-- ============================================================================
-- Шаг 20: покупка снаряжения и админская выдача предметов в Postgres.
--
-- Покупка в боте (!buy) и выдача из админки раньше шли отдельными PATCH/POST
-- запросами: деньги могли списаться без предмета, а прочность считалась в JS.
-- Теперь проверка уровня, места в сумке, цены и прочности, списание монет,
-- запись в инвентарь, автоэкипировка и событие выполняются одной транзакцией.
--
-- Для прочности нужен max_uses: бот синхронизирует его из
-- fishing-equipment.json вместе с остальными полями items.
--
-- Запускать в Supabase → SQL Editor после 19_shop_items.sql. Скрипт идемпотентен.
-- ============================================================================

alter table items add column if not exists max_uses integer;

comment on column items.max_uses is
    'Заряды нового экземпляра снаряжения: -1 — без ограничения, null — не расходуется.';

-- ---------------------------------------------------------------------------
-- upsert_item_inventory(): общая запись предмета в инвентарь.
--
-- Заряды, метаданные и стекинг считаются здесь, чтобы правила прочности
-- не расходились между покупкой (!buy) и админской выдачей. Возвращает
-- jsonb с ok, inventoryId, meta, uses, existed (или кодом ошибки).
-- ---------------------------------------------------------------------------
create or replace function upsert_item_inventory(
    p_channel_id bigint,
    p_user_id    bigint,
    p_item       items,
    p_quantity   integer,
    p_message_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row     inventory%rowtype;
    v_exists  boolean := false;
    v_qty     integer := least(999, greatest(1, coalesce(p_quantity, 1)));
    v_uses    numeric;
    v_meta    jsonb;
    v_id      bigint;
begin
    if p_item.kind in ('rod', 'line', 'hook', 'bait')
       and p_item.max_uses is null then
        return jsonb_build_object(
            'ok', false,
            'code', 'missing_max_uses',
            'error', format(
                'У снаряжения «%s» не заданы заряды: каталог items не синхронизирован ботом (max_uses is null).',
                p_item.name
            ),
            'itemId', p_item.id
        );
    end if;

    if p_item.kind = 'consumable' then
        v_meta := jsonb_strip_nulls(jsonb_build_object(
            'name', p_item.name,
            'description', p_item.description,
            'rarity', p_item.rarity
        ));
        v_uses := null;
    else
        if p_item.max_uses = -1 then
            v_uses := -1;
        else
            v_uses := p_item.max_uses * v_qty;
        end if;

        v_meta := jsonb_strip_nulls(jsonb_build_object(
            'name', p_item.name,
            'price', p_item.price,
            'rarity', p_item.rarity,
            'uses', v_uses,
            'max_uses', p_item.max_uses
        ));
    end if;

    select * into v_row
    from inventory
    where channel_id = p_channel_id
      and user_id = p_user_id
      and item_id = p_item.id
      and item_type = p_item.kind
    order by id
    limit 1;

    v_exists := found;

    if v_exists then
        v_meta := coalesce(v_row.meta, '{}'::jsonb) || v_meta;

        if p_item.kind in ('rod', 'line', 'hook', 'bait')
           and p_item.max_uses is not null
           and p_item.max_uses > 0
           and jsonb_typeof(coalesce(v_row.meta, '{}'::jsonb) -> 'uses') = 'number'
           and ((v_row.meta ->> 'uses')::numeric) <> -1 then
            v_uses := ((v_row.meta ->> 'uses')::numeric) + p_item.max_uses * v_qty;
            v_meta := jsonb_set(v_meta, '{uses}', to_jsonb(v_uses));
        end if;

        update inventory
        set quantity = quantity + v_qty,
            meta = v_meta,
            updated_at = now()
        where id = v_row.id;

        v_id := v_row.id;
    else
        insert into inventory (
            channel_id,
            user_id,
            item_id,
            item_type,
            quantity,
            meta,
            origin_event_id
        )
        values (
            p_channel_id,
            p_user_id,
            p_item.id,
            p_item.kind,
            v_qty,
            v_meta,
            nullif(p_message_id, '')
        )
        returning id into v_id;
    end if;

    return jsonb_build_object(
        'ok', true,
        'inventoryId', v_id,
        'meta', v_meta,
        'uses', v_uses,
        'existed', v_exists
    );
end $$;

comment on function upsert_item_inventory(bigint, bigint, items, integer, text) is
    'Общая запись предмета в инвентарь: заряды, метаданные, стекинг.';

revoke all on function upsert_item_inventory(bigint, bigint, items, integer, text) from public;
grant execute on function upsert_item_inventory(bigint, bigint, items, integer, text) to service_role;

-- ---------------------------------------------------------------------------
-- buy_item(): покупка снаряжения
-- ---------------------------------------------------------------------------
-- p_inventory_limit передаёт бот: лимит слотов зависит от уровня, артефактов
-- и ручных настроек, которые бот уже посчитал. Кабинет (authenticated) этот
-- параметр игнорирует и получает лимит по уровню, чтобы его нельзя было завысить.

drop function if exists buy_item(text, bigint, bigint, integer, text, text, integer);

create or replace function buy_item(
    p_item_id         text,
    p_channel_id      bigint,
    p_user_id         bigint default null,
    p_quantity        integer default 1,
    p_username        text default null,
    p_message_id      text default null,
    p_inventory_limit integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_uid          uuid := auth.uid();
    v_role         text := auth.role();
    v_user_id      bigint;
    v_player       players%rowtype;
    v_item         items%rowtype;
    v_row          inventory%rowtype;
    v_exists       boolean := false;
    v_qty          integer;
    v_price        integer;
    v_total        integer;
    v_balance      integer;
    v_level        integer;
    v_limit        integer;
    v_slots        integer;
    v_uses         numeric;
    v_meta         jsonb;
    v_inventory_id bigint;
    v_result       jsonb;
begin
    if p_channel_id is null or p_item_id is null or btrim(p_item_id) = '' then
        return jsonb_build_object(
            'ok', false,
            'code', 'bad_request',
            'error', 'Нужны канал и предмет.'
        );
    end if;

    -- Кабинет вызывает RPC от имени вошедшего игрока; service_role — бот.
    if coalesce(v_role, '') = 'service_role' then
        v_user_id := p_user_id;
        if v_user_id is null then
            return jsonb_build_object(
                'ok', false,
                'code', 'bad_request',
                'error', 'Для service_role нужен p_user_id.'
            );
        end if;
    else
        if v_uid is null then
            raise exception 'требуется вход через Twitch' using errcode = '28000';
        end if;

        select a.user_id into v_user_id
        from accounts a
        where a.auth_id = v_uid;

        if not found then
            raise exception 'аккаунт не привязан к игроку' using errcode = '28000';
        end if;

        if p_user_id is not null and p_user_id <> v_user_id then
            raise exception 'нельзя купить предмет другому игроку' using errcode = '42501';
        end if;
    end if;

    v_qty := least(999, greatest(1, coalesce(p_quantity, 1)));

    select * into v_item
    from items
    where id = p_item_id
      and kind in ('rod', 'line', 'hook', 'bait');

    if not found then
        return jsonb_build_object(
            'ok', false,
            'code', 'not_found',
            'error', 'Предмет не найден в магазине снаряжения.'
        );
    end if;

    if v_item.rarity = 'starter' then
        return jsonb_build_object(
            'ok', false,
            'code', 'starter',
            'error', format('Предмет «%s» является стартовым и не может быть куплен.', v_item.name)
        );
    end if;

    select * into v_player
    from players
    where channel_id = p_channel_id
      and user_id = v_user_id
    for update;

    if not found then
        return jsonb_build_object(
            'ok', false,
            'code', 'player_not_found',
            'error', 'Игрок не найден на этом канале.'
        );
    end if;

    v_level := level_from_xp(v_player.xp);
    if v_level < greatest(1, coalesce(v_item.level_required, 1)) then
        return jsonb_build_object(
            'ok', false,
            'code', 'level_too_low',
            'error', format(
                '«%s» требует %s ур. Ваш уровень: %s.',
                v_item.name,
                greatest(1, coalesce(v_item.level_required, 1)),
                v_level
            ),
            'level', v_level,
            'requiredLevel', greatest(1, coalesce(v_item.level_required, 1))
        );
    end if;

    select * into v_row
    from inventory
    where channel_id = p_channel_id
      and user_id = v_user_id
      and item_id = v_item.id
      and item_type = v_item.kind
    order by id
    limit 1;

    v_exists := found;

    -- Лимит слотов считает бот (уровень, артефакты, ручные настройки).
    -- Клиенту кабинета доверять нельзя: он получает лимит по уровню.
    if coalesce(v_role, '') = 'service_role'
       and p_inventory_limit is not null
       and p_inventory_limit > 0 then
        v_limit := p_inventory_limit;
    else
        v_limit := 10 + least(10, greatest(0, v_level / 5));
    end if;

    if not v_exists then
        select count(*) into v_slots
        from inventory i
        where i.channel_id = p_channel_id
          and i.user_id = v_user_id
          and i.item_type <> 'artifact';

        if v_slots + 1 > v_limit then
            return jsonb_build_object(
                'ok', false,
                'code', 'no_space',
                'error', format('В инвентаре нет места! (Лимит: %s)', v_limit),
                'inventoryLimit', v_limit
            );
        end if;
    end if;

    v_price := greatest(0, coalesce(v_item.price, 0));
    v_total := v_price * v_qty;

    if v_player.balance < v_total then
        return jsonb_build_object(
            'ok', false,
            'code', 'insufficient_funds',
            'error', format(
                'Недостаточно средств! Нужно %s, а у вас %s.',
                v_total,
                v_player.balance
            ),
            'totalPrice', v_total,
            'balance', v_player.balance
        );
    end if;

    -- Заряды, метаданные и стекинг — в общей функции upsert_item_inventory.
    v_result := upsert_item_inventory(
        p_channel_id, v_user_id, v_item, v_qty, nullif(p_message_id, '')
    );

    if not (v_result->>'ok')::boolean then
        return v_result;
    end if;

    v_inventory_id := (v_result->>'inventoryId')::bigint;
    v_uses := case
        when v_result->>'uses' is null then null
        else (v_result->>'uses')::numeric
    end;

    -- Деньги списываем только после успешной записи в инвентарь.
    update players
    set balance = balance - v_total
    where channel_id = p_channel_id
      and user_id = v_user_id
    returning balance into v_balance;

    -- Снаряжение надевается сразу: сначала снимаем предмет того же слота,
    -- иначе уникальный индекс надетых предметов не даст записать новый.
    update inventory
    set is_equipped = false,
        updated_at = now()
    where channel_id = p_channel_id
      and user_id = v_user_id
      and item_type = v_item.kind
      and is_equipped
      and id <> v_inventory_id;

    update inventory
    set is_equipped = true,
        updated_at = now()
    where id = v_inventory_id;

    insert into events (channel_id, user_id, type, message_id, payload)
    values (
        p_channel_id,
        v_user_id,
        'purchase',
        nullif(p_message_id, ''),
        jsonb_strip_nulls(jsonb_build_object(
            'username', coalesce(nullif(p_username, ''), v_player.username),
            'itemId', v_item.id,
            'itemType', v_item.kind::text,
            'rarity', v_item.rarity,
            'quantity', v_qty,
            'price', v_price,
            'totalPrice', v_total,
            'uses', v_uses,
            'maxUses', v_item.max_uses,
            'equipped', true,
            'metadata', jsonb_build_object('name', v_item.name)
        ))
    );

    return jsonb_build_object(
        'ok', true,
        'inventoryId', v_inventory_id,
        'itemId', v_item.id,
        'name', v_item.name,
        'itemType', v_item.kind::text,
        'rarity', v_item.rarity,
        'quantity', v_qty,
        'price', v_price,
        'totalPrice', v_total,
        'balance', v_balance,
        'uses', v_uses,
        'maxUses', v_item.max_uses,
        'equipped', true
    );
end $$;

comment on function buy_item(text, bigint, bigint, integer, text, text, integer) is
    'Покупка снаряжения: уровень, место в сумке, деньги, заряды, инвентарь, экипировка и событие одной транзакцией.';

revoke all on function buy_item(text, bigint, bigint, integer, text, text, integer) from public;
grant execute on function buy_item(text, bigint, bigint, integer, text, text, integer)
    to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- admin_grant_item(): выдача предмета из админки
-- ---------------------------------------------------------------------------
-- Привилегированная операция: только серверный ключ бота. Предмет и его
-- прочность берутся из items, а не из запроса браузера.

drop function if exists admin_grant_item(text, bigint, bigint, integer, text, text);

create or replace function admin_grant_item(
    p_item_id    text,
    p_channel_id bigint,
    p_user_id    bigint,
    p_quantity   integer default 1,
    p_username   text default null,
    p_message_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_role         text := auth.role();
    v_player       players%rowtype;
    v_item         items%rowtype;
    v_row          inventory%rowtype;
    v_exists       boolean := false;
    v_qty          integer;
    v_uses         numeric;
    v_meta         jsonb;
    v_inventory_id bigint;
    v_result       jsonb;
begin
    if coalesce(v_role, '') <> 'service_role' then
        raise exception 'выдача предметов доступна только service_role'
            using errcode = '42501';
    end if;

    if p_channel_id is null
       or p_user_id is null
       or p_item_id is null
       or btrim(p_item_id) = '' then
        return jsonb_build_object(
            'ok', false,
            'code', 'bad_request',
            'error', 'Нужны канал, игрок и предмет.'
        );
    end if;

    v_qty := least(999, greatest(1, coalesce(p_quantity, 1)));

    select * into v_item
    from items
    where id = p_item_id
      and kind in ('rod', 'line', 'hook', 'bait', 'consumable');

    if not found then
        return jsonb_build_object(
            'ok', false,
            'code', 'not_found',
            'error', 'Предмет не найден в каталоге.'
        );
    end if;

    select * into v_player
    from players
    where channel_id = p_channel_id
      and user_id = p_user_id
    for update;

    if not found then
        return jsonb_build_object(
            'ok', false,
            'code', 'player_not_found',
            'error', 'Игрок не найден на этом канале.'
        );
    end if;

    -- Заряды, метаданные и стекинг — в общей функции upsert_item_inventory.
    v_result := upsert_item_inventory(
        p_channel_id, p_user_id, v_item, v_qty, nullif(p_message_id, '')
    );

    if not (v_result->>'ok')::boolean then
        return v_result;
    end if;

    v_inventory_id := (v_result->>'inventoryId')::bigint;
    v_uses := case
        when v_result->>'uses' is null then null
        else (v_result->>'uses')::numeric
    end;

    insert into events (channel_id, user_id, type, message_id, payload)
    values (
        p_channel_id,
        p_user_id,
        'admin_grant',
        nullif(p_message_id, ''),
        jsonb_strip_nulls(jsonb_build_object(
            'username', coalesce(nullif(p_username, ''), v_player.username),
            'itemId', v_item.id,
            'itemType', v_item.kind::text,
            'rarity', v_item.rarity,
            'quantity', v_qty,
            'uses', v_uses,
            'maxUses', v_item.max_uses,
            'metadata', jsonb_build_object(
                'name', v_item.name,
                'source', 'web_admin'
            )
        ))
    );

    return jsonb_build_object(
        'ok', true,
        'inventoryId', v_inventory_id,
        'itemId', v_item.id,
        'name', v_item.name,
        'itemType', v_item.kind::text,
        'rarity', v_item.rarity,
        'quantity', v_qty,
        'uses', v_uses,
        'maxUses', v_item.max_uses
    );
end $$;

comment on function admin_grant_item(text, bigint, bigint, integer, text, text) is
    'Админская выдача снаряжения или расходника: прочность из items, инвентарь и событие admin_grant.';

revoke all on function admin_grant_item(text, bigint, bigint, integer, text, text) from public;
grant execute on function admin_grant_item(text, bigint, bigint, integer, text, text)
    to service_role;
