-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('26_shop_items_effects.sql');

-- ============================================================================
-- Шаг 26: витрина магазина показывает возможные статы артефактов.
--
-- Раньше shop_items() отдавала только тип артефакта, и кабинет не мог показать
-- возможные эффекты до покупки. Теперь функция возвращает также effects и
-- curse_effects (диапазоны из artifact_catalog) и шанс проклятия — кабинет
-- рисует их фиолетовыми чипами, как у уже купленных артефактов.
--
-- Запускать в Supabase → SQL Editor после 25_items_public.sql.
-- Скрипт идемпотентен.
-- ============================================================================

drop function if exists shop_items(text);

create or replace function shop_items(p_rarity text default null)
returns table (
    item_id        text,
    name           text,
    rarity         text,
    price          integer,
    level_required integer,
    kind           text,
    artifact_type  text,
    effects        jsonb,
    curse_effects  jsonb,
    curse_chance   numeric
)
language sql
stable
security definer
set search_path = public
as $$
    select
        i.id,
        i.name,
        i.rarity,
        i.price,
        coalesce(i.level_required, 1),
        i.kind::text,
        c.artifact_type,
        coalesce(c.effects, '[]'::jsonb),
        coalesce(c.curse_effects, '[]'::jsonb),
        coalesce(c.curse_chance, 0)
    from items i
    left join artifact_catalog c on c.item_id = i.id
    where i.kind in ('rod', 'line', 'hook', 'bait', 'artifact')
      and (p_rarity is null or i.rarity = lower(p_rarity))
    order by
        case i.kind
            when 'rod' then 1
            when 'line' then 2
            when 'hook' then 3
            when 'bait' then 4
            when 'artifact' then 5
            else 6
        end,
        i.price,
        i.id;
$$;

comment on function shop_items(text) is
    'Витрина магазина по редкости: снаряжение и артефакты с ценой, уровнем, типом артефакта и возможными статами.';

revoke all on function shop_items(text) from public;
grant execute on function shop_items(text) to anon, authenticated, service_role;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('26_shop_items_effects.sql');
