-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('24_hardening.sql');

-- ============================================================================
-- Шаг 24: закрытие дыр аудита безопасности.
--
-- Что делает:
--   1. журнал действий админки (admin_audit_log + log_admin_action);
--   2. лимиты частоты для запросов из кабинета (rate_limits + триггеры);
--   3. shop_state виден только по своим каналам, а не всем вошедшим;
--   4. channel_ranking больше не отдаёт Twitch ID чужих игроков;
--   5. окно магазина артефактов считает база (set_artifact_shop_window);
--   6. buy_item продаёт только то, что реально есть в витрине (цена > 0);
--   7. equip_item / unequip_item блокируют строку игрока — без гонки за слот;
--   8. request_chances_refresh проверяет игрока на канале и не даёт спамить;
--   9. права на chance_refresh_requests отозваны явно.
--
-- Запускать в Supabase → SQL Editor после 23_shop_state.sql.
-- Скрипт идемпотентен: функции пересоздаются, политики пересоздаются.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Журнал действий админки
-- ---------------------------------------------------------------------------
-- Деньги и предметы меняются и из бота, и из панели. Событие admin_grant
-- видно в ленте игрока, но смену баланса нигде не видно — после утечки
-- доступа нельзя понять, что подкрутили. Пишем каждое действие панели.
create table if not exists public.admin_audit_log (
    id          bigint generated always as identity primary key,
    channel_id  bigint references public.channels (id) on delete set null,
    actor       text not null default 'admin-panel',
    action      text not null,
    target_user bigint,
    target_name text,
    payload     jsonb not null default '{}'::jsonb,
    created_at  timestamptz not null default now()
);

comment on table public.admin_audit_log is
    'Журнал действий админ-панели: выдача предметов, правка баланса и опыта.';

create index if not exists admin_audit_log_channel_created_idx
    on public.admin_audit_log (channel_id, created_at desc);

alter table public.admin_audit_log enable row level security;

-- Читает только бот и панель: у кабинета доступа к журналу нет.
revoke all on public.admin_audit_log from anon, authenticated;
grant select, insert on public.admin_audit_log to service_role;
grant usage, select on sequence public.admin_audit_log_id_seq to service_role;

drop function if exists log_admin_action(text, bigint, bigint, text, text, jsonb);

