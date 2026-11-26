-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('60_player_catch_history.sql');

-- ============================================================================
-- Шаг 60: историческая таблица уловов игрока на канале.
--
-- Одна строка на пару «игрок + предмет» (рыба/сокровище) с числом уловов и
-- границами по времени. Мусор и пустота не получают идентификаторов и других
-- данных: для них хранится только общий счётчик (kind = 'trash' / 'empty',
-- item_id = null).
--
-- Таблица растёт от числа игроков и предметов, а не от числа уловов, поэтому
-- остаётся маленькой при любой активности. Счётчики обновляет триггер на
-- catches; пустой заброс в catches не пишется, поэтому его учитывает
-- record_catch() отдельной веткой.
--
-- Запускать в Supabase → SQL Editor после 59_processed_message_actions_cleanup.sql.
-- Перед запуском один раз выполните 00_schema_migrations.sql. Скрипт идемпотентен.
-- ============================================================================

create table if not exists public.player_catch_history (
    id              bigint      generated always as identity primary key,
    channel_id      bigint      not null references public.channels (id) on delete cascade,
    user_id         bigint      not null,
    -- Что поймано. Существующие виды улова; новые добавляются новой миграцией.
    kind            text        not null check (kind in ('fish', 'treasure', 'trash', 'empty')),
    -- id предмета из items для рыбы и сокровищ; null для мусора и пустоты.
    item_id         text        references public.items (id),
    catches         integer     not null default 0 check (catches >= 0),
    -- Суммарная цена уловов этой строки: заменяет подсчёт по сырому журналу
    -- catches, который чистится по сроку (cleanup_catches ниже).
    total_price     bigint      not null default 0,
    first_caught_at timestamptz not null default now(),
    last_caught_at  timestamptz not null default now(),
    updated_at      timestamptz not null default now(),
    constraint player_catch_history_player_fk
        foreign key (channel_id, user_id)
        references public.players (channel_id, user_id)
        on delete cascade,
    -- Мусор и пустота — без id; рыба и сокровище — всегда с id.
    constraint player_catch_history_item_shape check (
        (kind in ('trash', 'empty') and item_id is null)
        or (kind in ('fish', 'treasure') and item_id is not null)
    ),
    -- NULLS NOT DISTINCT: одна строка на игрока для мусора и для пустоты.
    constraint player_catch_history_unique
        unique nulls not distinct (channel_id, user_id, kind, item_id)
);

comment on table public.player_catch_history is
    'История уловов игрока на канале: число уловов по каждому предмету; мусор и пустота — общими счётчиками без id.';
comment on column public.player_catch_history.kind is
    'Вид улова: fish, treasure, trash или empty.';
comment on column public.player_catch_history.item_id is
    'Предмет из items для рыбы и сокровищ; null для мусора и пустоты.';

-- «Кто больше всех поймал щуку» и другие срезы по предмету.
create index if not exists idx_player_catch_history_top
    on public.player_catch_history (channel_id, kind, item_id, catches desc);

alter table public.player_catch_history enable row level security;
-- Политик нет: пишет триггер, читает бот (service_role обходит RLS).
revoke all on public.player_catch_history from public, anon, authenticated;
grant select, insert, update, delete on public.player_catch_history to service_role;
grant usage, select on sequence public.player_catch_history_id_seq to service_role;

-- На чистой базе переносить нечего: история наполняется триггером с первого улова.

-- ---------------------------------------------------------------------------
-- Триггер: каждый улов из catches увеличивает счётчик истории.
-- ---------------------------------------------------------------------------

create or replace function public.bump_player_catch_history()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_kind text;
    v_item text;
begin
    select i.kind::text into v_kind
      from public.items i
     where i.id = new.item_id;

    -- В catches попадают только рыба, сокровище и мусор.
    if v_kind is null or v_kind not in ('fish', 'treasure', 'trash') then
        return new;
    end if;

    v_item := case when v_kind = 'trash' then null else new.item_id end;

    insert into public.player_catch_history (
        channel_id, user_id, kind, item_id, catches, total_price, first_caught_at, last_caught_at
    )
    values (
        new.channel_id, new.user_id, v_kind, v_item, 1,
        coalesce(new.price, 0), new.caught_at, new.caught_at
    )
    on conflict on constraint player_catch_history_unique do update
        set catches         = public.player_catch_history.catches + 1,
            total_price     = public.player_catch_history.total_price + excluded.total_price,
            first_caught_at = least(public.player_catch_history.first_caught_at, excluded.first_caught_at),
            last_caught_at  = greatest(public.player_catch_history.last_caught_at, excluded.last_caught_at),
            updated_at      = now();

    return new;
end $$;

comment on function public.bump_player_catch_history() is
    'Увеличивает счётчик и сумму цен истории уловов при вставке в catches; мусор считается без id.';

drop trigger if exists catches_history_trigger on public.catches;
create trigger catches_history_trigger
    after insert on public.catches
    for each row
    execute function public.bump_player_catch_history();

-- ---------------------------------------------------------------------------
-- record_catch(): пустой заброс не пишет catches, но учитывается в истории.
-- ---------------------------------------------------------------------------

