-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('37_get_inventory_with_prices.sql');

-- ============================================================================
-- Шаг 37: инвентарь игрока вместе с ценами продажи в одном запросе.
--
-- Раньше !bag делал SELECT инвентаря и отдельный RPC inventory_sell_prices.
-- Теперь оба набора данных возвращаются одним вызовом: строка инвентаря
-- плюс цена, которую начислит sell_item. Это уменьшает число запросов к
-- API Gateway в два раза для команды инвентаря.
--
-- Запускать в Supabase → SQL Editor после 36_update_balance_increment_stats.sql.
-- Скрипт идемпотентен.
-- ============================================================================

create or replace function get_inventory_with_prices(
    p_channel_id bigint,
    p_user_id    bigint
)
returns table (
    id            bigint,
    user_id       bigint,
    item_id       text,
    item_type     item_kind,
    quantity      integer,
    meta          jsonb,
    is_equipped   boolean,
    created_at    timestamptz,
    expires_at    timestamptz,
    sell_price    integer
)
language sql
security definer
stable
set search_path = public
as $$
    select
        i.id,
        i.user_id,
        i.item_id,
        i.item_type,
        i.quantity,
        i.meta,
        i.is_equipped,
        i.created_at,
        i.expires_at,
        coalesce(sp.sell_price, 0)::integer as sell_price
      from inventory i
      left join inventory_sell_prices(p_channel_id, p_user_id) sp
        on sp.inventory_id = i.id
     where i.channel_id = p_channel_id
       and i.user_id    = p_user_id
     order by i.item_type, i.id;
$$;

comment on function get_inventory_with_prices(bigint, bigint) is
    'Инвентарь игрока с ценами продажи (один запрос вместо двух).';

revoke all on function get_inventory_with_prices(bigint, bigint) from public, anon;
grant execute on function get_inventory_with_prices(bigint, bigint) to service_role;

select register_migration('37_get_inventory_with_prices.sql');