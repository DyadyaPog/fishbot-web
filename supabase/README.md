# SQL-шаги базы

Все файлы выполняются вручную в **Supabase → SQL Editor**, по одному, сверху вниз.
Каждый шаг начинается с `assert_migration(...)` и заканчивается `register_migration(...)`:
повторный запуск применённого файла падает с сообщением, а не откатывает новые функции.

## Порядок

| # | Файл | Что создаёт |
|---|---|---|
| R | `00_reset_db.sql` | **только для полного пересоздания**: сносит схему `public` целиком и возвращает права |
| 0 | `00_schema_migrations.sql` | учёт шагов: `schema_migrations`, `migration_order`, `assert/register_migration` |
| 0b | `00b_backfill_migrations.sql` | отмечает уже существующие шаги (по фактическому наличию объектов) |
| 1 | `01_items.sql` | таблица `items` |
| 2 | `02_items_seed.sql` | справочник предметов (повторяемый) |
| 3 | `03_channels.sql`, `03_channels_seed.sql` | каналы и их строки |
| 4 | `04_accounts.sql` | связка Twitch ID ↔ Supabase Auth |
| 5 | `05_players.sql`, `05_check_levels.sql` | игроки по каналам, функции уровня, проверка порогов |
| 6 | `06_inventory.sql` | инвентарь |
| 7 | `07_catches.sql` | журнал уловов |
| 8 | `08_events.sql` | события |
| 9 | `09_views.sql` | `my_channels`, `channel_ranking` |
| 10 | `10_rls.sql` | RLS, `claim_profile`, `equip_item`/`unequip_item` |
| 11 | `11_dashboard_stats.sql` | `get_dashboard_stats` |
| 12 | `12_sell.sql` | продажа из кабинета |
| 13 | `13_chances.sql` | `player_chances` |
| 14 | `14_chances_refresh.sql` | запросы на пересчёт шансов |
| 15 | `15_artifact_cleanse.sql` | каталог артефактов и очистка |
| 16 | `16_artifact_catalog_grants.sql` | права на каталог (повторяемый) |
| 17 | `17_buy_artifact.sql` | покупка артефакта |
| 18 | `18_admin_grant_artifact.sql` | админская выдача артефакта |
| 19 | `19_shop_items.sql` | витрина `shop_items` |
| 20 | `20_buy_item.sql` | покупка снаряжения, выдача предметов |
| 21 | `21_repair.sql` | ремонт снаряжения |
| 22 | `22_sell_quantity.sql` | продажа с количеством, цены для `!bag` |
| 23 | `23_shop_state.sql` | окно магазина артефактов, гейт в `buy_artifact` |
| 24 | `24_hardening.sql` | лимиты, журнал админки, RLS `shop_state`, рейтинг без Twitch ID, блокировки экипировки |
| 25 | `25_items_public.sql` | вьюха `items_public`, таблица `items` закрыта |
| 26 | `26_shop_items_effects.sql` | витрина `shop_items` отдаёт возможные статы артефактов |
| 27 | `27_equipment_modifiers.sql` | модификаторы снаряжения в `items` |
| 28 | `28_shop_items_modifiers.sql` | витрина отдаёт модификаторы снаряжения |
| 29 | `29_fish_collection.sql` | коллекция рыб, `image_path`, `my_caught_fish_ids` |
| 30 | `30_hidden_sell_guard.sql` | запрет продажи тайной рыбы в базе |
| 31 | `31_unique_fish_claims.sql` | реестр занятых уникальных тегов рыбы |
| 32 | `32_sell_bot_event.sql` | продажа из бота пишет одно агрегированное событие |
| 33 | `33_drop_legacy_fields.sql` | удаление полей переноса из SQLite |
| 34 | `34_decrease_durability.sql` | атомарный износ снаряжения |
| 35 | `35_add_item_to_inventory.sql` | атомарная вставка предмета и claim уникальной рыбы |
| 36 | `36_update_balance_increment_stats.sql` | атомарный баланс и статистика |
| 37 | `37_get_inventory_with_prices.sql` | инвентарь вместе с ценами продажи |

Чеклист по порядку — по строке на один запуск в SQL Editor:

```text
00_schema_migrations.sql
01_items.sql
02_items_seed.sql
03_channels.sql
03_channels_seed.sql
04_accounts.sql
05_players.sql
05_check_levels.sql
06_inventory.sql
07_catches.sql
08_events.sql
09_views.sql
10_rls.sql
11_dashboard_stats.sql
12_sell.sql
13_chances.sql
14_chances_refresh.sql
15_artifact_cleanse.sql
16_artifact_catalog_grants.sql
17_buy_artifact.sql
18_admin_grant_artifact.sql
19_shop_items.sql
20_buy_item.sql
21_repair.sql
22_sell_quantity.sql
23_shop_state.sql
24_hardening.sql
25_items_public.sql
26_shop_items_effects.sql
27_equipment_modifiers.sql
28_shop_items_modifiers.sql
29_fish_collection.sql
30_hidden_sell_guard.sql
31_unique_fish_claims.sql
32_sell_bot_event.sql
33_drop_legacy_fields.sql
34_decrease_durability.sql
35_add_item_to_inventory.sql
36_update_balance_increment_stats.sql
37_get_inventory_with_prices.sql
```

