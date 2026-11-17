-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('14_chances_refresh.sql');

-- ============================================================================
-- Шаг 14: запросы кабинета на пересчёт шансов улова.
--
-- Кабинет не считает шансы сам: он пишет сюда запрос, а бот (единственный
-- калькулятор) подхватывает его через Supabase Realtime и/или опросом,
-- пересчитывает и обновляет player_chances. Строка запроса хранится только
-- до обработки — после пересчёта бот её удаляет.
-- ============================================================================

create table if not exists public.chance_refresh_requests (
    channel_id bigint not null,
    user_id    bigint not null,
    requested_at timestamptz not null default now(),
    primary key (channel_id, user_id)
);

alter table public.chance_refresh_requests enable row level security;

-- Прямого доступа у authenticated нет: чтение/запись только через RPC и
-- service_role (бот). RLS закрывает таблицу от клиентов полностью.
drop policy if exists "chance_refresh_requests: нет доступа" on public.chance_refresh_requests;

-- service_role обходит RLS по умолчанию, но явный GRANT не помешает.
grant all on public.chance_refresh_requests to service_role;

-- ---------------------------------------------------------------------------
-- request_chances_refresh(): кабинет просит бота пересчитать шансы.
-- ---------------------------------------------------------------------------
create or replace function public.request_chances_refresh(p_channel_id bigint)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_uid   uuid := auth.uid();
    v_user  bigint;
begin
    if v_uid is null then
        raise exception 'требуется вход' using errcode = '28000';
    end if;

    select a.user_id into v_user
      from public.accounts a
     where a.auth_id = v_uid
     limit 1;

    if v_user is null then
        raise exception 'профиль не привязан к Twitch ID' using errcode = '22023';
    end if;

    insert into public.chance_refresh_requests (channel_id, user_id, requested_at)
    values (p_channel_id, v_user, now())
    on conflict (channel_id, user_id)
    do update set requested_at = excluded.requested_at;

    return true;
end $$;

comment on function public.request_chances_refresh(bigint) is
    'Кабинет просит бота пересчитать шансы улова пользователя на канале.';

revoke all on function public.request_chances_refresh(bigint) from public, anon;
grant execute on function public.request_chances_refresh(bigint) to authenticated;

-- Включаем Realtime для таблицы, чтобы бот получал событие мгновенно.
do $$
begin
    if not exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename = 'chance_refresh_requests'
    ) then
        alter publication supabase_realtime add table public.chance_refresh_requests;
    end if;
end $$;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('14_chances_refresh.sql');
