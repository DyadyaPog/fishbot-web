-- ============================================================================
-- Шаг 5: игроки по каналам + функции уровня.
--
-- Статы у каждого канала свои, поэтому ключ — пара (channel_id, user_id).
-- Уровень не хранится: считается из xp теми же формулами, что в боте
-- (LEVEL_XP_BASE = 100, LEVEL_XP_GROWTH = 1.15).
--
-- Запускать в Supabase → SQL Editor. Скрипт идемпотентен.
-- ============================================================================

-- Уровень по накопленному XP (та же кривая, что в src/db/database.js).
-- Оба логарифма считаются в double precision: иначе Postgres берёт ln(1.15)
-- как numeric, и на границах порога уровень получается на единицу меньше.
create or replace function level_from_xp(p_xp integer)
returns integer
language sql
immutable
as $$
    select floor(
        ln(greatest(coalesce(p_xp, 0), 0)::double precision / 100.0 + 1.0)
        / ln(1.15::double precision)
    )::integer + 1
$$;

-- Порог XP для уровня, с той же поправкой округления, что и xpForLevel() в боте.
create or replace function xp_for_level(p_level integer)
returns integer
language plpgsql
immutable
as $$
declare
    l integer := greatest(1, coalesce(p_level, 1));
    t integer;
begin
    if l = 1 then
        return 0;
    end if;

    t := greatest(0, round(100 * (power(1.15::numeric, l - 1) - 1))::integer);

    while t > 0 and level_from_xp(t - 1) >= l loop
        t := t - 1;
    end loop;
    while level_from_xp(t) < l loop
        t := t + 1;
    end loop;

    return t;
end $$;

create table if not exists players (
    channel_id  bigint      not null references channels (id) on delete cascade,
    user_id     bigint      not null,              -- Twitch ID игрока
    username    text,                              -- имя на момент последней синхронизации
    balance     integer     not null default 0,
    xp          integer     not null default 0 check (xp >= 0),
    fish_caught integer     not null default 0,
    primary key (channel_id, user_id)
);

comment on table players is
    'Игровое состояние игрока на конкретном канале. Уровень вычисляется из xp.';

-- Поиск всех каналов игрока (для селектора my_channels).
create index if not exists idx_players_user            on players (user_id);
-- Топ канала по балансу (для channel_ranking).
create index if not exists idx_players_channel_balance on players (channel_id, balance desc);
