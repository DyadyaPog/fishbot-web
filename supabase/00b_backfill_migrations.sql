-- ============================================================================
-- Шаг 0b: отметить в учёте то, что уже есть в базе.
--
-- Если шаги выполняли до появления учёта, база о них не знает, и первый же
-- assert_migration решит, что можно запускать старый файл. Скрипт проверяет
-- фактическое наличие объектов и записывает только реально применённые шаги:
-- отсутствующие остаются неотмеченными, и их можно спокойно выполнить.
--
-- Запускать один раз, сразу после 00_schema_migrations.sql и до следующих шагов.
-- Безопасно запускать повторно: register_migration не создаёт дублей.
-- Ничего не создаёт и не меняет в схеме — только читает каталог.
-- ============================================================================

do $$
begin
    -- 01–08: таблицы и справочники.
    if to_regclass('public.items') is not null then
        perform register_migration('01_items.sql');
        if exists (select 1 from public.items limit 1) then
            perform register_migration('02_items_seed.sql');
        end if;
    end if;

    if to_regclass('public.channels') is not null then
        perform register_migration('03_channels.sql');
        if exists (select 1 from public.channels limit 1) then
            perform register_migration('03_channels_seed.sql');
        end if;
    end if;

    if to_regclass('public.accounts') is not null then
        perform register_migration('04_accounts.sql');
    end if;

    if to_regclass('public.players') is not null then
        perform register_migration('05_players.sql');
        perform register_migration('05_check_levels.sql');
    end if;

    if to_regclass('public.inventory') is not null then
        perform register_migration('06_inventory.sql');
    end if;

    if to_regclass('public.catches') is not null then
        perform register_migration('07_catches.sql');
    end if;

    if to_regclass('public.events') is not null then
        perform register_migration('08_events.sql');
    end if;

    -- 09–14: представления, RLS, дашборд, продажа, шансы.
    if to_regclass('public.my_channels') is not null then
        perform register_migration('09_views.sql');
    end if;

    if to_regprocedure('public.claim_profile()') is not null then
        perform register_migration('10_rls.sql');
    end if;

    if to_regprocedure('public.get_dashboard_stats(bigint)') is not null then
        perform register_migration('11_dashboard_stats.sql');
    end if;

    if to_regprocedure('public.sell_price_of(text,public.item_kind,jsonb,integer,timestamptz)') is not null then
        perform register_migration('12_sell.sql');
    end if;

    if to_regclass('public.player_chances') is not null then
        perform register_migration('13_chances.sql');
    end if;

    if to_regclass('public.chance_refresh_requests') is not null then
        perform register_migration('14_chances_refresh.sql');
    end if;

    -- 15–20: артефакты, витрина, покупка.
    if to_regprocedure('public.cleanse_artifact(bigint,text,text)') is not null then
        perform register_migration('15_artifact_cleanse.sql');
    end if;

    if to_regclass('public.artifact_catalog') is not null
       and has_table_privilege('service_role', 'public.artifact_catalog', 'insert') then
        perform register_migration('16_artifact_catalog_grants.sql');
    end if;

    if to_regprocedure('public.buy_artifact(text,bigint,bigint,text,text)') is not null
       or to_regprocedure('public.buy_artifact_impl(text,bigint,bigint,text,text)') is not null then
        perform register_migration('17_buy_artifact.sql');
    end if;

    if to_regprocedure('public.admin_grant_artifact(text,bigint,bigint,text,text)') is not null then
        perform register_migration('18_admin_grant_artifact.sql');
    end if;

    if to_regprocedure('public.shop_items(text)') is not null then
        perform register_migration('19_shop_items.sql');
    end if;

    if to_regprocedure('public.buy_item(text,bigint,bigint,integer,text,text,integer)') is not null
       or to_regprocedure('public.buy_item_impl(text,bigint,bigint,integer,text,text,integer)') is not null then
        perform register_migration('20_buy_item.sql');
    end if;

    -- 21–25: ремонт, продажа с количеством, магазин, безопасность, витрина.
    if to_regprocedure('public.repair_item(bigint,text)') is not null then
        perform register_migration('21_repair.sql');
    end if;

    if to_regprocedure('public.sell_item(bigint,integer,text)') is not null then
        perform register_migration('22_sell_quantity.sql');
    end if;

    if to_regclass('public.shop_state') is not null then
        perform register_migration('23_shop_state.sql');
    end if;

    if to_regclass('public.admin_audit_log') is not null then
        perform register_migration('24_hardening.sql');
    end if;

    if to_regclass('public.items_public') is not null then
        perform register_migration('25_items_public.sql');
    end if;
end $$;

-- Что в итоге считается применённым (неотмеченные шаги ещё нужно выполнить).
select o.idx,
       o.filename,
       case when m.filename is null then '— не применён' else '✓ применён' end as status
from migration_order o
left join schema_migrations m on m.filename = o.filename
order by o.idx;