create or replace function record_catch(
    p_channel_id      bigint,
    p_user_id         bigint,
    p_item_id         text,
    p_price           integer,
    p_xp_delta        integer,
    p_fish_delta      integer,
    p_catch_count     integer default 1,
    p_origin_event_id text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_count    integer := greatest(1, coalesce(p_catch_count, 1));
    v_inserted integer := 0;
begin
    -- Повтор того же сообщения не начисляет XP и не пишет улов повторно.
    if p_channel_id is not null
       and p_origin_event_id is not null and p_origin_event_id <> '' then
        insert into processed_message_actions (channel_id, user_id, action, origin_event_id)
        values (p_channel_id, p_user_id, 'record_catch', p_origin_event_id)
        on conflict do nothing;
        get diagnostics v_inserted = row_count;
        if v_inserted = 0 then
            return;
        end if;
    end if;

    -- Пустота: не улов, в catches не пишем; в истории — только счётчик.
    if p_item_id is null or btrim(p_item_id) = '' then
        if p_channel_id is null then
            return;
        end if;

        insert into player_catch_history (
            channel_id, user_id, kind, item_id, catches, first_caught_at, last_caught_at
        )
        values (p_channel_id, p_user_id, 'empty', null, v_count, now(), now())
        on conflict on constraint player_catch_history_unique do update
            set catches        = player_catch_history.catches + excluded.catches,
                last_caught_at = excluded.last_caught_at,
                updated_at     = now();
        return;
    end if;

    update players
       set xp          = xp + coalesce(p_xp_delta, 0),
           fish_caught = fish_caught + coalesce(p_fish_delta, 0)
     where channel_id = p_channel_id
       and user_id    = p_user_id;

    insert into catches (channel_id, user_id, item_id, price)
    select p_channel_id, p_user_id, p_item_id, coalesce(p_price, 0)
      from generate_series(1, v_count);
end $$;

comment on function record_catch(bigint, bigint, text, integer, integer, integer, integer, text) is
    'Атомарно обновляет XP/счётчик уловов и пишет catches; пустота идёт только в историю; повтор msg.id не применяется.';

revoke all on function record_catch(bigint, bigint, text, integer, integer, integer, integer, text) from public, anon;
grant execute on function record_catch(bigint, bigint, text, integer, integer, integer, integer, text) to service_role;

-- ---------------------------------------------------------------------------
-- Доход дашборда — из истории, а не из журнала: журнал чистится по сроку.
-- ---------------------------------------------------------------------------

create or replace function get_dashboard_stats(p_channel_id bigint)
returns table (
    total_fish    bigint,
    user_count    bigint,
    total_revenue bigint
)
language sql
stable
set search_path = public
as $$
    select
        coalesce((select sum(fish_caught) from players  where channel_id = p_channel_id), 0)::bigint,
        (select count(*)            from players  where channel_id = p_channel_id)::bigint,
        coalesce((select sum(total_price) from player_catch_history where channel_id = p_channel_id), 0)::bigint;
$$;

comment on function get_dashboard_stats(bigint) is
    'Агрегаты дашборда бота по каналу: уловы, игроки, доход (доход — из истории уловов).';

-- Считает только для бота: у клиентов прав на функцию нет.
revoke all on function get_dashboard_stats(bigint) from public, anon, authenticated;
grant execute on function get_dashboard_stats(bigint) to service_role;

-- ---------------------------------------------------------------------------
-- Коллекция рыб — тоже из истории: проданная и старая рыба не пропадает.
-- ---------------------------------------------------------------------------

create or replace function my_caught_fish_ids(p_channel_id bigint)
returns table(item_id text)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_user bigint;
begin
    if auth.uid() is null then
        raise exception 'требуется вход' using errcode = '28000';
    end if;

    select a.user_id into v_user
      from accounts a
     where a.auth_id = auth.uid()
     limit 1;

    if v_user is null then
        raise exception 'аккаунт не найден' using errcode = '28000';
    end if;

    -- Канал должен принадлежать этому игроку.
    if not exists (
        select 1 from players p
         where p.channel_id = p_channel_id
           and p.user_id = v_user
    ) then
        raise exception 'канал не принадлежит игроку' using errcode = '42501';
    end if;

    return query
        select distinct h.item_id
          from player_catch_history h
         where h.channel_id = p_channel_id
           and h.user_id = v_user
           and h.item_id is not null;
end $$;

comment on function my_caught_fish_ids(bigint) is
    'Distinct item_id уловов игрока на канале (для коллекции); источник — история уловов.';

revoke all on function my_caught_fish_ids(bigint) from public, anon;
grant execute on function my_caught_fish_ids(bigint) to authenticated;

-- ---------------------------------------------------------------------------
-- Срок хранения сырого журнала уловов.
-- ---------------------------------------------------------------------------

create index if not exists idx_catches_caught_at
    on public.catches (caught_at);

create or replace function cleanup_catches(
    p_keep_days integer default 30
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    v_days    integer := greatest(1, coalesce(p_keep_days, 30));
    v_deleted integer := 0;
begin
    delete from catches
     where caught_at < now() - make_interval(days => v_days);
    get diagnostics v_deleted = row_count;
    return v_deleted;
end $$;

comment on function cleanup_catches(integer) is
    'Удаляет сырой журнал catches старше p_keep_days (по умолчанию 30) и возвращает число удалённых строк. Счётчики и доход остаются в player_catch_history.';

revoke all on function cleanup_catches(integer) from public, anon;
grant execute on function cleanup_catches(integer) to service_role;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('60_player_catch_history.sql');
