-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('11_dashboard_stats.sql');

-- Агрегаты для панели управления (дашборд): суммарные уловы, число игроков,
-- суммарный доход по каналу. Используются ботом (service_role) вместо
-- локальной SQLite, чтобы цифры совпадали с данными в Supabase.
--
-- Применить один раз в SQL Editor Supabase после 01..10.

create or replace function get_dashboard_stats(p_channel_id bigint)
returns table (
    total_fish   bigint,
    user_count   bigint,
    total_revenue bigint
)
language sql
stable
as $$
    select
        coalesce((select sum(fish_caught) from players  where channel_id = p_channel_id), 0)::bigint,
        (select count(*)            from players  where channel_id = p_channel_id)::bigint,
        coalesce((select sum(price)         from catches  where channel_id = p_channel_id), 0)::bigint;
$$;

comment on function get_dashboard_stats(bigint) is
    'Агрегаты дашборда бота по каналу: уловы, игроки, доход.';
-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('11_dashboard_stats.sql');
