-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('12_sell.sql');

-- ============================================================================
-- Шаг 12: продажа из кабинета.
--
-- Продажа — изменение денег игрока, поэтому она выполняется в базе, а не в
-- браузере: клиент передаёт только id строки инвентаря, а владельца, цену и
-- списание считает эта функция. Подделать цену или продать чужой предмет
-- через anon-ключ нельзя.
--
-- Цена считается один раз в sell_price_of() и используется и для выплаты
-- (sell_item), и для подписи в карточке (inventory_sell_prices) — браузер
-- больше ничего не досчитывает, поэтому показанная цена совпадает с выплатой.
--
-- Правила совпадают с !sell в боте:
--   * рыба, сокровища, мусор и расходники — фактическая цена из meta (или
--     каталожная из items) за штуку;
--   * снаряжение и артефакты — 50 % цены с учётом остатка прочности;
--   * неиспользованный предмет в первые 5 минут после покупки — 100 % цены;
--   * надетое и проклятое не продаётся.
--
-- Запускать в Supabase → SQL Editor. Скрипт идемпотентен.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- sell_price_of(): единственное место с правилами цены продажи
-- ---------------------------------------------------------------------------
-- Функция чистая: ничего не читает из аккаунта и не меняет данные, поэтому
-- её можно вызывать и для выплаты, и для предпросмотра цены в кабинете.

create or replace function sell_price_of(
    p_item_id     text,
    p_item_type   item_kind,
    p_meta        jsonb,
    p_quantity    integer,
    p_created_at  timestamptz
)
returns integer
language plpgsql
stable
set search_path = public
as $$
declare
    v_meta      jsonb   := coalesce(p_meta, '{}'::jsonb);
    v_qty       integer := greatest(1, coalesce(p_quantity, 1));
    v_buyback   boolean := p_item_type in ('rod', 'line', 'hook', 'bait', 'artifact');
    v_base      numeric;
    v_uses      numeric;
    v_max_uses  numeric;
    v_price     numeric;
begin
    -- В meta фактическая цена экземпляра (у рыбы — стоимость улова, у
    -- снаряжения — цена покупки). Нет её — берём каталожную из items.
    if jsonb_typeof(v_meta->'price') = 'number' then
        v_base := (v_meta->>'price')::numeric;
    else
        select i.price into v_base from items i where i.id = p_item_id;
        v_base := coalesce(v_base, 0);
    end if;

    if not v_buyback then
        return greatest(0, round(v_base * v_qty)::integer);
    end if;

    if jsonb_typeof(v_meta->'uses') = 'number' then
        v_uses := (v_meta->>'uses')::numeric;
    elsif jsonb_typeof(v_meta->'durability') = 'number' then
        v_uses := (v_meta->>'durability')::numeric;
    end if;
    if jsonb_typeof(v_meta->'max_uses') = 'number' then
        v_max_uses := (v_meta->>'max_uses')::numeric;
    end if;

    if (v_uses is null or v_uses = -1
        or (v_max_uses is not null and v_max_uses > 0 and v_uses >= v_max_uses * v_qty))
       and p_created_at >= now() - interval '5 minutes' then
        -- Ошибочная покупка: неиспользованный предмет возвращается по полной.
        v_price := v_base * v_qty;
    elsif v_max_uses is not null and v_max_uses > 0
          and v_uses is not null and v_uses <> -1 then
        v_price := v_base * 0.5 * (least(v_uses, v_qty * v_max_uses) / v_max_uses);
    else
        v_price := v_base * 0.5 * v_qty;
    end if;

    return greatest(0, round(v_price)::integer);
end $$;

comment on function sell_price_of(text, item_kind, jsonb, integer, timestamptz) is
    'Цена продажи предмета по правилам !sell: используется и для выплаты, и для подписи в кабинете.';

-- ---------------------------------------------------------------------------
-- inventory_sell_prices(): цены для карточек кабинета
-- ---------------------------------------------------------------------------
-- Возвращает цены только для строк текущего пользователя: браузер получает
-- те же числа, что начислит sell_item, и ничего не считает сам.

-- Пересоздаём: набор возвращаемых колонок мог отличаться в ранней версии.
drop function if exists inventory_sell_prices(bigint);

create or replace function inventory_sell_prices(p_channel_id bigint)
returns table (
    inventory_id   bigint,
    sell_price     integer,
    refund_ends_at timestamptz,
    server_now     timestamptz
)
language sql
security definer
stable
set search_path = public
as $$
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
       and exists (
           select 1 from accounts a
           where a.auth_id = auth.uid() and a.user_id = i.user_id
       );
$$;

comment on function inventory_sell_prices(bigint) is
    'Цены продажи предметов игрока на канале для отображения в кабинете.';

-- ---------------------------------------------------------------------------
-- sell_item(): продажа
-- ---------------------------------------------------------------------------

-- Пересоздаём: добавился p_message_id, а старая версия с одной колонкой
-- сделала бы вызов с одним аргументом неоднозначным.
drop function if exists sell_item(bigint);

create or replace function sell_item(p_inventory_id bigint, p_message_id text default null)
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
    v_item      items%rowtype;
    v_meta      jsonb;
    v_qty       integer;
    v_buyback   boolean;
    v_uses      numeric;
    v_max_uses  numeric;
    v_remaining numeric;
    v_price     integer;
    v_balance   integer;
begin
    if v_uid is null then
        raise exception 'требуется вход через Twitch' using errcode = '28000';
    end if;

    -- Строка инвентаря блокируется на время продажи, чтобы две вкладки
    -- не продали один предмет дважды.
    select i.* into v_row
      from inventory i
     where i.id = p_inventory_id
       and exists (
           select 1 from accounts a
           where a.auth_id = v_uid and a.user_id = i.user_id
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

    v_qty := greatest(1, coalesce(v_row.quantity, 1));
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

    -- Списание: у снаряжения с зарядами уменьшаем остаток, иначе удаляем строку.
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
        'gold',     v_price,
        'balance',  coalesce(v_balance, 0),
        'name',     v_item.name,
        'quantity', v_qty
    );
end $$;

comment on function sell_item(bigint, text) is
    'Продаёт предмет игрока по правилам !sell бота и возвращает начисленное золото.';

revoke all on function sell_price_of(text, item_kind, jsonb, integer, timestamptz) from public, anon;
revoke all on function inventory_sell_prices(bigint) from public, anon;
revoke all on function sell_item(bigint, text) from public, anon;

grant execute on function sell_price_of(text, item_kind, jsonb, integer, timestamptz) to authenticated;
grant execute on function inventory_sell_prices(bigint) to authenticated;
grant execute on function sell_item(bigint, text) to authenticated;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('12_sell.sql');
