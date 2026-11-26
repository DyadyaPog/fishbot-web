-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('56_abyss_channel_config.sql');

-- ============================================================================
-- Шаг 56: настройки Бездны на канал.
--
-- До этого шага все каналы играли по одному src/config/abyss.json. Теперь
-- канал может переопределить любое простое значение: лимит нырков, кривую
-- риска, осколки, лицензию, длину сезона. Бот хранит только отличия от
-- общего конфига, а итог считает слиянием (src/engine/abyssSettings.js).
--
-- Пустая таблица = канал играет по общему abyss.json.
--
-- Запускать в Supabase → SQL Editor после 55_abyss.sql.
-- Перед запуском один раз выполните 00_schema_migrations.sql: он добавит файл
-- в migration_order. Скрипт идемпотентен.
-- ============================================================================

create table if not exists abyss_channel_config (
    channel_id bigint      primary key references channels(id) on delete cascade,
    settings   jsonb       not null default '{}'::jsonb,
    updated_by text,
    updated_at timestamptz not null default now()
);

comment on table abyss_channel_config is
    'Переопределения настроек Бездны на канал: только отличия от src/config/abyss.json.';

alter table abyss_channel_config enable row level security;

-- Политик нет: читает и пишет только бот (service_role обходит RLS).
grant select, insert, update, delete on abyss_channel_config to service_role;

select register_migration('56_abyss_channel_config.sql');
