-- ============================================================================
-- Шаг 0: учёт миграций.
--
-- Зачем: файлы вида 23_shop_state.sql и 25_items_public.sql меняют одни и те
-- же функции. Если применить 17 ещё раз после 23, вернётся незагейченная
-- покупка артефакта, и магазин снова можно обойти. Поэтому каждый файл
-- начинается с assert_migration(...) и падает, если его уже применяли или
-- если в базе есть шаг новее.
--
-- Порядок запуска:
--   Новая (пустая) база:   00_schema_migrations.sql → 01…62 по порядку.
--   Начать с нуля:         00_reset_db.sql → 00 → 01…62.
--   База с ручными шагами: 00 → 00b_backfill_migrations.sql → только неотмеченные.
--
-- На пустой базе 00b не нужен: шаги сами отметятся при первом запуске.
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

-- Набор шагов для чистой базы: 42 файла. Номера idx сохранили исходные
-- значения, поэтому в списке есть пропуски — это шаги, которые целиком
-- переписаны более поздними и удалены (см. delete ниже). Следующий новый шаг
-- берёт idx 72: 65 занят шагом 63, 66 — шагом 64, 67 — шагом 65, 68 — шагом 66,
-- 69 — шагом 67, 70 — шагом 68, 71 — шагом 69.
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
    (15, '13_chances.sql'),
    (16, '14_chances_refresh.sql'),
    (17, '15_artifact_cleanse.sql'),
    (18, '16_artifact_catalog_grants.sql'),
    (20, '18_admin_grant_artifact.sql'),
    (22, '20_buy_item.sql'),
    (23, '21_repair.sql'),
    (25, '23_shop_state.sql'),
    (26, '24_hardening.sql'),
    (27, '25_items_public.sql'),
    (29, '27_equipment_modifiers.sql'),
    (30, '28_shop_items_modifiers.sql'),
    (31, '29_fish_collection.sql'),
    (34, '32_sell_bot_event.sql'),
    (37, '35_add_item_to_inventory.sql'),
    (38, '36_update_balance_increment_stats.sql'),
    (40, '38_extra_indexes.sql'),
    (48, '46_bot_access_and_hardening.sql'),
    (49, '47_bot_badge_rpc_hardening.sql'),
    (50, '48_bot_joined_at_cleanup.sql'),
    (51, '49_bot_heartbeat.sql'),
    (52, '50_player_feedback.sql'),
    (54, '52_fix_search_path.sql'),
    (55, '53_bot_channel_default_blocked.sql'),
    (57, '55_abyss.sql'),
    (58, '56_abyss_channel_config.sql'),
    (59, '57_zombie_write_idempotency.sql'),
    (61, '59_processed_message_actions_cleanup.sql'),
    (62, '60_player_catch_history.sql'),
    (64, '62_events_retention.sql'),
    (65, '63_player_buffs.sql'),
    (66, '64_leviathan.sql'),
    (67, '65_sell_all_loot.sql'),
    (68, '66_decrease_durability_amount.sql'),
    (69, '67_cast_pipeline.sql'),
    (70, '68_sell_all_loot_counters.sql'),
    (71, '69_sell_all_loot_instance_unique.sql')
on conflict (idx) do update set filename = excluded.filename;

-- Шаги, которых больше нет: их содержимое перенесено в более поздние файлы
-- (11→60, 12/22/30/54→32, 17→23, 19/26→28, 31/42/43 — реестр уникальных рыб
-- не нужен, 33 — legacy-поля не создаются вовсе, 34→57, 37 — функция без
-- вызовов, 39/40 — 60, 41 — индексы не создаются, 44→15, 45 — нечего
-- исправлять на чистой базе, 51→38, 58 — перегрузок нет, 61→60). На уже
-- применённой базе отметки в schema_migrations остаются, а из порядка
-- убираем только неприменённые.
delete from public.migration_order o
 where o.filename in (
     '11_dashboard_stats.sql',
     '12_sell.sql',
     '17_buy_artifact.sql',
     '19_shop_items.sql',
     '22_sell_quantity.sql',
     '26_shop_items_effects.sql',
     '30_hidden_sell_guard.sql',
     '31_unique_fish_claims.sql',
     '33_drop_legacy_fields.sql',
     '34_decrease_durability.sql',
     '37_get_inventory_with_prices.sql',
     '39_record_catch.sql',
     '40_record_catch_slim.sql',
     '41_trim_indexes.sql',
     '42_unique_fish_via_inventory.sql',
     '43_drop_unique_fish_index.sql',
     '44_artifact_roll_scalar_safe.sql',
     '45_jsonb_double_encode_fix.sql',
     '51_extra_indexes.sql',
     '54_artifact_no_full_refund.sql',
     '58_drop_legacy_write_signatures.sql',
     '61_catches_retention.sql'
 )
   and not exists (
       select 1 from public.schema_migrations m where m.filename = o.filename
   );

-- Отдельные 46–50 больше не существуют: шаги объединены в 46. Убираем их из
-- порядка, чтобы старый файл нельзя было случайно запустить после объединения.
-- Уже отмеченные в schema_migrations записи не трогаем.
delete from public.migration_order o
 where o.filename in (
     '46_streamer_bot_access.sql',
     '47_bot_channel_admin.sql',
     '48_bot_badge_access.sql',
     '49_identity_provider_id.sql',
     '50_channel_column_grants.sql'
 )
   and not exists (
       select 1 from public.schema_migrations m where m.filename = o.filename
   );

-- Шаги 63–64 (доступ кабинета к player_catch_history и его откат) удалены: вместе
-- они ничего не создают, поэтому для чистой установки не нужны. На базе, где
-- они применялись, состояние уже такое же — доступа к таблице нет. Отметки об
-- их запуске остаются в schema_migrations, а из порядка имена убираем совсем,
-- чтобы номер 65 достался следующему живому шагу.
delete from public.migration_order o
 where o.filename in (
     '63_player_catch_history_cabinet.sql',
     '64_revert_player_catch_history_cabinet.sql'
 );

-- Новый шаг: впишите строку в insert выше (idx 68 и далее) и создайте файл.
-- Файл, которого нет в списке, assert_migration не пропустит.

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
