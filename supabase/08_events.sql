-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('08_events.sql');

-- ============================================================================
-- Шаг 8: события.
--
-- Одна таблица вместо artifact_events и будущих журналов: type описывает, что
-- произошло, а payload хранит подробности в jsonb. Так админ-выдача, покупка,
-- реролл и любые новые события живут в одном месте без правки схемы.
--
-- Запускать в Supabase → SQL Editor. Скрипт идемпотентен.
-- ============================================================================

create table if not exists events (
    id          bigint      generated always as identity primary key,
    channel_id  bigint      not null,
    user_id     bigint      not null,
    -- admin_grant, purchase, reroll_success и т.д. (eventType из бота)
    type        text        not null,
    -- id сообщения Twitch, к которому относится событие (UUID), если было.
    message_id  text,
    -- Остальные поля события: artifactId, artifactType, rarity, price,
    -- cursed, effects, metadata, username.
    payload     jsonb       not null default '{}'::jsonb,
    -- id строки в artifact_events SQLite: ключ повторного переноса.
    legacy_id   bigint,
    created_at  timestamptz not null default now(),
    constraint events_player_fk
        foreign key (channel_id, user_id)
        references players (channel_id, user_id)
        on delete cascade,
    constraint events_legacy_key unique (channel_id, legacy_id)
);

alter table events add column if not exists message_id text;
alter table events add column if not exists legacy_id   bigint;

comment on table events is
    'События канала: админ-выдача, покупки, рероллы и прочее. Детали — в payload.';
comment on column events.message_id is
    'id сообщения Twitch (UUID). Совпадает с inventory.origin_event_id при выдаче предмета.';

create index if not exists idx_events_player
    on events (channel_id, user_id, created_at desc);

create index if not exists idx_events_type
    on events (channel_id, type, created_at desc);

-- Поиск события по сообщению Twitch (связка с inventory.origin_event_id).
create index if not exists idx_events_message
    on events (channel_id, message_id);

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('08_events.sql');
