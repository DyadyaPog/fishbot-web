-- ============================================================================
-- Шаг 4: аккаунты.
--
-- Одна строка на человека, независимо от числа каналов: связывает Twitch ID
-- игрока с пользователем Supabase Auth. Через эту таблицу RLS понимает,
-- чьи строки показывать, а claim_profile() привязывает профиль при входе.
--
-- Запускать в Supabase → SQL Editor. Скрипт идемпотентен.
-- ============================================================================

create table if not exists accounts (
    user_id    bigint      primary key,   -- числовой Twitch ID игрока
    auth_id    uuid        unique,        -- auth.users.id после входа через Twitch
    username   text,                      -- последний известный display name
    created_at timestamptz not null default now()
);

comment on table accounts is
    'Twitch ID ↔ Supabase Auth. auth_id заполняется при первом входе (claim_profile).';
