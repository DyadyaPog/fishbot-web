-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('27_equipment_modifiers.sql');

-- ============================================================================
-- Шаг 27: модификаторы характеристик для снаряжения (удочки, лески, крючки,
-- наживки) в справочнике items и публичной витрине items_public.
--
-- Раньше модификаторы хранились в конфиге бота и дублировались во фронтенде.
-- Теперь бот синхронизирует их в items, а кабинет читает из items_public —
-- единый источник истины.
--
-- Запускать в Supabase → SQL Editor после 26_shop_items_effects.sql.
-- Скрипт идемпотентен.
-- ============================================================================

alter table public.items
    add column if not exists type_modifiers jsonb not null default '{}'::jsonb;

alter table public.items
    add column if not exists rarity_modifiers jsonb not null default '{}'::jsonb;

comment on column public.items.type_modifiers is
    'Модификаторы от типа снаряжения (рыба, трофей, мусор, тяжёлая рыба, скорость, шанс редкой рыбы, шанс редкого предмета и т.д.).';
comment on column public.items.rarity_modifiers is
    'Модификаторы от редкости снаряжения (по редкостям рыбы).';

-- Пересоздать публичную витрину, включив новые колонки.
drop view if exists public.items_public;

create view public.items_public as
select
    id,
    name,
    rarity,
    price,
    kind,
    level_required,
    max_uses,
    description,
    type_modifiers,
    rarity_modifiers
from public.items;

comment on view public.items_public is
    'Публичная часть справочника предметов для кабинета: только витринные колонки.';

revoke all on public.items_public from anon, authenticated;
grant select on public.items_public to authenticated;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('27_equipment_modifiers.sql');
