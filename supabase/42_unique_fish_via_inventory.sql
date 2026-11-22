-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('42_unique_fish_via_inventory.sql');

-- ============================================================================
-- Шаг 42: уникальные рыбы хранятся только в inventory.
--
-- Отдельная таблица unique_fish_claims и триггер claim_unique_fish удалены.
-- Вместо них — partial unique index на inventory: одна строка с непустым
-- meta.uniqueTag на (channel_id, item_id). Продажа/удаление inventory
-- автоматически освобождает слот (индексная запись исчезает).
--
-- Запускать в Supabase → SQL Editor после 41_trim_indexes.sql.
-- Скрипт идемпотентен.
-- ============================================================================

-- Триггер и функция больше не нужны.
drop trigger if exists inventory_unique_fish_claim on public.inventory;
drop function if exists public.claim_unique_fish();

-- Таблица claims удаляется; данные не переносим (backfill не нужен).
drop table if exists public.unique_fish_claims cascade;


select register_migration('42_unique_fish_via_inventory.sql');