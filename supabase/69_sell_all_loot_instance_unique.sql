-- Шаг 69: sell_all_loot уважает метку уникальности экземпляра.
--
-- sell.command.js считает рыбу уникальной по двум признакам: `metadata.unique`
-- в строке инвентаря и id из конфига. Первый пишет сам бот при улове
-- (fish.command.js), поэтому он есть даже там, где справочник `items` отстал:
-- у тайной рыбы `iuy` в конфиге стоит unique: true, а в items.is_unique — false
-- до ближайшей синхронизации каталога.
--
-- Проверка только по items.is_unique оставляла окно: уникальную рыбу можно
-- было продать, пока каталог не обновился. Здесь добавляется второй признак —
-- meta.unique, как в боте. Что продаётся и по какой цене, не меняется;
-- меняется только то, что защищённая рыба остаётся в сумке.
--
-- Запускать в Supabase → SQL Editor после 68_sell_all_loot_counters.sql.
-- Перед запуском один раз выполните 00_schema_migrations.sql.

select assert_migration('69_sell_all_loot_instance_unique.sql');

create or replace function sell_all_loot(
    p_channel_id bigint,
    p_user_id    bigint default null,   -- бот под service_role
    p_message_id text   default null    -- как у sell_item: null = кабинет
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_uid           uuid    := auth.uid();
    v_message_id    text    := case when auth.uid() is null then nullif(p_message_id, '') end;
    v_user          bigint;
    v_row           inventory%rowtype;
    v_total         integer := 0;
    v_sold          integer := 0;
    v_rows          integer := 0;
    v_fish          integer := 0;
    v_fish_gold     integer := 0;
    v_treasure      integer := 0;
    v_treasure_gold integer := 0;
    v_unique        integer := 0;
    v_hidden        integer := 0;
    v_balance       integer;
    v_meta          jsonb;
    v_qty           integer;
    v_price         integer;
    v_items         jsonb   := '[]'::jsonb;
begin
    -- Игрок: бот присылает p_user_id, кабинет определяется по auth.uid().
    if coalesce(auth.role(), '') = 'service_role' then
        v_user := p_user_id;
    else
        select a.user_id into v_user
        from accounts a
        where a.auth_id = v_uid;
    end if;

    if v_user is null then
        raise exception 'требуется вход через Twitch' using errcode = '28000';
    end if;

    -- Что остаётся в сумке. Признаки уникальности — как в боте: справочник
    -- items.is_unique или метка экземпляра meta.unique. Сначала уникальные,
    -- тайные — из остатка: так же считает sell.command.js.
    select count(*) filter (
               where it.rarity = 'hidden'
                 and not coalesce(it.is_unique, false)
                 and coalesce(i.meta->>'unique', 'false') <> 'true'
           ),
           count(*) filter (
               where coalesce(it.is_unique, false)
                  or coalesce(i.meta->>'unique', 'false') = 'true'
           )
      into v_hidden, v_unique
      from inventory i
      join items it on it.id = i.item_id
     where i.channel_id = p_channel_id
       and i.user_id    = v_user
       and i.item_type in ('fish', 'treasure')
       and not i.is_equipped;

    for v_row in
        select i.*
          from inventory i
          join items it on it.id = i.item_id
         where i.channel_id = p_channel_id
           and i.user_id    = v_user
           and i.item_type in ('fish', 'treasure')
           and not i.is_equipped
           and it.rarity is distinct from 'hidden'
           and not coalesce(it.is_unique, false)
           and coalesce(i.meta->>'unique', 'false') <> 'true'
         order by i.id
         for update of i
    loop
        v_meta  := coalesce(v_row.meta, '{}'::jsonb);
        v_qty   := greatest(1, coalesce(v_row.quantity, 1));
        v_price := sell_price_of(v_row.item_id, v_row.item_type, v_meta, v_qty, v_row.created_at);

        delete from inventory where id = v_row.id;

        v_total := v_total + v_price;
        v_sold  := v_sold + v_qty;
        v_rows  := v_rows + 1;

        if v_row.item_type = 'fish' then
            v_fish      := v_fish + v_qty;
            v_fish_gold := v_fish_gold + v_price;
        else
            v_treasure      := v_treasure + v_qty;
            v_treasure_gold := v_treasure_gold + v_price;
        end if;

        v_items := v_items || jsonb_build_object(
            'inventoryId', v_row.id,
            'itemId',      v_row.item_id,
            'itemType',    v_row.item_type,
            'quantity',    v_qty,
            'gold',        v_price
        );

        -- Событие пишет только кабинет. Бот передаёт message_id и логирует
        -- продажу сам, одним агрегированным inventory_sell.
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
                    'source',      'web'
                ))
            );
        end if;
    end loop;

    -- Баланс — одним обновлением на всю продажу.
    if v_rows > 0 then
        update players p
           set balance = p.balance + v_total
         where p.channel_id = p_channel_id
           and p.user_id    = v_user
        returning p.balance into v_balance;
    end if;

    if v_balance is null then
        select p.balance into v_balance
        from players p
        where p.channel_id = p_channel_id
          and p.user_id    = v_user;
    end if;

    return jsonb_build_object(
        'ok',      true,
        'sold',    v_sold,
        'rows',    v_rows,
        'gold',    v_total,
        'balance', coalesce(v_balance, 0),
        'by_type', jsonb_build_object(
            'fish',     jsonb_build_object('count', v_fish,     'gold', v_fish_gold),
            'treasure', jsonb_build_object('count', v_treasure, 'gold', v_treasure_gold)
        ),
        'items',   v_items,
        'skipped', jsonb_build_object('unique', v_unique, 'hidden', v_hidden)
    );
end $$;

comment on function sell_all_loot(bigint, bigint, text) is
    'Продаёт всю обычную рыбу и сокровища игрока (кроме уникальных и тайных), начисляет золото одним обновлением. Уникальность — по items.is_unique и meta.unique, как в sell.command.js.';

revoke all on function sell_all_loot(bigint, bigint, text) from public, anon;
grant execute on function sell_all_loot(bigint, bigint, text) to authenticated, service_role;

select register_migration('69_sell_all_loot_instance_unique.sql');
