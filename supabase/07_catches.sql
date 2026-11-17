-- ============================================================================
-- Шаг 7: журнал уловов.
--
-- Строка = один выловленный предмет на канале. Название, редкость и вид берутся
-- из items; здесь только то, что относится к конкретному улову: цена продажи,
-- время и игрок. legacy_id — id из SQLite, чтобы перенос можно было повторить.
--
-- Запускать в Supabase → SQL Editor. Скрипт идемпотентен.
-- ============================================================================

create table if not exists catches (
    id          bigint      generated always as identity primary key,
    channel_id  bigint      not null,
    user_id     bigint      not null,
    item_id     text        not null references items (id),
    price       integer     not null default 0,
    caught_at   timestamptz not null default now(),
    legacy_id   bigint,
    constraint catches_player_fk
        foreign key (channel_id, user_id)
        references players (channel_id, user_id)
        on delete cascade,
    constraint catches_legacy_key unique (channel_id, legacy_id)
);

alter table catches add column if not exists legacy_id bigint;

comment on table catches is
    'Журнал уловов по каналам. Вид и редкость — в items, цена — фактическая цена улова.';

-- Журнал игрока: последние уловы в кабинете.
create index if not exists idx_catches_player
    on catches (channel_id, user_id, caught_at desc);

-- Лента канала (общая статистика, последние уловы).
create index if not exists idx_catches_channel
    on catches (channel_id, caught_at desc);
