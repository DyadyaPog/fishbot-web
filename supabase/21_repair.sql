-- ============================================================================
-- Шаг 21: ремонт снаряжения целиком в Postgres.
--
-- Раньше !repair списывал деньги отдельным updateBalance, а прочность писала
-- отдельным updateItemMetadata: при сбое между запросами игрок оставался без
-- денег или с бесплатным ремонтом. Теперь проверка износа, цена, списание
-- монет, запись прочности и событие выполняются одной транзакцией.
--
-- Правила совпадают с прежним !repair в боте:
--   * чинится только снаряжение с прочностью — удочка, леска, крючок;
--   * наживка расходуется, а артефакты прочности не имеют;
--   * ремонт стоит REPAIR_COST_COEFFICIENT (0.8) каталожной цены за пункт
--     прочности, итог округляется вверх.
--
-- Запускать в Supabase → SQL Editor после 20_buy_item.sql. Скрипт идемпотентен.
-- ============================================================================

-- Стоимость ремонта: доля каталожной цены за один пункт прочности.
-- Источник истины — здесь; бот больше не считает цену у себя.
create or replace function repair_cost_of(
    p_price    numeric,
    p_missing  numeric,
    p_max_uses numeric
)
returns integer
language sql
immutable
as $$
    select case
        when coalesce(p_max_uses, 0) <= 0 or coalesce(p_missing, 0) <= 0
            then 0
        else greatest(0, ceil(p_missing * coalesce(p_price, 0) / p_max_uses * 0.8)::integer)
    end;
$$;

comment on function repair_cost_of(numeric, numeric, numeric) is
    'Цена ремонта: 0.8 каталожной цены за пункт прочности, округление вверх.';

drop function if exists repair_item(bigint);

create or replace function repair_item(
    p_inventory_id bigint,
    p_message_id   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_role     text := auth.role();
    v_row      inventory%rowtype;
    v_item     items%rowtype;
    v_meta     jsonb;
    v_quantity integer;
    v_max_uses numeric;
    v_uses     numeric;
    v_full     numeric;
    v_missing  numeric;
    v_price    numeric;
    v_cost     integer;
    v_balance  integer;
    v_name     text;
begin
    -- Ремонт вызывает только бот: кабинет этой операции не предлагает.
    if coalesce(v_role, '') <> 'service_role' then
        raise exception 'ремонт доступен только service_role' using errcode = '42501';
    end if;

    select * into v_row
    from inventory
    where id = p_inventory_id
    for update;

    if not found then
        return jsonb_build_object(
            'ok', false,
            'code', 'not_found',
            'error', 'Предмет не найден в инвентаре.'
        );
    end if;

    if v_row.item_type not in ('rod', 'line', 'hook') then
        return jsonb_build_object(
            'ok', false,
            'code', 'not_repairable',
            'error', 'Чинится только удочка, леска и крючок.'
        );
    end if;

    select * into v_item from items where id = v_row.item_id;

    v_meta := coalesce(v_row.meta, '{}'::jsonb);
    v_quantity := greatest(1, coalesce(v_row.quantity, 1));

    -- Максимум зарядов: у экземпляра в meta, иначе каталожный из items.
    if jsonb_typeof(v_meta->'max_uses') = 'number' then
        v_max_uses := (v_meta->>'max_uses')::numeric;
    elsif v_item.max_uses is not null then
        v_max_uses := v_item.max_uses;
    end if;

    if v_max_uses is null or v_max_uses <= 0 then
        return jsonb_build_object(
            'ok', false,
            'code', 'not_repairable',
            'error', 'У предмета нет прочности — ремонтировать нечего.'
        );
    end if;

    if jsonb_typeof(v_meta->'uses') = 'number' then
        v_uses := (v_meta->>'uses')::numeric;
    elsif jsonb_typeof(v_meta->'durability') = 'number' then
        v_uses := (v_meta->>'durability')::numeric;
    end if;

    -- -1 — бесконечная прочность (стартовый набор), null — заряды не ведутся.
    if v_uses is null or v_uses = -1 then
        return jsonb_build_object(
            'ok', false,
            'code', 'no_damage',
            'error', 'Предмет не изношен.'
        );
    end if;

    -- Полный запас строки: заряд одного юнита × количество юнитов.
    v_full := v_max_uses * v_quantity;
    v_missing := greatest(0, v_full - least(v_uses, v_full));

    if v_missing <= 0 then
        return jsonb_build_object(
            'ok', false,
            'code', 'no_damage',
            'error', 'Предмет не изношен.'
        );
    end if;

    if jsonb_typeof(v_meta->'price') = 'number' then
        v_price := (v_meta->>'price')::numeric;
    else
        v_price := coalesce(v_item.price, 0);
    end if;

    v_cost := repair_cost_of(v_price, v_missing, v_max_uses);

    select p.balance into v_balance
    from players p
    where p.channel_id = v_row.channel_id
      and p.user_id = v_row.user_id
    for update;

    if v_balance is null then
        return jsonb_build_object(
            'ok', false,
            'code', 'player_not_found',
            'error', 'Игрок не найден на этом канале.'
        );
    end if;

    if v_balance < v_cost then
        return jsonb_build_object(
            'ok', false,
            'code', 'insufficient_funds',
            'error', format('Недостаточно средств на ремонт! Нужно %s, а у вас %s.', v_cost, v_balance),
            'cost', v_cost,
            'balance', v_balance
        );
    end if;

    update players
       set balance = balance - v_cost
     where channel_id = v_row.channel_id
       and user_id = v_row.user_id
    returning balance into v_balance;

    update inventory
       set meta = jsonb_set(v_meta, '{uses}', to_jsonb(v_full)),
           updated_at = now()
     where id = v_row.id;

    v_name := coalesce(v_meta->>'name', v_item.name, v_row.item_id);

    insert into events (channel_id, user_id, type, message_id, payload)
    values (
        v_row.channel_id,
        v_row.user_id,
        'inventory_repair',
        nullif(p_message_id, ''),
        jsonb_strip_nulls(jsonb_build_object(
            'inventoryId', v_row.id,
            'itemId',      v_row.item_id,
            'itemType',    v_row.item_type,
            'cost',        v_cost,
            'uses',        v_full,
            'max_uses',    v_max_uses,
            'source',      'bot'
        ))
    );

    return jsonb_build_object(
        'ok', true,
        'inventoryId', v_row.id,
        'itemId', v_row.item_id,
        'name', v_name,
        'cost', v_cost,
        'balance', v_balance,
        'uses', v_full,
        'maxUses', v_max_uses
    );
end $$;

comment on function repair_item(bigint, text) is
    'Ремонт снаряжения: проверка износа, цена, списание монет и запись прочности одной транзакцией.';

revoke all on function repair_cost_of(numeric, numeric, numeric) from public;
revoke all on function repair_item(bigint, text) from public, anon, authenticated;

grant execute on function repair_cost_of(numeric, numeric, numeric) to service_role;
grant execute on function repair_item(bigint, text) to service_role;
