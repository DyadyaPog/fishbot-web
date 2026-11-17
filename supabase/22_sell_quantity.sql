-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('22_sell_quantity.sql');

-- ============================================================================
-- Шаг 22: продажа с количеством и цены продажи для бота.
--
-- Раньше !sell считал цену и менял баланс в JS: несколько PATCH-запросов на
-- одну продажу могли оставить игрока без предмета или без денег. С шага 12
-- продажа идёт через sell_item, но только целиком. Здесь добавляется
-- количество (для стаков рыбы и наживки) и доступ к ценам из бота.
--
-- Запускать в Supabase → SQL Editor после 21_repair.sql. Скрипт идемпотентен.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- inventory_sell_prices(): цены для карточек кабинета и для !bag бота
-- ---------------------------------------------------------------------------
-- Кабинет передаёт только канал: владелец строк — вошедший игрок.
-- Бот (service_role) передаёт ещё и p_user_id: auth.uid() у серверного ключа
-- пустой, поэтому без параметра функция не нашла бы ни одной строки.

drop function if exists inventory_sell_prices(bigint);

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
           sell_price_of(i.item_id, i.item_type, i.meta, i.quantity, i.created_at),
           -- Когда заканчивается окно полного возврата: в этот момент цена
           -- снаряжения падает до 50 %, и кабинет пересчитывает подписи.
           case
               when i.item_type in ('rod', 'line', 'hook', 'bait', 'artifact')
                   then i.created_at + interval '5 minutes'
           end,
           -- Время базы: браузер считает задержку от него, а не от своих часов.
           now()
      from inventory i
     where i.channel_id = p_channel_id
       and i.user_id = v_user;
end $$;

comment on function inventory_sell_prices(bigint, bigint) is
    'Цены продажи предметов игрока на канале: для кабинета (свой игрок) и для !bag бота.';

-- ---------------------------------------------------------------------------
-- sell_item(): продажа предмета целиком или частью стака
-- ---------------------------------------------------------------------------

drop function if exists sell_item(bigint);
drop function if exists sell_item(bigint, text);

create or replace function sell_item(
    p_inventory_id bigint,
    -- null — продать всю строку: так продаёт кабинет, у которого нет выбора количества.
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
    -- Из кабинета message_id пустой; бот передаёт id исходного сообщения.
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

    -- Строка инвентаря блокируется на время продажи, чтобы две вкладки
    -- не продали один предмет дважды.
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

    v_meta := coalesce(v_row.meta, '{}'::jsonb);

    if v_row.item_type = 'artifact'
       and jsonb_typeof(v_meta->'cursed') = 'boolean'
       and (v_meta->>'cursed')::boolean then
        raise exception 'проклятый артефакт продать нельзя' using errcode = '22023';
    end if;

    v_available := greatest(1, coalesce(v_row.quantity, 1));
    -- Продать можно не больше, чем лежит в строке. 0/null — продать всё.
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

    -- Списание: у снаряжения с зарядами уменьшаем остаток, у остальных —
    -- количество, а при продаже всей строки удаляем её.
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
           set quantity   = v_available - v_qty,
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
    'Продаёт предмет (или часть стака) по правилам !sell и возвращает начисленное золото.';

revoke all on function inventory_sell_prices(bigint, bigint) from public, anon;
revoke all on function sell_item(bigint, integer, text) from public, anon;

grant execute on function inventory_sell_prices(bigint, bigint) to authenticated, service_role;
grant execute on function sell_item(bigint, integer, text) to authenticated, service_role;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('22_sell_quantity.sql');
