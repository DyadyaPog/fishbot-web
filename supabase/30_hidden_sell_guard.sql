-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('30_hidden_sell_guard.sql');

-- ============================================================================
-- Шаг 30: запрет продажи тайной рыбы на уровне базы.
--
-- Тайная рыба — пасхалка и коллекционный предмет, а не источник золота.
-- Бот уже не продаёт её через !sell, кабинет скрывает кнопку, но прямой вызов
-- RPC sell_item должен отказывать и сам. Этот шаг не меняет старую 22:
-- на базе, где 22 уже применён, достаточно выполнить только 30.
--
-- Запускать в Supabase → SQL Editor после 29_fish_collection.sql.
-- Скрипт идемпотентен.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- inventory_sell_prices(): не отдавать цену для тайной рыбы
-- ---------------------------------------------------------------------------
create or replace function inventory_sell_prices(
    p_channel_id bigint,
    p_user_id    bigint default null
)
returns table (
    inventory_id   bigint,
    sell_price     integer,
    refund_ends_at timestamptz,
    server_now     timestamptz
)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
    v_role text := auth.role();
    v_user bigint;
begin
    if coalesce(v_role, '') = 'service_role' then
        v_user := p_user_id;
    else
        select a.user_id into v_user
        from accounts a
        where a.auth_id = auth.uid();
    end if;

    if v_user is null then
        return;
    end if;

    return query
    select i.id,
           case
               when it.rarity = 'hidden' then null
               else sell_price_of(i.item_id, i.item_type, i.meta, i.quantity, i.created_at)
           end,
           case
               when i.item_type in ('rod', 'line', 'hook', 'bait', 'artifact')
                   then i.created_at + interval '5 minutes'
           end,
           now()
      from inventory i
      left join items it on it.id = i.item_id
     where i.channel_id = p_channel_id
       and i.user_id = v_user;
end $$;

comment on function inventory_sell_prices(bigint, bigint) is
    'Цены продажи предметов игрока на канале: для кабинета (свой игрок) и для !bag бота. Тайная рыба не продаётся.';

revoke all on function inventory_sell_prices(bigint, bigint) from public, anon;
grant execute on function inventory_sell_prices(bigint, bigint) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- sell_item(): отказ для тайной рыбы до расчёта цены
-- ---------------------------------------------------------------------------
create or replace function sell_item(
    p_inventory_id bigint,
    p_quantity     integer default null,
    p_message_id   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_uid        uuid := auth.uid();
    v_message_id text := case when auth.uid() is null then nullif(p_message_id, '') end;
    v_row        inventory%rowtype;
    v_item       items%rowtype;
    v_meta       jsonb;
    v_available  integer;
    v_qty        integer;
    v_buyback    boolean;
    v_uses       numeric;
    v_max_uses   numeric;
    v_remaining  numeric;
    v_price      integer;
    v_balance    integer;
begin
    if v_uid is null and auth.role() is distinct from 'service_role' then
        raise exception 'требуется вход через Twitch' using errcode = '28000';
    end if;

    select i.* into v_row
      from inventory i
     where i.id = p_inventory_id
       and (
           coalesce(auth.role(), '') = 'service_role'
           or exists (
               select 1 from accounts a
               where a.auth_id = v_uid and a.user_id = i.user_id
           )
       )
     for update;

    if not found then
        raise exception 'предмет не найден' using errcode = 'P0002';
    end if;

    if v_row.is_equipped then
        raise exception 'сначала снимите предмет' using errcode = '22023';
    end if;

    select * into v_item from items where id = v_row.item_id;
    if not found then
        raise exception 'предмет отсутствует в каталоге' using errcode = 'P0002';
    end if;

    -- Тайная редкость — пасхалка, а не источник золота.
    if v_item.rarity = 'hidden' then
        raise exception 'тайную рыбу продать нельзя' using errcode = '22023';
    end if;

    v_meta := coalesce(v_row.meta, '{}'::jsonb);

    if v_row.item_type = 'artifact'
       and jsonb_typeof(v_meta->'cursed') = 'boolean'
       and (v_meta->>'cursed')::boolean then
        raise exception 'проклятый артефакт продать нельзя' using errcode = '22023';
    end if;

    v_available := greatest(1, coalesce(v_row.quantity, 1));
    v_qty := case
        when p_quantity is null or p_quantity <= 0 then v_available
        else least(v_available, p_quantity)
    end;

    v_buyback := v_row.item_type in ('rod', 'line', 'hook', 'bait', 'artifact');
    v_price := sell_price_of(v_row.item_id, v_row.item_type, v_meta, v_qty, v_row.created_at);

    if jsonb_typeof(v_meta->'uses') = 'number' then
        v_uses := (v_meta->>'uses')::numeric;
    elsif jsonb_typeof(v_meta->'durability') = 'number' then
        v_uses := (v_meta->>'durability')::numeric;
    end if;
    if jsonb_typeof(v_meta->'max_uses') = 'number' then
        v_max_uses := (v_meta->>'max_uses')::numeric;
    end if;

    if v_buyback
       and v_max_uses is not null and v_max_uses > 0
       and v_uses is not null and v_uses <> -1 then
        v_remaining := v_uses - least(v_uses, v_qty * v_max_uses);

        if v_remaining <= 0 then
            delete from inventory where id = v_row.id;
        else
            update inventory
               set meta       = jsonb_set(v_meta, '{uses}', to_jsonb(v_remaining)),
                   quantity   = greatest(1, ceil(v_remaining / v_max_uses)::integer),
                   updated_at = now()
             where id = v_row.id;
        end if;
    elsif v_available > v_qty then
        update inventory
           set quantity = v_available - v_qty,
               updated_at = now()
         where id = v_row.id;
    else
        delete from inventory where id = v_row.id;
    end if;

    update players p
       set balance = p.balance + v_price
     where p.channel_id = v_row.channel_id
       and p.user_id    = v_row.user_id
    returning p.balance into v_balance;

    insert into events (channel_id, user_id, type, message_id, payload)
    values (
        v_row.channel_id, v_row.user_id, 'inventory_sell', v_message_id,
        jsonb_strip_nulls(jsonb_build_object(
            'inventoryId', v_row.id,
            'itemId',      v_row.item_id,
            'itemType',    v_row.item_type,
            'quantity',    v_qty,
            'gold',        v_price,
            'uses',        v_uses,
            'max_uses',    v_max_uses,
            'source',      case when v_message_id is null then 'web' else 'bot' end
        ))
    );

    return jsonb_build_object(
        'ok',       true,
        'gold',     v_price,
        'balance',  coalesce(v_balance, 0),
        'name',     v_item.name,
        'quantity', v_qty
    );
end $$;

comment on function sell_item(bigint, integer, text) is
    'Продаёт предмет (или часть стака) по правилам !sell и возвращает начисленное золото. Тайная рыба не продаётся.';

revoke all on function sell_item(bigint, integer, text) from public, anon;
grant execute on function sell_item(bigint, integer, text) to authenticated, service_role;

-- Отметка в учёте миграций.
select register_migration('30_hidden_sell_guard.sql');
