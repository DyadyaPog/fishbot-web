-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('29_fish_collection.sql');

-- ============================================================================
-- Шаг 29: коллекция рыб в кабинете.
--
-- Добавляет путь к картинке в справочник items и в публичную вьюху.
-- Картинки хранятся в репозитории (assets/fish-images), Storage не используется.
--
-- Запускать в Supabase → SQL Editor после 28_shop_items_modifiers.sql.
-- Скрипт идемпотентен.
-- ============================================================================

alter table if exists items add column if not exists image_path text;

-- Заполняем пути по умолчанию для рыб (только пустые), чтобы коллекция
-- работала сразу после применения миграции.
update public.items
   set image_path = 'assets/fish-images/' || id || '.webp'
 where kind = 'fish'
   and (image_path is null or btrim(image_path) = '');

-- Пересоздаём вьюху: create or replace view не умеет добавлять колонки.
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
    rarity_modifiers,
    image_path
from public.items;

comment on view public.items_public is
    'Публичная часть справочника предметов для кабинета: только витринные колонки (включая image_path).';

revoke all on public.items_public from anon, authenticated;
grant select on public.items_public to authenticated;

-- RPC my_caught_fish_ids() живёт в шаге 60 рядом с историей уловов: коллекция
-- считается по счётчикам, а не по сырому журналу catches.

-- Отметка в учёте миграций.
select register_migration('29_fish_collection.sql');