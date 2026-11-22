-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('38_extra_indexes.sql');

-- ============================================================================
-- Шаг 38: дополнительные индексы под горячие запросы бота и кабинета.
--
-- Скрипт идемпотентен: использует create index if not exists.
-- ============================================================================

-- inventory: поиск предмета игрока (продажа, удаление, надевание).
create index if not exists idx_inventory_player_item
    on public.inventory (channel_id, user_id, item_id);

-- inventory: поиск экипированного предмета в слоте.
create index if not exists idx_inventory_player_equipped
    on public.inventory (channel_id, user_id, item_type)
    where is_equipped;

-- players: топы по fish_caught и xp на канале.
create index if not exists idx_players_channel_fish_caught
    on public.players (channel_id, fish_caught desc);
create index if not exists idx_players_channel_xp
    on public.players (channel_id, xp desc);


-- Отметка в учёте миграций.
select register_migration('38_extra_indexes.sql');