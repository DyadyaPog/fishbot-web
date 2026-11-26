-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('55_abyss.sql');

-- ============================================================================
-- Шаг 55: эндгейм-механика «Бездна».
--
-- Механика целиком живёт в боте (src/engine/abyss.js + abyss.*.command.js),
-- здесь только данные:
--   abyss_seasons  — лестница сезонов канала: дно (depth_cap), сроки, статус;
--   abyss_progress — текущий спуск и рекорд игрока в сезоне (лестница);
--   abyss_wallets  — осколки: баланс, всего добыто, оплата лицензии;
--   abyss_dives    — журнал нырков для статистики и разбора баланса.
--
-- Бот подключается как service_role и обходит RLS; политик для
-- authenticated нет намеренно — данные Бездны кабинет ещё не читает.
--
-- Запускать в Supabase → SQL Editor после 54_artifact_no_full_refund.sql.
-- Перед запуском один раз выполните 00_schema_migrations.sql: он добавит файл
-- в migration_order. Скрипт идемпотентен.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Сезоны: одна активная запись на канал
-- ---------------------------------------------------------------------------

create table if not exists abyss_seasons (
    id          bigserial   primary key,
    channel_id  bigint      not null references channels(id) on delete cascade,
    season_no   integer     not null,
    depth_cap   integer     not null check (depth_cap between 1 and 200),
    status      text        not null default 'active' check (status in ('active', 'closed')),
    started_at  timestamptz not null default now(),
    ends_at     timestamptz,
    closed_at   timestamptz,
    cap_set_by  text,
    cap_reason  text,
    settings    jsonb       not null default '{}'::jsonb,
    unique (channel_id, season_no)
);

comment on table abyss_seasons is
    'Сезоны Бездны: дно канала (depth_cap), срок, кто и почему менял глубину.';

-- Один активный сезон на канал: иначе лестница удвоится.
create unique index if not exists uq_abyss_seasons_active
    on abyss_seasons (channel_id) where status = 'active';

create index if not exists idx_abyss_seasons_channel
    on abyss_seasons (channel_id, season_no desc);

-- ---------------------------------------------------------------------------
-- Прогресс: текущий спуск и рекорд игрока в сезоне
-- ---------------------------------------------------------------------------

create table if not exists abyss_progress (
    channel_id         bigint      not null references channels(id) on delete cascade,
    season_id          bigint      not null references abyss_seasons(id) on delete cascade,
    user_id            bigint      not null,
    depth              integer     not null default 0 check (depth >= 0),
    checkpoint         integer     not null default 0 check (checkpoint >= 0),
    best_depth         integer     not null default 0 check (best_depth >= 0),
    dives_today        integer     not null default 0 check (dives_today >= 0),
    dives_date         date,
    total_dives        integer     not null default 0 check (total_dives >= 0),
    breaks             integer     not null default 0 check (breaks >= 0),
    shards             integer     not null default 0 check (shards >= 0),
    next_dive_at       timestamptz,
    bottom_reached_at  timestamptz,
    surfaced_at        timestamptz,
    updated_at         timestamptz not null default now(),
    primary key (channel_id, season_id, user_id)
);

comment on table abyss_progress is
    'Лестница Бездны: текущая глубина, отметка, рекорд сезона, бюджет нырков и осколки игрока.';

create index if not exists idx_abyss_progress_leaderboard
    on abyss_progress (channel_id, season_id, best_depth desc, depth desc);

create index if not exists idx_abyss_progress_user
    on abyss_progress (channel_id, user_id, best_depth desc);

-- ---------------------------------------------------------------------------
-- Кошелёк: осколки и разовая лицензия на вход
-- ---------------------------------------------------------------------------

create table if not exists abyss_wallets (
    channel_id       bigint      not null references channels(id) on delete cascade,
    user_id          bigint      not null,
    balance          integer     not null default 0 check (balance >= 0),
    earned           integer     not null default 0 check (earned >= 0),
    spent            integer     not null default 0 check (spent >= 0),
    license_paid_at  timestamptz,
    updated_at       timestamptz not null default now(),
    primary key (channel_id, user_id)
);

comment on table abyss_wallets is
    'Осколки Бездны (валюта эндгейма) и отметка об оплате лицензии на канале.';

-- ---------------------------------------------------------------------------
-- Журнал нырков: сырьё для статистики и аудита экономики
-- ---------------------------------------------------------------------------

create table if not exists abyss_dives (
    id          bigserial   primary key,
    channel_id  bigint      not null,
    season_id   bigint      not null references abyss_seasons(id) on delete cascade,
    user_id     bigint      not null,
    message_id  text,
    depth_from  integer     not null,
    depth_to    integer     not null,
    result      text        not null check (result in ('ok', 'break', 'bottom')),
    risk        numeric(5,4) not null default 0,
    checkpoint  integer     not null default 0,
    shards      integer     not null default 0,
    item_id     text,
    created_at  timestamptz not null default now()
);

comment on table abyss_dives is
    'Журнал нырков Бездны: глубина до/после, риск, осколки и пойманная на глубине рыба.';

create index if not exists idx_abyss_dives_season
    on abyss_dives (channel_id, season_id, created_at desc);

create index if not exists idx_abyss_dives_user
    on abyss_dives (channel_id, season_id, user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Статистика сезона: агрегат по прогрессу, без отдельной таблицы
-- ---------------------------------------------------------------------------

create or replace view abyss_season_stats as
select s.id                                        as season_id,
       s.channel_id,
       s.season_no,
       s.depth_cap,
       s.status,
       s.started_at,
       s.ends_at,
       count(p.user_id)                            as divers,
       coalesce(sum(p.total_dives), 0)             as total_dives,
       coalesce(sum(p.breaks), 0)                  as total_breaks,
       coalesce(max(p.best_depth), 0)              as deepest,
       count(*) filter (where p.bottom_reached_at is not null) as bottom_reached,
       coalesce(sum(p.shards), 0)                  as shards_earned
  from abyss_seasons s
  left join abyss_progress p
         on p.season_id = s.id
        and p.channel_id = s.channel_id
 group by s.id;

comment on view abyss_season_stats is
    'Агрегаты сезона Бездны: участники, нырки, обрывы, глубина, взятое дно, осколки.';

-- ---------------------------------------------------------------------------
-- RLS и права
-- ---------------------------------------------------------------------------

alter table abyss_seasons  enable row level security;
alter table abyss_progress enable row level security;
alter table abyss_wallets  enable row level security;
alter table abyss_dives    enable row level security;

-- Политик нет: читает и пишет только бот (service_role обходит RLS).
grant select, insert, update, delete
    on abyss_seasons, abyss_progress, abyss_wallets, abyss_dives
    to service_role;

grant usage, select on sequence abyss_seasons_id_seq to service_role;
grant usage, select on sequence abyss_dives_id_seq   to service_role;

select register_migration('55_abyss.sql');
