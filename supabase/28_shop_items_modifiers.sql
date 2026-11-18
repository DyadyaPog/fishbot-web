-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('28_shop_items_modifiers.sql');

-- ============================================================================
-- Шаг 28: витрина магазина отдаёт модификаторы снаряжения.
--
-- Добавляет в shop_items() колонки type_modifiers и rarity_modifiers, чтобы
-- кабинет показывал характеристики снаряжения (удочки, лески, крючки,
-- наживки) из справочника items, а не из дублированного конфига.
--
-- Запускать в Supabase → SQL Editor после 27_equipment_modifiers.sql.
-- Скрипт идемпотентен.
-- ============================================================================

drop function if exists shop_items(text);

create or replace function shop_items(p_rarity text default null)
returns table (
    item_id          text,
    name             text,
    rarity           text,
    price            integer,
    level_required   integer,
    kind             text,
    artifact_type    text,
    effects          jsonb,
    curse_effects    jsonb,
    curse_chance     numeric,
    type_modifiers   jsonb,
    rarity_modifiers jsonb
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
        coalesce(c.curse_chance, 0),
        coalesce(i.type_modifiers, '{}'::jsonb),
        coalesce(i.rarity_modifiers, '{}'::jsonb)
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
    'Витрина магазина по редкости: снаряжение и артефакты с ценой, уровнем, типом артефакта, возможными статами и модификаторами снаряжения.';

revoke all on function shop_items(text) from public;
grant execute on function shop_items(text) to anon, authenticated, service_role;

select register_migration('28_shop_items_modifiers.sql');
