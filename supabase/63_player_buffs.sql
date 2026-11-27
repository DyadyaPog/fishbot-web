-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('63_player_buffs.sql');

-- ============================================================================
-- Шаг 63: временные баффы расходников.
--
-- Расходник-бафф активируется в чате (!использовать). Бот передаёт список
-- баффов предмета (в каталоге их может быть несколько — «Пиршество духов»
-- даёт золото и опыт сразу), а вся запись выполняется здесь, в одной
-- транзакции: списание предмета, проверка занятых групп и продление.
--
-- Баффы живут в базе, а не в памяти: переживают рестарт бота и видны
-- кабинету. Канальные бонусы по-прежнему считаются в памяти бота.
--
-- Запускать в Supabase → SQL Editor после 01–62. Скрипт идемпотентен.
-- ============================================================================

create table if not exists public.player_buffs (
    id                uuid        primary key default gen_random_uuid(),
    channel_id        bigint      not null,
    user_id           bigint      not null,
    -- id баффа внутри каталога расходников (у составного предмета их два).
    buff_id           text        not null,
    -- Расходник, которым активирован бафф: по нему отличается продление
    -- от конфликта с другим предметом.
    item_id           text        not null,
    stack_group       text        not null check (stack_group in ('chance', 'gold', 'xp')),
    buff_name         text        not null,
    duration_seconds  integer     not null check (duration_seconds > 0 and duration_seconds <= 3600),
    -- Снимок эффектов на момент активации: кабинету не нужен каталог бота.
    effects           jsonb       not null default '[]'::jsonb,
    started_at        timestamptz not null default now(),
    ends_at           timestamptz not null,
    origin_message_id text,
    constraint player_buffs_player_fk
        foreign key (channel_id, user_id)
        references public.players (channel_id, user_id)
        on delete cascade,
    -- Один активный бафф на группу: chance / gold / xp.
    constraint player_buffs_group_unique unique (channel_id, user_id, stack_group)
);

comment on table public.player_buffs is
    'Активные временные баффы расходников: по одной строке на группу chance/gold/xp.';
comment on column public.player_buffs.item_id is
    'Расходник-источник: повтор того же предмета продлевает бафф, другой предмет в группе — отказ.';

-- Ежедневная очистка истёкших строк (bot/index.js) идёт по этому индексу.
create index if not exists player_buffs_ends_at_idx
    on public.player_buffs (ends_at);

-- Уникальные расходники (свиток очищения) кабинет помечает отдельно.
alter table public.items add column if not exists is_unique boolean not null default false;

comment on column public.items.is_unique is
    'Уникальный расходник со своим действием (свиток очищения). Синхронизируется из consumables.json.';

-- ---------------------------------------------------------------------------
-- RLS: кабинет читает только свои баффы, пишет только бот.
-- ---------------------------------------------------------------------------

alter table public.player_buffs enable row level security;

drop policy if exists "player_buffs: свой" on public.player_buffs;
create policy "player_buffs: свой" on public.player_buffs
    for select to authenticated
    using (exists (
        select 1 from public.accounts a
        where a.auth_id = (select auth.uid()) and a.user_id = player_buffs.user_id
    ));

revoke all on public.player_buffs from anon, authenticated;
grant select on public.player_buffs to authenticated;
grant all on public.player_buffs to service_role;

-- ---------------------------------------------------------------------------
-- Идемпотентность: одно сообщение активирует расходник один раз.
-- ---------------------------------------------------------------------------

create unique index if not exists uq_events_consumable_used
    on public.events (channel_id, user_id, message_id)
    where type = 'consumable_used' and message_id is not null;

comment on index public.uq_events_consumable_used is
    'Повторная обработка того же сообщения !использовать не списывает второй расходник.';

-- ---------------------------------------------------------------------------
-- Активация расходника-баффа.
--
-- Возвращает jsonb:
--   { ok: true, buffs: [{ buff_id, stack_group, buff_name, ends_at, remaining_seconds }] }
--   { ok: true, replayed: true } — этот расходник уже активирован этим сообщением
--   { ok: false, code: 'group_busy', stack_group, buff_name, remaining_seconds }
--   { ok: false, code, error } — остальные отказы
-- ---------------------------------------------------------------------------

