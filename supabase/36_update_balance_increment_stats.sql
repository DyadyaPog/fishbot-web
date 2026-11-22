-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('36_update_balance_increment_stats.sql');

-- ============================================================================
-- Шаг 36: атомарное изменение баланса и статистики игрока.
--
-- Раньше бот читал старое значение, пытался обновить с проверкой по старому
-- значению и повторял попытку — 2 запроса на каждую операцию и риск гонок.
-- Теперь изменение выполняется одним UPDATE в Postgres, без чтения и без
-- оптимистической блокировки.
--
-- Запускать в Supabase → SQL Editor после 35_add_item_to_inventory.sql.
-- Скрипт идемпотентен.
-- ============================================================================

create or replace function update_balance(
    p_channel_id bigint,
    p_user_id    bigint,
    p_delta      integer
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
    v_balance bigint;
begin
    update players
       set balance = balance + coalesce(p_delta, 0)
     where channel_id = p_channel_id
       and user_id    = p_user_id
    returning balance into v_balance;

    return v_balance;
end $$;

comment on function update_balance(bigint, bigint, integer) is
    'Атомарно меняет баланс игрока на p_delta и возвращает новый баланс.';

revoke all on function update_balance(bigint, bigint, integer) from public, anon;
grant execute on function update_balance(bigint, bigint, integer) to service_role;

create or replace function increment_stats(
    p_channel_id bigint,
    p_user_id    bigint,
    p_xp_delta   integer,
    p_fish_delta integer
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    update players
       set xp          = xp + coalesce(p_xp_delta, 0),
           fish_caught = fish_caught + coalesce(p_fish_delta, 0)
     where channel_id = p_channel_id
       and user_id    = p_user_id;
end $$;

comment on function increment_stats(bigint, bigint, integer, integer) is
    'Атомарно увеличивает XP и счётчик уловов игрока.';

revoke all on function increment_stats(bigint, bigint, integer, integer) from public, anon;
grant execute on function increment_stats(bigint, bigint, integer, integer) to service_role;

select register_migration('36_update_balance_increment_stats.sql');