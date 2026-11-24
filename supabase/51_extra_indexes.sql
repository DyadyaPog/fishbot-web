-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('51_extra_indexes.sql');

-- ============================================================================
-- Шаг 51: дополнительные индексы под горячие запросы бота.
--
-- Скрипт идемпотентен: использует create index if not exists.
-- ============================================================================

-- inventory: проверка занятости уникальной рыбы на канале (!fish, hasInventoryItem).
create index if not exists idx_inventory_channel_item
    on public.inventory (channel_id, item_id);

-- players: поиск игрока по нику на канале (админ-панель, getUserByUsername).
create index if not exists idx_players_channel_username_lower
    on public.players (channel_id, lower(username));

-- Отметка в учёте миграций.
select register_migration('51_extra_indexes.sql');