`00_reset_db.sql` и `00b_backfill_migrations.sql` в чеклист не входят: первый нужен
только при полном пересоздании, второй — только для базы с уже выполненными шагами.

## Три ситуации

**Новая (пустая) база.** `00` → `01…37` по порядку. `00b` не нужен.

**Решили начать с нуля.** Сначала `00_reset_db.sql` — он удаляет схему `public`
со всем содержимым и возвращает ей права Supabase, потом `00` → `01…37`.
Так база гарантированно соответствует файлам, без сверки того, что уже применено.
Данные пропадут; аккаунты Supabase Auth (схема `auth`) остаются, но связка
`accounts` (Twitch ID ↔ auth) создастся заново и её нужно будет заполнить входом в кабинет.

**База уже используется** (часть шагов выполняли когда-то руками). `00` → `00b`:
скрипт смотрит на реальные объекты и отмечает только то, что есть, после чего печатает
таблицу «применён / не применён». Дальше выполняются **только неотмеченные** файлы,
по возрастанию номера. Уже применённые шаги не запускать: `assert_migration` их всё равно
остановит, но лучше не доводить до ошибки.

Не путайте `00b` с «отметить всё»: отсутствующие шаги он не трогает специально —
иначе пропущенный шаг остался бы невыполненным, но закрытым от запуска.

Если разбираться, какие шаги уже сделаны, не хочется — берите `00_reset_db.sql`
и проходите `00` → `01…37` целиком.

## Проверка после запуска

Итоговый запрос: `✓` — на месте, `✗` — шаг не применён или права не те. Пустых `✗`
быть не должно.

