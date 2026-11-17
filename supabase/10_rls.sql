-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('10_rls.sql');

-- ============================================================================
-- Шаг 10: RLS и функции для веба.
--
-- Читает кабинет только своё: строки игрока определяются через accounts.auth_id.
-- Пишет в игровые таблицы только бот (service_role обходит RLS), поэтому у
-- authenticated нет insert/update/delete политик — кроме двух RPC для инвентаря.
--
-- Запускать в Supabase → SQL Editor. Скрипт идемпотентен.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table items     enable row level security;
alter table channels  enable row level security;
alter table accounts  enable row level security;
alter table players   enable row level security;
alter table inventory enable row level security;
alter table catches   enable row level security;
alter table events        enable row level security;

drop policy if exists "items: чтение"    on items;
drop policy if exists "channels: чтение" on channels;
drop policy if exists "accounts: свой"   on accounts;
drop policy if exists "players: свой"    on players;
drop policy if exists "inventory: свой"  on inventory;
drop policy if exists "catches: свой"       on catches;
drop policy if exists "events: свой"     on events;

-- Справочники читают все вошедшие.
create policy "items: чтение" on items
    for select to authenticated using (true);

create policy "channels: чтение" on channels
    for select to authenticated using (true);

-- Своя связка Twitch ID ↔ auth.
create policy "accounts: свой" on accounts
    for select to authenticated using (auth_id = (select auth.uid()));

-- Свои профили на всех каналах (источник my_channels).
create policy "players: свой" on players
    for select to authenticated
    using (user_id in (select a.user_id from accounts a where a.auth_id = (select auth.uid())));

-- Личный инвентарь, журнал уловов и события.
create policy "inventory: свой" on inventory
    for select to authenticated
    using (exists (
        select 1 from accounts a
        where a.auth_id = (select auth.uid()) and a.user_id = inventory.user_id
    ));

create policy "catches: свой" on catches
    for select to authenticated
    using (exists (
        select 1 from accounts a
        where a.auth_id = (select auth.uid()) and a.user_id = catches.user_id
    ));

create policy "events: свой" on events
    for select to authenticated
    using (exists (
        select 1 from accounts a
        where a.auth_id = (select auth.uid()) and a.user_id = events.user_id
    ));

-- ---------------------------------------------------------------------------
-- claim_profile(): привязка Twitch ID к Supabase Auth при первом входе
-- ---------------------------------------------------------------------------

create or replace function claim_profile()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
    v_uid       uuid := auth.uid();
    v_provider  text;
    v_twitch    bigint;
    v_username  text;
    v_owner     uuid;
begin
    if v_uid is null then
        raise exception 'требуется вход через Twitch' using errcode = '28000';
    end if;

    select u.raw_app_meta_data->>'provider',
           case
               when u.raw_user_meta_data->>'provider_id' ~ '^[0-9]+$'
                   then (u.raw_user_meta_data->>'provider_id')::bigint
           end,
           coalesce(
               u.raw_user_meta_data->>'user_name',
               u.raw_user_meta_data->>'preferred_username',
               u.raw_user_meta_data->>'nickname'
           )
      into v_provider, v_twitch, v_username
      from auth.users u
     where u.id = v_uid;

    if v_provider is distinct from 'twitch' or v_twitch is null then
        raise exception 'в профиле нет Twitch ID (provider_id)' using errcode = '22023';
    end if;

    select a.auth_id into v_owner
      from accounts a
     where a.user_id = v_twitch;

    if found then
        if v_owner is not null and v_owner <> v_uid then
            raise exception 'Twitch ID % уже привязан к другому аккаунту', v_twitch
                using errcode = '23505';
        end if;

        update accounts
           set auth_id  = v_uid,
               username = coalesce(nullif(v_username, ''), username)
         where user_id = v_twitch;
    else
        if exists (select 1 from accounts a where a.auth_id = v_uid) then
            raise exception 'этот вход уже привязан к другому Twitch ID' using errcode = '23505';
        end if;

        insert into accounts (user_id, auth_id, username)
        values (v_twitch, v_uid, nullif(v_username, ''));
    end if;

    return v_twitch;
end $$;

comment on function claim_profile() is
    'Привязывает Twitch ID вошедшего к accounts.auth_id и возвращает Twitch ID.';

-- ---------------------------------------------------------------------------
-- equip_item / unequip_item: единственные изменения из веба
-- ---------------------------------------------------------------------------

-- Пересоздаём: добавился p_message_id, а старая версия с одной колонкой
-- сделала бы вызов с одним аргументом неоднозначным.
drop function if exists equip_item(bigint);

