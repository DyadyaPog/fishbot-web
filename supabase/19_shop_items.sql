-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('19_shop_items.sql');

-- ============================================================================
-- Шаг 19: витрина магазина для бота и кабинета.
--
-- Запускать в Supabase → SQL Editor после 18_admin_grant_artifact.sql:
-- функция читает artifact_catalog, чтобы отдать тип артефакта. Скрипт идемпотентен.
--
-- shop_items(p_rarity) возвращает всё, что продаётся в магазинах: снаряжение
-- из items и артефакты с их типом. Бот использует функцию в !shop и
-- !artifacts, кабинет сможет читать её тем же запросом.
-- ============================================================================

-- Минимальный уровень покупки: у снаряжения и артефактов он свой,
-- остальным предметам он не нужен и остаётся 1.
alter table items add column if not exists level_required integer not null default 1;

comment on column items.level_required is
    'Минимальный уровень игрока для покупки. Синхронизируется ботом из fishing-equipment.json и artifacts.json.';

drop function if exists shop_items(text);

create or replace function shop_items(p_rarity text default null)
returns table (
    item_id        text,
    name           text,
    rarity         text,
    price          integer,
    level_required integer,
    kind           text,
    artifact_type  text
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
        c.artifact_type
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
    'Витрина магазина по редкости: снаряжение и артефакты с ценой, уровнем и типом артефакта.';

-- security definer читает artifact_catalog под владельцем функции: у anon
-- и authenticated прямого доступа к каталогу артефактов нет.
revoke all on function shop_items(text) from public;
grant execute on function shop_items(text) to anon, authenticated, service_role;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('19_shop_items.sql');
