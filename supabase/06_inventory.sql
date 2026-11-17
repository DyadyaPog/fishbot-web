-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('06_inventory.sql');

-- ============================================================================
-- Шаг 6: инвентарь.
--
-- Предметы принадлежат игроку на конкретном канале, поэтому ссылка составная:
-- (channel_id, user_id) -> players. Название, редкость и каталожная цена лежат
-- в items; в meta — только то, что меняется у конкретного экземпляра.
--
-- Запускать в Supabase → SQL Editor. Скрипт идемпотентен: если таблица уже
-- создана в ранней версии, колонки ниже добавятся через alter table.
-- ============================================================================

create table if not exists inventory (
    id              bigint      generated always as identity primary key,
    channel_id      bigint      not null,
    user_id         bigint      not null,
    item_id         text        not null references items (id),
    item_type       item_kind   not null,
    quantity        integer     not null default 1 check (quantity > 0),
    -- uses, max_uses, cursed, effects, failed_cleanses, weight,
    -- фактическая цена улова. Статичные поля (name/rarity/price) — в items.
    meta            jsonb       not null default '{}'::jsonb,
    is_equipped     boolean     not null default false,
    -- id сообщения Twitch, которым получен предмет (UUID), не внешний ключ.
    origin_event_id text,
    -- Срок годности наживки и расходников из старой базы.
    expires_at      timestamptz,
    -- id строки в SQLite: ключ повторного переноса, в вебе не используется.
    legacy_id       bigint,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now(),
    constraint inventory_player_fk
        foreign key (channel_id, user_id)
        references players (channel_id, user_id)
        on delete cascade
);

-- Догоняем колонки, если таблица была создана до появления переноса.
alter table inventory add column if not exists origin_event_id text;
alter table inventory add column if not exists expires_at      timestamptz;
alter table inventory add column if not exists legacy_id       bigint;
alter table inventory add column if not exists updated_at      timestamptz not null default now();

comment on table inventory is
    'Предметы игрока на канале. Статичные поля предмета — в items, переменные — в meta.';
-- Если колонка успела создаться как bigint (ранняя версия шага), переводим в text.
do $$
begin
    if exists (
        select 1
        from information_schema.columns
        where table_name = 'inventory'
          and column_name = 'origin_event_id'
          and data_type <> 'text'
    ) then
        alter table inventory alter column origin_event_id type text;
    end if;
end $$;

comment on column inventory.origin_event_id is
    'id сообщения Twitch (UUID), которым получен предмет; не ссылка на events.id.';
comment on column inventory.legacy_id is
    'id из inventory SQLite. Уникален в паре с channel_id, обеспечивает повторный перенос без дублей.';

-- Все предметы игрока на канале.
create index if not exists idx_inventory_player
    on inventory (channel_id, user_id);

-- На канале у игрока не больше одного надетого предмета каждого типа.
-- Дублирует проверку бота (equipItem снимает старый предмет того же слота).
create unique index if not exists uq_inventory_equipped
    on inventory (channel_id, user_id, item_type)
    where is_equipped;

-- Ключ повторного переноса из SQLite.
create unique index if not exists uq_inventory_legacy
    on inventory (channel_id, legacy_id);

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('06_inventory.sql');
