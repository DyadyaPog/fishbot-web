-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('39_record_catch.sql');

-- ============================================================================
-- Шаг 39: атомарная запись улова.
--
-- Объединяет increment_stats + logCatch (и опционально изменение баланса от
-- артефактов) в один запрос, чтобы сократить round-trip'ы в горячем пути !fish.
--
-- Запускать в Supabase → SQL Editor после 38_extra_indexes.sql.
-- Скрипт идемпотентен.
-- ============================================================================

create or replace function record_catch(
    p_channel_id      bigint,
    p_user_id         bigint,
    p_item_id         text,
    p_price           integer,
    p_xp_delta        integer,
    p_fish_delta      integer,
    p_catch_count     integer default 1
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_count integer := greatest(1, coalesce(p_catch_count, 1));
begin
    update players
       set xp          = xp + coalesce(p_xp_delta, 0),
           fish_caught = fish_caught + coalesce(p_fish_delta, 0)
     where channel_id = p_channel_id
       and user_id    = p_user_id;

    insert into catches (channel_id, user_id, item_id, price)
    select p_channel_id, p_user_id, coalesce(p_item_id, ''), coalesce(p_price, 0)
      from generate_series(1, v_count);
end $$;

comment on function record_catch(bigint, bigint, text, integer, integer, integer, integer) is
    'Атомарно обновляет статистику/баланс игрока и пишет записи в catches.';

revoke all on function record_catch(bigint, bigint, text, integer, integer, integer, integer) from public, anon;
grant execute on function record_catch(bigint, bigint, text, integer, integer, integer, integer) to service_role;

select register_migration('39_record_catch.sql');