-- ============================================================================
-- Шаг 1: типы предметов и общий справочник items.
--
-- Запускать в Supabase → SQL Editor. Скрипт идемпотентен.
-- Данные (177 предметов) заливаются отдельно: 02_items_seed.sql.
-- ============================================================================

-- Значения совпадают с src/config/constants.js бота (строчные).
do $$
begin
    create type item_kind as enum (
        'fish', 'treasure', 'trash',
        'rod', 'line', 'hook', 'bait',
        'artifact', 'consumable'
    );
exception
    when duplicate_object then null;
end $$;

-- Название, редкость и каталожная цена хранятся здесь, а не в inventory/catches.
create table if not exists items (
    id          text      primary key,
    name        text      not null,
    rarity      text      not null,
    price       integer   not null default 0,
    kind        item_kind not null,
    description text
);

create index if not exists idx_items_kind on items (kind);

-- Описание предмета для кабинета. Бот заполняет его при синхронизации каталога;
-- пустые значения допустимы: пользователь добавляет описания позже.
alter table if exists items add column if not exists description text;
