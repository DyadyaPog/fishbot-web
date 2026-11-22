-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('32_sell_bot_event.sql');

-- ============================================================================
-- Шаг 32: продажа из бота не пишет отдельное событие на каждую строку.
--
-- Раньше sell_item всегда вставлял строку events(type='inventory_sell').
-- Для !sell ALL это давало N записей на одну команду. Теперь при вызове от
-- service_role (бот) событие не пишется в SQL: бот сам собирает все проданные
-- строки и пишет одно агрегированное событие inventory_sell. Продажа из
-- кабинета (authenticated) по-прежнему логируется по одной строке.
--
-- Запускать в Supabase → SQL Editor после 31_unique_fish_claims.sql.
-- Скрипт идемпотентен.
-- ============================================================================

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

    -- Событие пишет только кабинет (продажа без message_id). Бот передаёт
    -- message_id и логирует продажу сам, одним агрегированным событием.
    if v_message_id is null then
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
    end if;

    return jsonb_build_object(
        'ok',       true,
        'gold',     v_price,
        'balance',  coalesce(v_balance, 0),
        'name',     v_item.name,
        'quantity', v_qty
    );
end $$;

comment on function sell_item(bigint, integer, text) is
    'Продаёт предмет (или часть стака) по правилам !sell. Тайная рыба не продаётся. Событие пишет только кабинет; бот логирует агрегированно.';

revoke all on function sell_item(bigint, integer, text) from public, anon;
grant execute on function sell_item(bigint, integer, text) to authenticated, service_role;

select register_migration('32_sell_bot_event.sql');