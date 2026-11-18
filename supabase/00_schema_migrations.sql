-- ============================================================================
-- Шаг 0: учёт миграций.
--
-- Зачем: файлы вида 17_buy_artifact.sql и 23_shop_state.sql меняют одни и те
-- же функции. Если применить 17 ещё раз после 23, вернётся незагейченная
-- покупка артефакта, и магазин снова можно обойти. Поэтому каждый файл
-- начинается с assert_migration(...) и падает, если его уже применяли или
-- если в базе есть шаг новее.
--
-- Порядок запуска:
--   Новая (пустая) база:   00_schema_migrations.sql → 01…25 по порядку.
--   Начать с нуля:         00_reset_db.sql → 00 → 01…25.
--   База с ручными шагами: 00 → 00b_backfill_migrations.sql → только неотмеченные.
--
-- На пустой базе 00b не нужен: 01…25 сами отметятся при первом запуске.
-- Запускать в Supabase → SQL Editor. Скрипт идемпотентен.
-- ============================================================================

create table if not exists public.schema_migrations (
    filename   text primary key,
    applied_at timestamptz not null default now()
);

comment on table public.schema_migrations is
    'Учёт применённых SQL-шагов: защита от повторного запуска старых файлов.';

-- Полный список шагов в порядке выполнения. Два шага с одним номером
-- (03_channels и 03_channels_seed) здесь разведены по индексу.
create table if not exists public.migration_order (
    idx      integer primary key,
    filename text not null unique
);

comment on table public.migration_order is
    'Порядок SQL-шагов по имени файла: по нему проверяется, не отстал ли файл.';

insert into public.migration_order (idx, filename) values
    (1,  '01_items.sql'),
    (2,  '02_items_seed.sql'),
    (3,  '03_channels.sql'),
    (4,  '03_channels_seed.sql'),
    (5,  '04_accounts.sql'),
    (6,  '05_players.sql'),
    (7,  '05_check_levels.sql'),
    (8,  '06_inventory.sql'),
    (9,  '07_catches.sql'),
    (10, '08_events.sql'),
    (11, '09_views.sql'),
    (12, '10_rls.sql'),
    (13, '11_dashboard_stats.sql'),
    (14, '12_sell.sql'),
    (15, '13_chances.sql'),
    (16, '14_chances_refresh.sql'),
    (17, '15_artifact_cleanse.sql'),
    (18, '16_artifact_catalog_grants.sql'),
    (19, '17_buy_artifact.sql'),
    (20, '18_admin_grant_artifact.sql'),
    (21, '19_shop_items.sql'),
    (22, '20_buy_item.sql'),
    (23, '21_repair.sql'),
    (24, '22_sell_quantity.sql'),
    (25, '23_shop_state.sql'),
    (26, '24_hardening.sql'),
    (27, '25_items_public.sql'),
    (28, '26_shop_items_effects.sql'),
    (29, '27_equipment_modifiers.sql'),
    (30, '28_shop_items_modifiers.sql')
on conflict (idx) do update set filename = excluded.filename;

-- Заглушки для следующих шагов: раскомментируйте и впишите имя файла, когда
-- он появится. Файл, которого нет в списке, assert_migration не пропустит.
--   ,(29, '27_next_step.sql')

-- ---------------------------------------------------------------------------
-- assert_migration(): «этот файл ещё не применяли и он не отстал от базы»
-- ---------------------------------------------------------------------------
-- p_repeatable = true — для файлов, которые по своей природе повторяемые
-- (сеяные справочники, проверки, выдача прав). Их можно запускать снова.
create or replace function assert_migration(
    p_filename   text,
    p_repeatable boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_idx     integer;
    v_applied boolean;
    v_max     integer;
begin
    select idx into v_idx
      from migration_order
     where filename = p_filename;

    if v_idx is null then
        raise exception
            'Файл % не описан в migration_order: добавьте его в 00_schema_migrations.sql.', p_filename
            using errcode = 'P0001';
    end if;

    select exists (
        select 1 from schema_migrations where filename = p_filename
    ) into v_applied;

    if v_applied then
        if p_repeatable then
            raise notice 'Миграция % уже применялась: повтор разрешён.', p_filename;
            return;
        end if;

        raise exception
            'Миграция % уже применена. Повторный запуск перезаписал бы более новые функции — остановлено.', p_filename
            using errcode = 'P0001';
    end if;

    select max(o.idx) into v_max
      from schema_migrations m
      join migration_order o on o.filename = m.filename;

    if v_max is not null and v_max > v_idx then
        raise exception
            'Миграция % — это шаг %, а в базе уже применён шаг %. Применяйте файлы по порядку: старый файл откатил бы новые правки.',
            p_filename, v_idx, v_max
            using errcode = 'P0001';
    end if;
end $$;

comment on function assert_migration(text, boolean) is
    'Проверка порядка: падает, если файл уже применён (или отстал от базы).';

-- ---------------------------------------------------------------------------
-- register_migration(): отметка «файл применён»
-- ---------------------------------------------------------------------------
create or replace function register_migration(p_filename text)
returns void
language sql
security definer
set search_path = public
as $$
    insert into schema_migrations (filename)
    values (p_filename)
    on conflict (filename) do nothing;
$$;

comment on function register_migration(text) is
    'Отмечает шаг как применённый; повторная отметка ничего не меняет.';

revoke all on function assert_migration(text, boolean) from public, anon, authenticated;
revoke all on function register_migration(text) from public, anon, authenticated;

revoke all on schema_migrations  from anon, authenticated;
revoke all on migration_order    from anon, authenticated;
grant select, insert on schema_migrations to service_role;
grant select on migration_order to service_role;

select register_migration('00_schema_migrations.sql');
