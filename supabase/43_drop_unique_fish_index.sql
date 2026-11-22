-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('43_drop_unique_fish_index.sql');

-- ============================================================================
-- Шаг 43: убираем partial unique index на inventory.
--
-- Уникальность теперь проверяется запросом по item_id + in-memory резерв,
-- без поля/индекса в таблице.
-- Запускать в Supabase → SQL Editor после 42_unique_fish_via_inventory.sql.
-- Скрипт идемпотентен.
-- ============================================================================

drop index if exists public.uq_inventory_unique_fish;

select register_migration('43_drop_unique_fish_index.sql');