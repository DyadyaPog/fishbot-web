-- ============================================================================
-- Шаг 49: отметка «бот запущен» для кабинета.
--
-- Кабинет не знал, жив ли процесс бота: в channels есть только статус
-- подключения канала, а он не меняется, когда бот падает. Теперь бот при старте
-- и дальше раз в две минуты обновляет одну строку bot_heartbeat, а кабинет
-- читает время последнего сигнала через RPC bot_heartbeat() и сам решает,
-- считать ли бота запущенным (сигнал не старше 5 минут).
--
-- Таблица закрыта от кабинета и анонимов: строку пишет бот ключом service_role,
-- читать её можно только через RPC.
--
-- Запускать в Supabase → SQL Editor после 48_bot_joined_at_cleanup.sql.
-- Скрипт идемпотентен.
-- ============================================================================

select assert_migration('49_bot_heartbeat.sql');

create table if not exists public.bot_heartbeat (
    id      smallint    primary key default 1 check (id = 1),
    seen_at timestamptz not null default now()
);

comment on table public.bot_heartbeat is
    'Одна строка: время последнего сигнала от запущенного процесса бота.';

alter table public.bot_heartbeat enable row level security;

-- Политик нет: напрямую таблицу не читает никто, кабинет идёт через RPC.
revoke all on public.bot_heartbeat from authenticated, anon, public;
grant select, insert, update on public.bot_heartbeat to service_role;

-- ---------------------------------------------------------------------------
-- bot_heartbeat(): время последнего сигнала
-- ---------------------------------------------------------------------------
-- Пустой результат — бот ещё ни разу не запускался с этим шагом.

create or replace function bot_heartbeat()
returns table (seen_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
    select h.seen_at from public.bot_heartbeat h where h.id = 1;
$$;

comment on function bot_heartbeat() is
    'Время последнего сигнала от бота; пустой результат — бот ещё не запускался.';

revoke all on function bot_heartbeat() from public, anon;
grant execute on function bot_heartbeat() to authenticated, service_role;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('49_bot_heartbeat.sql');
