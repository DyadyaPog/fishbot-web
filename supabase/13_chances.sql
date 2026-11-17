-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('13_chances.sql');

-- ============================================================================
-- Шаг 13: снимок шансов улова, который считает бот.
--
-- Шансы зависят от экипировки, артефактов и ручных настроек канала, поэтому
-- единственный источник правды — расчёт бота (riggingCalculator). Бот
-- складывает сюда готовые проценты, кабинет их только показывает и сам
-- ничего не пересчитывает.
--
-- Запускать в Supabase → SQL Editor. Скрипт идемпотентен.
-- ============================================================================

create table if not exists player_chances (
    channel_id bigint not null,
    user_id bigint not null,
    types jsonb not null default '{}'::jsonb,
    rarities_if_fish jsonb not null default '{}'::jsonb,
    updated_at timestamptz not null default now(),
    primary key (channel_id, user_id),
    constraint player_chances_player_fk
        foreign key (channel_id, user_id)
        references players (channel_id, user_id)
        on delete cascade
);

comment on table player_chances is
    'Шансы улова игрока на канале: снимок расчёта бота для кабинета.';

alter table player_chances enable row level security;

-- Игрок видит только свой снимок: тот же владелец, что у inventory.
drop policy if exists "player_chances: свой" on player_chances;
create policy "player_chances: свой" on player_chances
    for select to authenticated
    using (exists (
        select 1
        from accounts a
        where a.auth_id = (select auth.uid())
          and a.user_id = player_chances.user_id
    ));

revoke all on player_chances from anon, authenticated;
grant select on player_chances to authenticated;
grant select, insert, update, delete on player_chances to service_role;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('13_chances.sql');
