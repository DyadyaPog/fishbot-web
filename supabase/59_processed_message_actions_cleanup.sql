-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('59_processed_message_actions_cleanup.sql');

-- ============================================================================
-- Шаг 59: очистка старых ключей идемпотентности.
--
-- Таблица processed_message_actions растёт на каждый улов и каждый заброс.
-- Ключ нужен только пока сообщение Twitch может прийти повторно; через
-- 30 дней он бесполезен. Функция удаляет строки старше p_keep_days и
-- возвращает число удалённых — бот вызывает её на старте и раз в сутки.
--
-- Запускать в Supabase → SQL Editor после 57_zombie_write_idempotency.sql.
-- Перед запуском один раз выполните 00_schema_migrations.sql.
-- Скрипт идемпотентен.
-- ============================================================================

create or replace function cleanup_processed_message_actions(
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
    delete from processed_message_actions
     where created_at < now() - make_interval(days => v_days);
    get diagnostics v_deleted = row_count;
    return v_deleted;
end $$;

comment on function cleanup_processed_message_actions(integer) is
    'Удаляет ключи идемпотентности старше p_keep_days (по умолчанию 30) и возвращает число удалённых строк.';

revoke all on function cleanup_processed_message_actions(integer) from public, anon;
grant execute on function cleanup_processed_message_actions(integer) to service_role;

select register_migration('59_processed_message_actions_cleanup.sql');
