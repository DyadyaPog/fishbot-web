-- ============================================================================
-- Шаг 3 (продолжение): строки каналов.
--
-- Два канала, для которых у бота есть базы: fishBot/data/fishing_game_dyadyapog.db
-- и fishing_game_yui2d.db. Числовые ID получены публичным запросом Twitch по логину.
--
-- Запускать после 03_channels.sql. Повторный запуск обновляет логин и имя.
-- ============================================================================

insert into channels (id, login, display_name) values
    (47337460,   'dyadyapog', 'DyadyaPog'),
    (1093290248, 'yui2d',     'yui2D')
on conflict (id) do update set
    login        = excluded.login,
    display_name = excluded.display_name;