create or replace function log_admin_action(
    p_action      text,
    p_channel_id  bigint default null,
    p_target_user bigint default null,
    p_target_name text default null,
    p_actor       text default null,
    p_payload     jsonb default '{}'::jsonb
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id bigint;
begin
    if coalesce(auth.role(), '') <> 'service_role' then
        raise exception 'журнал доступен только service_role' using errcode = '42501';
    end if;

    insert into admin_audit_log (channel_id, actor, action, target_user, target_name, payload)
    values (
        p_channel_id,
        coalesce(nullif(p_actor, ''), 'admin-panel'),
        coalesce(nullif(p_action, ''), 'unknown'),
        p_target_user,
        nullif(p_target_name, ''),
        coalesce(p_payload, '{}'::jsonb)
    )
    returning id into v_id;

    return v_id;
end $$;

comment on function log_admin_action(text, bigint, bigint, text, text, jsonb) is
    'Запись в журнал админки: кто, что и у кого изменил.';

revoke all on function log_admin_action(text, bigint, bigint, text, text, jsonb)
    from public, anon, authenticated;
grant execute on function log_admin_action(text, bigint, bigint, text, text, jsonb)
    to service_role;

-- ---------------------------------------------------------------------------
-- 2. Лимиты частоты
-- ---------------------------------------------------------------------------
-- Кабинет ходит в базу напрямую с anon-ключом, поэтому лимит нужен в базе.
-- Ограничиваем только вызовы от authenticated: бот работает service_role,
-- и его игровые действия (каждый улов меняет баланс) лимитировать нельзя.
create table if not exists public.rate_limits (
    user_id      bigint not null,
    action       text not null,
    window_start timestamptz not null default now(),
    count        integer not null default 0,
    primary key (user_id, action)
);

comment on table public.rate_limits is
    'Счётчики частоты изменений из кабинета: окно и число операций на игрока.';

alter table public.rate_limits enable row level security;
revoke all on public.rate_limits from anon, authenticated;
grant select, insert, update, delete on public.rate_limits to service_role;

-- take_rate_limit(): атомарный счётчик. true — можно, false — лимит исчерпан.
create or replace function take_rate_limit(
    p_user_id bigint,
    p_action  text,
    p_limit   integer,
    p_window  interval
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_count integer;
begin
    insert into rate_limits (user_id, action, window_start, count)
    values (p_user_id, p_action, now(), 1)
    on conflict (user_id, action) do update
    set count = case
            when rate_limits.window_start < now() - p_window then 1
            else rate_limits.count + 1
        end,
        window_start = case
            when rate_limits.window_start < now() - p_window then now()
            else rate_limits.window_start
        end
    returning count into v_count;

    return v_count <= p_limit;
end $$;

comment on function take_rate_limit(bigint, text, integer, interval) is
    'Атомарный счётчик частоты: true, если операция в пределах лимита.';

-- Внутренняя функция: снаружи её вызывают только триггеры и RPC.
revoke all on function take_rate_limit(bigint, text, integer, interval)
    from public, anon, authenticated;

-- Единый страж изменений игрового состояния из веба.
-- Баланс меняет любая покупка, продажа, ремонт и очистка, поэтому лимит
-- на players.balance накрывает все денежные RPC сразу.
create or replace function guard_web_writes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_user   bigint;
    v_limit  integer;
    v_action text;
    v_window interval;
begin
    -- В BEFORE DELETE нет строки NEW: работаем с OLD, а не с coalesce по записи.
    if tg_op = 'DELETE' then
        v_user := old.user_id;
    else
        v_user := new.user_id;
    end if;

    -- Бот пишет service_role: его скорость задаётся кулдауном рыбалки.
    if coalesce(auth.role(), '') = 'service_role' then
        return case when tg_op = 'DELETE' then old else new end;
    end if;

    if tg_table_name = 'players' then
        v_action := 'wallet';
        v_limit  := 30;
        v_window := interval '1 minute';
    else
        v_action := 'inventory';
        v_limit  := 60;
        v_window := interval '1 minute';
    end if;

    if not take_rate_limit(v_user, v_action, v_limit, v_window) then
        raise exception 'Слишком часто: подождите минуту и повторите.'
            using errcode = 'P0001';
    end if;

    return case when tg_op = 'DELETE' then old else new end;
end $$;

comment on function guard_web_writes() is
    'Лимит частоты для изменений баланса и инвентаря из кабинета (не для service_role).';

drop trigger if exists players_web_rate_limit on public.players;
create trigger players_web_rate_limit
    before update of balance on public.players
    for each row execute function guard_web_writes();

drop trigger if exists inventory_web_rate_limit on public.inventory;
create trigger inventory_web_rate_limit
    before insert or update or delete on public.inventory
    for each row execute function guard_web_writes();

revoke all on function guard_web_writes() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. shop_state: только свои каналы
-- ---------------------------------------------------------------------------
-- Раньше окно магазина читал любой вошедший по всем каналам сразу: чужие
-- каналы и их окна были видны всем. Теперь строка видна, если на канале
-- есть профиль вошедшего — этого достаточно и для уведомления о другом
-- канале, ведь уведомлять можно только про свои каналы.
drop policy if exists "shop_state: чтение" on public.shop_state;
create policy "shop_state: чтение" on public.shop_state
    for select to authenticated
    using (exists (
        select 1
        from public.players p
        join public.accounts a on a.user_id = p.user_id
        where p.channel_id = shop_state.channel_id
          and a.auth_id = (select auth.uid())
    ));

-- ---------------------------------------------------------------------------
-- 4. channel_ranking без Twitch ID
-- ---------------------------------------------------------------------------
-- Представление работает с правами владельца (иначе RLS на players скрыл бы
-- соперников) и до сих пор отдавало user_id каждого игрока канала. Кабинету
-- он не нужен: рейтинг строится по нику, месту и балансу.
drop view if exists public.channel_ranking;

create view public.channel_ranking as
select
    p.channel_id,
    p.username,
    p.balance,
    p.xp,
    level_from_xp(p.xp) as level,
    p.fish_caught,
    rank() over (partition by p.channel_id order by p.balance desc) as place
from public.players p
where exists (
    select 1
    from public.players me
    join public.accounts a on a.user_id = me.user_id
    where me.channel_id = p.channel_id
      and a.auth_id = (select auth.uid())
);

comment on view public.channel_ranking is
    'Рейтинг канала по балансу без Twitch ID; строки только по каналам, где вошедший играет.';

revoke all on public.channel_ranking from anon, authenticated;
grant select on public.channel_ranking to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Окно магазина артефактов считает база
-- ---------------------------------------------------------------------------
-- Раньше бот присылал готовое время закрытия, посчитанное по своим часам:
-- расхождение часов с базой сдвигало окно. Теперь бот передаёт минуты,
-- а now() берётся из базы — единственный источник времени.
drop function if exists set_artifact_shop_window(bigint, integer);

create or replace function set_artifact_shop_window(
    p_channel_id bigint,
    p_minutes    integer default 0
)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
    v_minutes integer := least(240, greatest(0, coalesce(p_minutes, 0)));
    v_until   timestamptz;
begin
    if coalesce(auth.role(), '') <> 'service_role' then
        raise exception 'окно магазина меняет только бот' using errcode = '42501';
    end if;

    v_until := case
        when v_minutes > 0 then now() + (v_minutes * interval '1 minute')
        else now()
    end;

    insert into shop_state (channel_id, artifact_open_until, updated_at)
    values (p_channel_id, v_until, now())
    on conflict (channel_id) do update
    set artifact_open_until = excluded.artifact_open_until,
        updated_at          = now();

    return v_until;
end $$;

comment on function set_artifact_shop_window(bigint, integer) is
    'Открывает магазин артефактов на N минут (0 — закрыть); время закрытия считает база.';

revoke all on function set_artifact_shop_window(bigint, integer)
    from public, anon, authenticated;
grant execute on function set_artifact_shop_window(bigint, integer) to service_role;

-- ---------------------------------------------------------------------------
-- 6. buy_item: продаётся только то, что есть в витрине
-- ---------------------------------------------------------------------------
-- Проверка «kind и редкость валидны» пропускала любой предмет из items,
-- включая убранный из конфига и с ценой 0. Тело покупки не дублируем:
-- переименовываем его в buy_item_impl, а обёртка проверяет витрину.
do $$
begin
    if to_regprocedure('public.buy_item(text,bigint,bigint,integer,text,text,integer)') is not null
       and to_regprocedure('public.buy_item_impl(text,bigint,bigint,integer,text,text,integer)') is null then
        alter function public.buy_item(text, bigint, bigint, integer, text, text, integer)
            rename to buy_item_impl;
    end if;
end $$;

drop function if exists buy_item(text, bigint, bigint, integer, text, text, integer);

create or replace function buy_item(
    p_item_id         text,
    p_channel_id      bigint,
    p_user_id         bigint default null,
    p_quantity        integer default 1,
    p_username        text default null,
    p_message_id      text default null,
    p_inventory_limit integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_in_shop boolean;
begin
    if p_item_id is null or btrim(p_item_id) = '' or p_channel_id is null then
        return jsonb_build_object(
            'ok', false,
            'code', 'bad_request',
            'error', 'Нужны канал и предмет.'
        );
    end if;

    -- Ровно те же строки, что отдаёт shop_items(): снаряжение с ценой.
    select exists (
        select 1
        from items i
        where i.id = p_item_id
          and i.kind in ('rod', 'line', 'hook', 'bait')
          and i.rarity <> 'starter'
          and coalesce(i.price, 0) > 0
    ) into v_in_shop;

    if not v_in_shop then
        return jsonb_build_object(
            'ok', false,
            'code', 'not_found',
            'error', 'Этого предмета нет в магазине.'
        );
    end if;

    return buy_item_impl(
        p_item_id, p_channel_id, p_user_id, p_quantity,
        p_username, p_message_id, p_inventory_limit
    );
end $$;

comment on function buy_item(text, bigint, bigint, integer, text, text, integer) is
    'Покупка снаряжения: проверка витрины, затем buy_item_impl.';

revoke all on function buy_item_impl(text, bigint, bigint, integer, text, text, integer)
    from public, anon, authenticated;
grant execute on function buy_item_impl(text, bigint, bigint, integer, text, text, integer)
    to service_role;

revoke all on function buy_item(text, bigint, bigint, integer, text, text, integer)
    from public, anon;
grant execute on function buy_item(text, bigint, bigint, integer, text, text, integer)
    to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. equip_item / unequip_item: блокировка строки игрока
-- ---------------------------------------------------------------------------
-- Две параллельные экипировки могли одновременно пройти проверку слота и
-- упереться в уникальный индекс uq_inventory_equipped. Блокируем профиль
-- игрока на время операции — как это уже делает buy_item.
drop function if exists equip_item(bigint);
drop function if exists unequip_item(bigint);

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

    -- Та же блокировка, что в buy_item: слот один, операции идут по очереди.
    perform 1
      from players
     where channel_id = v_channel
       and user_id = v_user
     for update;

    -- Те же слоты, что EQUIPPABLE_TYPES в боте: наживка экипируется наравне
    -- со снаряжением, артефакты — нет.
    if v_type::text not in ('rod', 'line', 'hook', 'bait') then
        raise exception 'этот предмет нельзя надеть' using errcode = '22023';
    end if;

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
    'Надевает предмет игрока под блокировкой профиля и пишет событие inventory_equip.';

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

    perform 1
      from players
     where channel_id = v_channel
       and user_id = v_user
     for update;

    update inventory
       set is_equipped = false,
           updated_at  = now()
     where id = p_inventory_id;

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
    'Снимает предмет игрока под блокировкой профиля и пишет событие inventory_unequip.';

revoke all on function equip_item(bigint, text)   from public, anon;
revoke all on function unequip_item(bigint, text) from public, anon;
grant execute on function equip_item(bigint, text)   to authenticated, service_role;
grant execute on function unequip_item(bigint, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8. request_chances_refresh: игрок на канале + лимит
-- ---------------------------------------------------------------------------
-- Без проверки профиля запрос на чужом канале падал сырой ошибкой FK, а
-- повторные вызовы заставляли бота пересчитывать шансы без ограничений.
create or replace function request_chances_refresh(p_channel_id bigint)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_uid  uuid := auth.uid();
    v_user bigint;
begin
    if v_uid is null then
        raise exception 'требуется вход' using errcode = '28000';
    end if;

    select a.user_id into v_user
      from accounts a
     where a.auth_id = v_uid
     limit 1;

    if v_user is null then
        raise exception 'профиль не привязан к Twitch ID' using errcode = '22023';
    end if;

    if not exists (
        select 1 from players p
        where p.channel_id = p_channel_id
          and p.user_id = v_user
    ) then
        raise exception 'вы не играли на этом канале' using errcode = '42501';
    end if;

    if not take_rate_limit(v_user, 'chances_refresh', 3, interval '5 minutes') then
        raise exception 'Шансы пересчитываются не чаще трёх раз в 5 минут.'
            using errcode = 'P0001';
    end if;

    insert into chance_refresh_requests (channel_id, user_id, requested_at)
    values (p_channel_id, v_user, now())
    on conflict (channel_id, user_id)
    do update set requested_at = excluded.requested_at;

    return true;
end $$;

comment on function request_chances_refresh(bigint) is
    'Кабинет просит бота пересчитать шансы: только свой канал и не чаще 3 раз в 5 минут.';

revoke all on function request_chances_refresh(bigint) from public, anon;
grant execute on function request_chances_refresh(bigint) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. Явные права там, где спасала только RLS
-- ---------------------------------------------------------------------------
-- chance_refresh_requests создан без revoke: роли получали табличные права
-- по умолчанию Supabase. Политик нет, поэтому RLS и закрывал доступ, но
-- полагаться на это не стоит.
revoke all on public.chance_refresh_requests from anon, authenticated;

-- Права самого get_dashboard_stats закрываются там, где он создаётся
-- (шаг 60): здесь этой функции ещё нет.

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('24_hardening.sql');
