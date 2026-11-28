-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('67_cast_pipeline.sql');

-- ============================================================================
-- Шаг 67: конвейер заброса — новые запросы без переписывания старых функций.
--
-- Что добавляется (новые имена, ничего не удаляется и не переопределяется):
--   ensure_player()   — игрок и accounts одним вызовом (было select → insert
--                       → update accounts: 2–3 запроса);
--   cast_bundle()     — игрок + инвентарь + активные баффы одним запросом
--                       (было getUser + getInventory + getActiveBuffs: 3);
--   resolve_cast()    — износ, предметы, улов, баланс одной транзакцией
--                       (было decrease_durability + add_item_to_inventory ×N
--                       + record_catch + update_balance: 4–6 запросов).
--
-- Важно: resolve_cast — тонкая обёртка над существующими функциями базы.
-- decrease_durability, add_item_to_inventory, update_balance и record_catch
-- остаются как есть и продолжают работать для старого кода бота. Поэтому
-- откат не требует миграции данных: новый путь пишет те же строки.
--
-- Запускать в Supabase → SQL Editor после 66_decrease_durability_amount.sql.
-- Перед запуском один раз выполните 00_schema_migrations.sql: он добавит файл
-- в migration_order. Скрипт идемпотентен.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Игрок: один upsert вместо «select, затем insert/update, затем accounts».
--
-- Попутно чинит гонку первого сообщения: два параллельных запроса больше не
-- пытаются вставить одну и ту же строку players двумя разными путями.
-- ---------------------------------------------------------------------------
create or replace function ensure_player(
    p_channel_id bigint,
    p_user_id    bigint,
    p_username   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row     players%rowtype;
    v_existed boolean;
    v_name    text := nullif(btrim(coalesce(p_username, '')), '');
begin
    if p_channel_id is null or p_user_id is null then
        return jsonb_build_object('ok', false, 'code', 'bad_request');
    end if;

    -- Один лишний SELECT внутри той же функции: лишнего round-trip нет,
    -- зато «создан ли игрок» определяется однозначно.
    select exists (
        select 1 from players
        where channel_id = p_channel_id and user_id = p_user_id
    ) into v_existed;

    insert into players (channel_id, user_id, username)
    values (p_channel_id, p_user_id, v_name)
    on conflict (channel_id, user_id) do update
       set username = coalesce(excluded.username, players.username)
    returning * into v_row;

    -- accounts нужна для входа через Twitch в кабинете. Пишем только когда имя
    -- действительно изменилось: иначе это была бы запись на каждое сообщение.
    if v_row.username is not null then
        insert into accounts (user_id, username)
        values (p_user_id, v_row.username)
        on conflict (user_id) do update
           set username = excluded.username
         where accounts.username is distinct from excluded.username;
    end if;

    return jsonb_build_object(
        'ok',      true,
        'created', not v_existed,
        'player',  to_jsonb(v_row) || jsonb_build_object(
                       'level', level_from_xp(v_row.xp)
                   )
    );
end $$;

comment on function ensure_player(bigint, bigint, text) is
    'Возвращает/создаёт игрока канала и синхронизирует accounts: один вызов вместо трёх запросов.';

revoke all on function ensure_player(bigint, bigint, text) from public, anon, authenticated;
grant execute on function ensure_player(bigint, bigint, text) to service_role;

-- ---------------------------------------------------------------------------
-- Всё, что нужно прочитать до ролла лута, — одним ответом.
--
-- Состав намеренно совпадает с тем, что бот читает сейчас по частям:
--   player    — players (mapPlayer: user_id, username, balance, xp, fish_caught);
--   inventory — те же колонки, что в getInventory, порядок по id;
--   buffs     — те же строки и тот же фильтр ends_at > now(), что в getActiveBuffs.
-- Запрос к Левиафану сюда не входит: у события своё одно чтение состояния
-- (leviathanGetState), и дублировать его здесь значило бы держать две копии
-- одного CTE. Оно и так занимает один round-trip.
-- ---------------------------------------------------------------------------
create or replace function cast_bundle(
    p_channel_id bigint,
    p_user_id    bigint
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
    select jsonb_build_object(
        'player', (
            select to_jsonb(p) || jsonb_build_object('level', level_from_xp(p.xp))
              from players p
             where p.channel_id = p_channel_id
               and p.user_id    = p_user_id
        ),
        'inventory', coalesce((
            select jsonb_agg(to_jsonb(i) order by i.id)
              from inventory i
             where i.channel_id = p_channel_id
               and i.user_id    = p_user_id
        ), '[]'::jsonb),
        'buffs', coalesce((
            select jsonb_agg(to_jsonb(b) order by b.stack_group)
              from player_buffs b
             where b.channel_id = p_channel_id
               and b.user_id    = p_user_id
               and b.ends_at    > now()
        ), '[]'::jsonb)
    );
$$;

comment on function cast_bundle(bigint, bigint) is
    'Игрок, инвентарь и активные баффы одним запросом: замена трёх чтений на горячем пути заброса.';

revoke all on function cast_bundle(bigint, bigint) from public, anon, authenticated;
grant execute on function cast_bundle(bigint, bigint) to service_role;

-- ---------------------------------------------------------------------------
-- Запись заброса одной транзакцией.
--
-- Бот передаёт уже вычисленный результат ролла (RNG остаётся в боте: он должен
-- быть воспроизводим по msg.id), а база применяет его целиком:
--   * износ надетого снаряжения  → decrease_durability(...)
--   * предметы (улов, двойной улов, расходник) → add_item_to_inventory(...)
--   * золото за заброс (артефакты) → update_balance(...)
--   * опыт, счётчик уловов, catches → record_catch(...)
--
-- p_origin — msg.id. Внешний ключ action = 'resolve_cast' плюс штатные ключи
-- вложенных функций дают две защиты: повтор сообщения не применит заброс ни
-- целиком, ни частично. При ошибке посередине откатывается всё: раньше могло
-- остаться «наживка списана, улов не записан».
--
-- p_items:   [{"item_id":"...","item_type":"fish","quantity":1,
--              "meta":{...},"origin_event_id":"... ",
--              "stack":false,"is_equipped":false}, ...]
-- p_catch:   {"item_id":null|"...","price":0,"xp":0,
--             "fish_delta":0,"catch_count":1}   (null — не писать улов)
-- p_balance: целое; 0 — не трогать баланс (update_balance не вызывается)
-- p_wear:    сколько прочности снять; 0 — не изнашивать (износ выключен)
-- ---------------------------------------------------------------------------
create or replace function resolve_cast(
    p_channel_id bigint,
    p_user_id    bigint,
    p_origin     text,
    p_items      jsonb   default '[]'::jsonb,
    p_catch      jsonb   default null,
    p_balance    integer default 0,
    p_wear       integer default 1,
    p_skip_bait  boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_inserted   integer := 0;
    v_wear       jsonb   := '[]'::jsonb;
    v_items_done jsonb   := '[]'::jsonb;
    v_balance    bigint  := null;
    v_item       jsonb;
    v_result     jsonb;
    v_ok         boolean;
begin
    if coalesce(auth.role(), '') <> 'service_role' then
        raise exception 'resolve_cast доступна только боту' using errcode = '42501';
    end if;

    if p_channel_id is null or p_user_id is null
       or p_origin is null or btrim(p_origin) = '' then
        return jsonb_build_object('ok', false, 'code', 'bad_request');
    end if;

    -- postgres.js отдаёт массив/объект как jsonb, но строку с JSON может
    -- упаковать вторым слоем (та же ловушка, что в шаге 45). Принимаем оба вида.
    if p_items is not null and jsonb_typeof(p_items) = 'string' then
        p_items := (p_items #>> '{}')::jsonb;
    end if;
    if p_catch is not null and jsonb_typeof(p_catch) = 'string' then
        p_catch := (p_catch #>> '{}')::jsonb;
    end if;

    -- Ключ на весь заброс: повтор msg.id не применит ни износ, ни улов.
    insert into processed_message_actions (channel_id, user_id, action, origin_event_id)
    values (p_channel_id, p_user_id, 'resolve_cast', p_origin)
    on conflict do nothing;
    get diagnostics v_inserted = row_count;
    if v_inserted = 0 then
        return jsonb_build_object('ok', true, 'duplicate', true);
    end if;

    -- Износ: та же функция, что зовёт текущий код бота.
    if coalesce(p_wear, 0) > 0 then
        v_wear := decrease_durability(
            p_channel_id,
            p_user_id,
            coalesce(p_skip_bait, false),
            p_origin,
            greatest(1, p_wear)
        );
    end if;

    -- Предметы: порядок важен (улов, затем двойной улов, затем расходник),
    -- поэтому массив обрабатывается как есть.
    for v_item in
        select value from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
    loop
        v_result := add_item_to_inventory(
            p_channel_id,
            p_user_id,
            nullif(btrim(coalesce(v_item->>'item_id', '')), ''),
            coalesce(nullif(v_item->>'item_type', ''), 'fish')::item_kind,
            greatest(1, coalesce((v_item->>'quantity')::integer, 1)),
            coalesce(v_item->'meta', '{}'::jsonb),
            nullif(v_item->>'origin_event_id', ''),
            coalesce((v_item->>'stack')::boolean, true),
            coalesce((v_item->>'is_equipped')::boolean, false)
        );

        v_ok := coalesce((v_result->>'ok')::boolean, false);
        if not v_ok then
            raise exception 'resolve_cast: не удалось добавить предмет %: %',
                v_item->>'item_id', coalesce(v_result->>'error', 'без описания')
                using errcode = 'P0001';
        end if;

        v_items_done := v_items_done || jsonb_build_array(jsonb_build_object(
            'item_id',   v_item->>'item_id',
            'item_type', v_item->>'item_type'
        ));
    end loop;

    -- Золото артефактов за заброс (в т.ч. за пустой).
    if coalesce(p_balance, 0) <> 0 then
        v_balance := update_balance(p_channel_id, p_user_id, p_balance);
    end if;

    -- Улов: XP, счётчик рыб, журнал catches и история.
    if p_catch is not null then
        perform record_catch(
            p_channel_id,
            p_user_id,
            nullif(btrim(coalesce(p_catch->>'item_id', '')), ''),
            coalesce((p_catch->>'price')::integer, 0),
            coalesce((p_catch->>'xp')::integer, 0),
            coalesce((p_catch->>'fish_delta')::integer, 0),
            greatest(1, coalesce((p_catch->>'catch_count')::integer, 1)),
            p_origin
        );
    end if;

    return jsonb_build_object(
        'ok',        true,
        'duplicate', false,
        'wear',      coalesce(v_wear, '[]'::jsonb),
        'items',     v_items_done,
        'balance',   v_balance,
        'player', (
            select to_jsonb(p) || jsonb_build_object('level', level_from_xp(p.xp))
              from players p
             where p.channel_id = p_channel_id
               and p.user_id    = p_user_id
        )
    );
end $$;

comment on function resolve_cast(bigint, bigint, text, jsonb, jsonb, integer, integer, boolean) is
    'Применяет заброс целиком одной транзакцией (износ, предметы, золото, улов) через существующие функции; повтор msg.id не применяется.';

revoke all on function resolve_cast(bigint, bigint, text, jsonb, jsonb, integer, integer, boolean) from public, anon, authenticated;
grant execute on function resolve_cast(bigint, bigint, text, jsonb, jsonb, integer, integer, boolean) to service_role;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('67_cast_pipeline.sql');
