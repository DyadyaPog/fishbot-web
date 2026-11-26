-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('62_events_retention.sql');

-- ============================================================================
-- Шаг 62: срок хранения журнала событий.
--
-- events растёт на каждую покупку, продажу, выдачу и реролл: в payload лежат
-- подробности, а нужны они только последние дни (лента событий игрока в
-- кабинете показывает последние записи). Строки старше 30 дней бесполезны.
--
-- Функция удаляет их и возвращает число удалённых; бот вызывает её на старте
-- и раз в сутки тем же таймером, что и остальные чистки.
--
-- Запускать в Supabase → SQL Editor после 60_player_catch_history.sql.
-- Перед запуском один раз выполните 00_schema_migrations.sql. Скрипт идемпотентен.
-- ============================================================================

-- Удаление по сроку не должно читать таблицу целиком.
create index if not exists idx_events_created_at
    on public.events (created_at);

create or replace function cleanup_events(
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
    delete from events
     where created_at < now() - make_interval(days => v_days);
    get diagnostics v_deleted = row_count;
    return v_deleted;
end $$;

comment on function cleanup_events(integer) is
    'Удаляет события events старше p_keep_days (по умолчанию 30) и возвращает число удалённых строк.';

revoke all on function cleanup_events(integer) from public, anon;
grant execute on function cleanup_events(integer) to service_role;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('62_events_retention.sql');
