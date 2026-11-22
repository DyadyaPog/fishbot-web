-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('41_trim_indexes.sql');

-- ============================================================================
-- Шаг 41: чистка индексов — убираем неиспользуемые, добавляем полезный.
--
-- Запускать в Supabase → SQL Editor после 40_record_catch_slim.sql.
-- Скрипт идемпотентен.
-- ============================================================================

drop index if exists public.idx_items_rarity;
drop index if exists public.idx_inventory_item;
drop index if exists public.idx_inventory_player_created;
drop index if exists public.idx_inventory_meta_gin;
drop index if exists public.idx_catches_channel_item;
drop index if exists public.idx_unique_fish_claims_channel_tag;

create index if not exists idx_inventory_player_item
    on public.inventory (channel_id, user_id, item_id);

select register_migration('41_trim_indexes.sql');