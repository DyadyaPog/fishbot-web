-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('33_drop_legacy_fields.sql');

-- ============================================================================
-- Шаг 33: удаление легаси-полей переноса из SQLite.
--
-- Поля legacy_id использовались только для повторного переноса данных из
-- старой SQLite-базы. После завершения переноса они не нужны: код бота и
-- кабинета их не использует. Удаляем колонки и связанные ограничения/индексы.
--
-- Запускать в Supabase → SQL Editor после 32_sell_bot_event.sql.
-- ВНИМАНИЕ: операция деструктивная, откатить колонки нельзя.
-- Скрипт идемпотентен.
-- ============================================================================

-- Уникальные ключи/индексы повторного переноса.
alter table if exists catches drop constraint if exists catches_legacy_key;
alter table if exists events drop constraint if exists events_legacy_key;
drop index if exists public.uq_inventory_legacy;

-- Легаси-колонки.
alter table if exists inventory drop column if exists legacy_id;
alter table if exists catches drop column if exists legacy_id;
alter table if exists events drop column if exists legacy_id;

-- Отметка в учёте миграций.
select register_migration('33_drop_legacy_fields.sql');