```sql
with checks(name, ok) as (values
    ('таблица items',                     to_regclass('public.items') is not null),
    ('таблица channels',                  to_regclass('public.channels') is not null),
    ('таблица accounts',                  to_regclass('public.accounts') is not null),
    ('таблица players',                   to_regclass('public.players') is not null),
    ('таблица inventory',                 to_regclass('public.inventory') is not null),
    ('таблица unique_fish_claims',        to_regclass('public.unique_fish_claims') is not null),
    ('триггер inventory_unique_fish_claim', exists (
        select 1
        from pg_trigger t
        join pg_class c on c.oid = t.tgrelid
        where c.relname = 'inventory'
          and t.tgname = 'inventory_unique_fish_claim'
          and not t.tgisinternal
    )),
    ('функция update_balance(...)',       to_regprocedure('public.update_balance(bigint,bigint,integer)') is not null),
    ('функция increment_stats(...)',      to_regprocedure('public.increment_stats(bigint,bigint,integer,integer)') is not null),
    ('функция add_item_to_inventory(...)', to_regprocedure('public.add_item_to_inventory(bigint,bigint,text,public.item_kind,integer,jsonb,text,boolean,boolean)') is not null),
    ('функция decrease_durability(...)',  to_regprocedure('public.decrease_durability(bigint,bigint,boolean)') is not null),
    ('функция get_inventory_with_prices(...)', to_regprocedure('public.get_inventory_with_prices(bigint,bigint)') is not null),
    ('legacy_id удалён из inventory',     not exists (select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'inventory' and column_name = 'legacy_id')),
    ('таблица catches',                   to_regclass('public.catches') is not null),
    ('таблица events',                    to_regclass('public.events') is not null),
    ('таблица player_chances',            to_regclass('public.player_chances') is not null),
    ('таблица chance_refresh_requests',   to_regclass('public.chance_refresh_requests') is not null),
    ('таблица shop_state',                to_regclass('public.shop_state') is not null),
    ('таблица rate_limits',               to_regclass('public.rate_limits') is not null),
    ('таблица admin_audit_log',           to_regclass('public.admin_audit_log') is not null),
    ('вьюха my_channels',                 to_regclass('public.my_channels') is not null),
    ('вьюха channel_ranking',             to_regclass('public.channel_ranking') is not null),
    ('вьюха items_public',                to_regclass('public.items_public') is not null),

    ('claim_profile()',                   to_regprocedure('public.claim_profile()') is not null),
    ('equip_item(bigint,text)',           to_regprocedure('public.equip_item(bigint,text)') is not null),
    ('unequip_item(bigint,text)',         to_regprocedure('public.unequip_item(bigint,text)') is not null),
    ('get_dashboard_stats(bigint)',       to_regprocedure('public.get_dashboard_stats(bigint)') is not null),
    ('sell_price_of(...)',                to_regprocedure('public.sell_price_of(text,public.item_kind,jsonb,integer,timestamptz)') is not null),
    ('inventory_sell_prices(bigint,bigint)', to_regprocedure('public.inventory_sell_prices(bigint,bigint)') is not null),
    ('sell_item(bigint,integer,text)',    to_regprocedure('public.sell_item(bigint,integer,text)') is not null),
    ('repair_item(bigint,text)',          to_regprocedure('public.repair_item(bigint,text)') is not null),
    ('repair_cost_of(numeric,numeric,numeric)', to_regprocedure('public.repair_cost_of(numeric,numeric,numeric)') is not null),
    ('cleanse_artifact(bigint,text,text)', to_regprocedure('public.cleanse_artifact(bigint,text,text)') is not null),
    ('shop_items(text)',                  to_regprocedure('public.shop_items(text)') is not null),
    ('buy_item(...7 аргументов)',         to_regprocedure('public.buy_item(text,bigint,bigint,integer,text,text,integer)') is not null),
    ('buy_item_impl(...)',                to_regprocedure('public.buy_item_impl(text,bigint,bigint,integer,text,text,integer)') is not null),
    ('buy_artifact(text,bigint,bigint,text,text)', to_regprocedure('public.buy_artifact(text,bigint,bigint,text,text)') is not null),
    ('buy_artifact_impl(...)',            to_regprocedure('public.buy_artifact_impl(text,bigint,bigint,text,text)') is not null),
    ('admin_grant_artifact(...)',         to_regprocedure('public.admin_grant_artifact(text,bigint,bigint,text,text)') is not null),
    ('admin_grant_item(...)',             to_regprocedure('public.admin_grant_item(text,bigint,bigint,integer,text,text)') is not null),
    ('artifact_shop_open(bigint)',        to_regprocedure('public.artifact_shop_open(bigint)') is not null),
    ('set_artifact_shop_window(bigint,integer)', to_regprocedure('public.set_artifact_shop_window(bigint,integer)') is not null),
    ('log_admin_action(...)',             to_regprocedure('public.log_admin_action(text,bigint,bigint,text,text,jsonb)') is not null),
    ('take_rate_limit(...)',              to_regprocedure('public.take_rate_limit(bigint,text,integer,interval)') is not null),
    ('request_chances_refresh(bigint)',   to_regprocedure('public.request_chances_refresh(bigint)') is not null),

    -- нет дублей перегрузок: иначе PostgREST не сможет выбрать функцию
    ('sell_item без перегрузок', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'sell_item') = 1),
    ('buy_item без перегрузок', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'buy_item') = 1),
    ('buy_artifact без перегрузок', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'buy_artifact') = 1),
    ('inventory_sell_prices без перегрузок', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'inventory_sell_prices') = 1),

    -- доступы
    ('items закрыт для authenticated', case when to_regclass('public.items') is null then false
        else not has_table_privilege('authenticated', 'public.items', 'select') end),
    ('items_public открыт authenticated', case when to_regclass('public.items_public') is null then false
        else has_table_privilege('authenticated', 'public.items_public', 'select') end),
    ('buy_item_impl закрыт для authenticated', case when to_regprocedure('public.buy_item_impl(text,bigint,bigint,integer,text,text,integer)') is null then false
        else not has_function_privilege('authenticated', 'public.buy_item_impl(text,bigint,bigint,integer,text,text,integer)', 'execute') end),
    ('buy_artifact_impl закрыт для authenticated', case when to_regprocedure('public.buy_artifact_impl(text,bigint,bigint,text,text)') is null then false
        else not has_function_privilege('authenticated', 'public.buy_artifact_impl(text,bigint,bigint,text,text)', 'execute') end),
    ('get_dashboard_stats закрыт для authenticated', case when to_regprocedure('public.get_dashboard_stats(bigint)') is null then false
        else not has_function_privilege('authenticated', 'public.get_dashboard_stats(bigint)', 'execute') end),
    ('chance_refresh_requests закрыт для authenticated', case when to_regclass('public.chance_refresh_requests') is null then false
        else not has_table_privilege('authenticated', 'public.chance_refresh_requests', 'select') end),

    -- структура и политики
    ('channel_ranking без user_id', (select count(*) from information_schema.columns
        where table_schema = 'public' and table_name = 'channel_ranking' and column_name = 'user_id') = 0),
    ('политика shop_state по своим каналам', exists (select 1 from pg_policies
        where schemaname = 'public' and tablename = 'shop_state' and policyname = 'shop_state: чтение')),
    ('триггеры лимитов', (select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid
        where not t.tgisinternal and t.tgname in ('players_web_rate_limit', 'inventory_web_rate_limit')) = 2),
    ('shop_state в Realtime', exists (select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'shop_state'))
)
select case when ok then '✓' else '✗' end as result, name
from checks
order by ok, name;
```

Отдельно — что считается применённым:

```sql
select o.idx, o.filename, m.applied_at
from migration_order o
left join schema_migrations m on m.filename = o.filename
order by o.idx;
```

## Если шаг упал

- `Миграция … уже применена` — файл уже выполняли; ничего делать не нужно.
- `Миграция … это шаг N, а в базе уже применён шаг M` — вы запускаете старый файл поверх
  новых. Применяйте только файлы с бо́льшим номером.
- `function assert_migration(...) does not exist` — сначала `00_schema_migrations.sql`.
- `relation ... does not exist` внутри шага — пропущен предыдущий по номеру шаг: сверьтесь
  с таблицей выше и выполните недостающие.
