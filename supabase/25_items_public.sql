-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('25_items_public.sql');

-- ============================================================================
-- Шаг 25: публичная витрина справочника items.
--
-- Раньше authenticated читал таблицу items целиком (политика «select true»):
-- вместе с витриной уходило всё, что в таблице есть и появится. Служебное поле
-- (дроп-шанс, закупочная цена, внутренний тег) стало бы публичным молча.
--
-- Теперь кабинет читает вьюху с нужными колонками, а сама таблица закрыта:
-- её видят только бот (service_role) и SECURITY DEFINER-функции
-- (shop_items, buy_item_impl, buy_artifact_impl, cleanse_artifact).
--
-- description включён в вьюху: кабинет показывает описание улова и предметов.
--
-- Запускать в Supabase → SQL Editor после 24_hardening.sql.
-- Скрипт идемпотентен.
-- ============================================================================

-- Представление работает с правами владельца (postgres): RLS на items его не
-- режет, но наружу уходят только перечисленные колонки.
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
    description
from public.items;

comment on view public.items_public is
    'Публичная часть справочника предметов для кабинета: только витринные колонки.';

revoke all on public.items_public from anon, authenticated;
grant select on public.items_public to authenticated;

-- Таблицу больше не читает ни кабинет, ни anon: только бот и definer-функции.
drop policy if exists "items: чтение" on public.items;
revoke all on public.items from anon, authenticated;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('25_items_public.sql');