create or replace function use_buff_consumable(
    p_channel_id bigint,
    p_user_id bigint,
    p_inventory_id bigint,
    p_buffs jsonb,
    p_origin_message_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_item      inventory%rowtype;
    v_buff      jsonb;
    v_group     text;
    v_duration  integer;
    v_groups    text[] := array[]::text[];
    v_existing  player_buffs%rowtype;
    v_started   timestamptz;
    v_ends      timestamptz;
    v_now       timestamptz := now();
    v_cap       timestamptz := now() + interval '60 minutes';
    v_results   jsonb := '[]'::jsonb;
    v_event_id  bigint;
begin
    -- Расходник списывает только бот: браузер не должен активировать баффы.
    if coalesce(auth.role(), '') <> 'service_role' then
        raise exception 'use_buff_consumable доступна только боту' using errcode = '42501';
    end if;

    if p_buffs is null
       or jsonb_typeof(p_buffs) <> 'array'
       or jsonb_array_length(p_buffs) = 0 then
        return jsonb_build_object('ok', false, 'code', 'empty_buffs',
            'error', 'Нет баффов для применения.');
    end if;

    select * into v_item
    from inventory
    where id = p_inventory_id
      and channel_id = p_channel_id
      and user_id = p_user_id
    for update;

    if not found then
        return jsonb_build_object('ok', false, 'code', 'not_found',
            'error', 'Расходник не найден в инвентаре.');
    end if;

    if v_item.item_type <> 'consumable' then
        return jsonb_build_object('ok', false, 'code', 'not_consumable',
            'error', 'Это не расходник.');
    end if;

    -- Список баффов: только известные группы, каждая один раз, длительность в капе.
    for v_buff in select * from jsonb_array_elements(p_buffs) loop
        v_group := coalesce(v_buff->>'stack_group', '');

        if v_group not in ('chance', 'gold', 'xp') then
            return jsonb_build_object('ok', false, 'code', 'bad_group',
                'error', 'Неизвестная группа баффа: ' || v_group);
        end if;

        if v_group = any(v_groups) then
            return jsonb_build_object('ok', false, 'code', 'duplicate_group',
                'error', 'Группа указана дважды: ' || v_group);
        end if;
        v_groups := array_append(v_groups, v_group);

        v_duration := coalesce((v_buff->>'duration_seconds')::integer, 0);
        if v_duration < 1 or v_duration > 3600 then
            return jsonb_build_object('ok', false, 'code', 'bad_duration',
                'error', 'Длительность баффа вне 1..3600 секунд.');
        end if;
    end loop;

    -- Группы: чужой активный бафф блокирует активацию целиком, без списания.
    for v_buff in select * from jsonb_array_elements(p_buffs) loop
        v_group := v_buff->>'stack_group';

        select * into v_existing
        from player_buffs
        where channel_id = p_channel_id
          and user_id = p_user_id
          and stack_group = v_group
        for update;

        if found and v_existing.ends_at > v_now
           and v_existing.item_id <> v_item.item_id then
            return jsonb_build_object(
                'ok', false,
                'code', 'group_busy',
                'stack_group', v_group,
                'buff_name', v_existing.buff_name,
                'remaining_seconds', greatest(
                    0,
                    ceil(extract(epoch from (v_existing.ends_at - v_now)))
                )::integer
            );
        end if;
    end loop;

    -- Идемпотентность: повтор того же сообщения не списывает второй предмет.
    -- Метка ставится после проверок: упавшая активация не должна оставлять
    -- событие, иначе исправленный повтор вернул бы «уже активирован».
    insert into events (channel_id, user_id, type, message_id, payload)
    values (
        p_channel_id,
        p_user_id,
        'consumable_used',
        nullif(p_origin_message_id, ''),
        jsonb_build_object('item_id', v_item.item_id, 'buffs', p_buffs)
    )
    on conflict (channel_id, user_id, message_id)
        where type = 'consumable_used' and message_id is not null
    do nothing
    returning id into v_event_id;

    if v_event_id is null then
        return jsonb_build_object('ok', true, 'replayed', true);
    end if;

    -- Списание одного расходника: стак уменьшается, последний экземпляр удаляется.
    if v_item.quantity > 1 then
        update inventory
        set quantity = quantity - 1, updated_at = now()
        where id = v_item.id;
    else
        delete from inventory where id = v_item.id;
    end if;

    for v_buff in select * from jsonb_array_elements(p_buffs) loop
        v_group := v_buff->>'stack_group';
        v_duration := (v_buff->>'duration_seconds')::integer;

        select * into v_existing
        from player_buffs
        where channel_id = p_channel_id
          and user_id = p_user_id
          and stack_group = v_group;

        if found and v_existing.ends_at > v_now and v_existing.item_id = v_item.item_id then
            -- Повтор того же предмета продлевает бафф, но не дольше капа.
            v_started := v_existing.started_at;
            v_ends := least(v_existing.ends_at + make_interval(secs => v_duration), v_cap);
        else
            v_started := v_now;
            v_ends := least(v_now + make_interval(secs => v_duration), v_cap);
        end if;

        insert into player_buffs (
            channel_id, user_id, buff_id, item_id, stack_group, buff_name,
            duration_seconds, effects, started_at, ends_at, origin_message_id
        ) values (
            p_channel_id,
            p_user_id,
            coalesce(nullif(v_buff->>'buff_id', ''), v_item.item_id || '_' || v_group),
            v_item.item_id,
            v_group,
            coalesce(nullif(v_buff->>'buff_name', ''), v_item.item_id),
            v_duration,
            coalesce(v_buff->'effects', '[]'::jsonb),
            v_started,
            v_ends,
            nullif(p_origin_message_id, '')
        )
        on conflict (channel_id, user_id, stack_group) do update set
            buff_id = excluded.buff_id,
            item_id = excluded.item_id,
            buff_name = excluded.buff_name,
            duration_seconds = excluded.duration_seconds,
            effects = excluded.effects,
            started_at = excluded.started_at,
            ends_at = excluded.ends_at,
            origin_message_id = excluded.origin_message_id;

        v_results := v_results || jsonb_build_array(jsonb_build_object(
            'buff_id', coalesce(nullif(v_buff->>'buff_id', ''), v_item.item_id || '_' || v_group),
            'stack_group', v_group,
            'buff_name', coalesce(nullif(v_buff->>'buff_name', ''), v_item.item_id),
            'ends_at', v_ends,
            'remaining_seconds', greatest(
                0,
                ceil(extract(epoch from (v_ends - v_now)))
            )::integer
        ));
    end loop;

    return jsonb_build_object('ok', true, 'item_id', v_item.item_id, 'buffs', v_results);
end $$;

comment on function use_buff_consumable(bigint, bigint, bigint, jsonb, text) is
    'Активирует расходник-бафф: списание, проверка групп и продление — в одной транзакции.';

revoke all on function use_buff_consumable(bigint, bigint, bigint, jsonb, text)
    from public, anon, authenticated;
grant execute on function use_buff_consumable(bigint, bigint, bigint, jsonb, text)
    to service_role;

-- ---------------------------------------------------------------------------
-- Ежедневная очистка истёкших баффов (вызывает бот при обслуживании).
-- ---------------------------------------------------------------------------

create or replace function cleanup_player_buffs()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    v_removed integer := 0;
begin
    if coalesce(auth.role(), '') <> 'service_role' then
        raise exception 'cleanup_player_buffs доступна только боту' using errcode = '42501';
    end if;

    delete from player_buffs where ends_at < now() - interval '1 hour';
    get diagnostics v_removed = row_count;
    return v_removed;
end $$;

comment on function cleanup_player_buffs() is
    'Удаляет истёкшие баффы старше часа: активные строки всегда читаются по ends_at.';

revoke all on function cleanup_player_buffs() from public, anon, authenticated;
grant execute on function cleanup_player_buffs() to service_role;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('63_player_buffs.sql');