create or replace function equip_item(p_inventory_id bigint, p_message_id text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_user         bigint;
    v_channel      bigint;
    v_type         item_kind;
    v_item_id      text;
    v_prev_id      bigint;
    v_prev_item_id text;
    -- Из кабинета message_id всегда пустой; бот передаёт id своего сообщения.
    v_message_id   text := case when auth.uid() is null then nullif(p_message_id, '') end;
begin
    select i.user_id, i.channel_id, i.item_type, i.item_id
      into v_user, v_channel, v_type, v_item_id
      from inventory i
     where i.id = p_inventory_id
       and exists (
           select 1 from accounts a
           where a.auth_id = auth.uid() and a.user_id = i.user_id
       );

    if not found then
        raise exception 'предмет не найден' using errcode = 'P0002';
    end if;

    -- Те же слоты, что EQUIPPABLE_TYPES в боте (equip.command.js): наживка
    -- экипируется наравне со снаряжением, артефакты — нет.
    if v_type::text not in ('rod', 'line', 'hook', 'bait') then
        raise exception 'этот предмет нельзя надеть' using errcode = '22023';
    end if;

    -- Снимаем текущий предмет этого слота: uq_inventory_equipped не даёт
    -- держать два надетых предмета одного типа.
    update inventory
       set is_equipped = false,
           updated_at  = now()
     where channel_id = v_channel
       and user_id    = v_user
       and item_type  = v_type
       and is_equipped
    returning id, item_id into v_prev_id, v_prev_item_id;

    -- Старый предмет слетает сам — пишем это как отдельное снятие, иначе
    -- в журнале видно только надевание нового.
    if found and v_prev_id <> p_inventory_id then
        insert into events (channel_id, user_id, type, message_id, payload)
        values (
            v_channel, v_user, 'inventory_unequip', v_message_id,
            jsonb_build_object(
                'inventoryId', v_prev_id,
                'itemId',      v_prev_item_id,
                'itemType',    v_type,
                'source',      case when v_message_id is null then 'web' else 'bot' end,
                'replacedBy',  p_inventory_id,
                'implicit',    true
            )
        );
    end if;

    update inventory
       set is_equipped = true,
           updated_at  = now()
     where id = p_inventory_id;

    insert into events (channel_id, user_id, type, message_id, payload)
    values (
        v_channel, v_user, 'inventory_equip', v_message_id,
        jsonb_build_object(
            'inventoryId', p_inventory_id,
            'itemId',      v_item_id,
            'itemType',    v_type,
            'source',      case when v_message_id is null then 'web' else 'bot' end
        )
    );
end $$;

comment on function equip_item(bigint, text) is
    'Надевает предмет игрока и пишет событие inventory_equip в events.';

drop function if exists unequip_item(bigint);

create or replace function unequip_item(p_inventory_id bigint, p_message_id text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_user       bigint;
    v_channel    bigint;
    v_type       item_kind;
    v_item_id    text;
    v_message_id text := case when auth.uid() is null then nullif(p_message_id, '') end;
begin
    update inventory i
       set is_equipped = false,
           updated_at  = now()
     where i.id = p_inventory_id
       and exists (
           select 1 from accounts a
           where a.auth_id = auth.uid() and a.user_id = i.user_id
       )
    returning i.user_id, i.channel_id, i.item_type, i.item_id
      into v_user, v_channel, v_type, v_item_id;

    if not found then
        raise exception 'предмет не найден' using errcode = 'P0002';
    end if;

    insert into events (channel_id, user_id, type, message_id, payload)
    values (
        v_channel, v_user, 'inventory_unequip', v_message_id,
        jsonb_build_object(
            'inventoryId', p_inventory_id,
            'itemId',      v_item_id,
            'itemType',    v_type,
            'source',      case when v_message_id is null then 'web' else 'bot' end
        )
    );
end $$;

comment on function unequip_item(bigint, text) is
    'Снимает предмет игрока и пишет событие inventory_unequip в events.';

-- ---------------------------------------------------------------------------
-- Привилегии на таблицы
-- ---------------------------------------------------------------------------
-- RLS ограничивает строки, но не заменяет GRANT: роли нужны права на сами
-- таблицы. service_role обходит RLS (бот и скрипт переноса пишут им),
-- authenticated читает через политики выше.

grant select on items, channels, accounts, players, inventory, catches, events
    to authenticated;

grant select, insert, update, delete
    on items, channels, accounts, players, inventory, catches, events
    to service_role;

grant usage, select on all sequences in schema public to service_role;

-- ---------------------------------------------------------------------------
-- Права на функции
-- ---------------------------------------------------------------------------

revoke all on function claim_profile()          from public, anon;
revoke all on function equip_item(bigint, text)   from public, anon;
revoke all on function unequip_item(bigint, text) from public, anon;

grant execute on function claim_profile()       to authenticated;
grant execute on function equip_item(bigint, text)   to authenticated;
grant execute on function unequip_item(bigint, text) to authenticated;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('10_rls.sql');
