-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('35_add_item_to_inventory.sql');

-- ============================================================================
-- Шаг 35: атомарная вставка/обновление строки инвентаря.
--
-- Раньше бот делал SELECT существующей строки, а затем PATCH или INSERT —
-- два запроса на каждый улов. Теперь вся логика (поиск стака, увеличение
-- количества или вставка новой строки) выполняется одной транзакцией
-- в Postgres и возвращает jsonb с ok/кодом ошибки.
--
-- Запускать в Supabase → SQL Editor после 32_sell_bot_event.sql.
-- Скрипт идемпотентен.
-- ============================================================================

create or replace function add_item_to_inventory(
    p_channel_id      bigint,
    p_user_id         bigint,
    p_item_id         text,
    p_item_type       item_kind,
    p_quantity        integer,
    p_meta            jsonb,
    p_origin_event_id text,
    p_stack           boolean default true,
    p_is_equipped     boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_amount   integer := greatest(1, coalesce(p_quantity, 1));
    v_existing inventory%rowtype;
begin
    if p_stack then
        select *
          into v_existing
          from inventory
         where channel_id = p_channel_id
           and user_id    = p_user_id
           and item_id    = p_item_id
           and item_type  = p_item_type
         for update;

        if found then
            update inventory
               set quantity   = coalesce(quantity, 1) + v_amount,
                   updated_at = now()
             where id = v_existing.id;
            return jsonb_build_object('ok', true);
        end if;
    end if;

    insert into inventory (
        channel_id,
        user_id,
        item_id,
        item_type,
        quantity,
        meta,
        is_equipped,
        origin_event_id
    )
    values (
        p_channel_id,
        p_user_id,
        p_item_id,
        p_item_type,
        v_amount,
        coalesce(p_meta, '{}'::jsonb),
        coalesce(p_is_equipped, false),
        nullif(p_origin_event_id, '')
    );

    return jsonb_build_object('ok', true);
exception
    when others then
        return jsonb_build_object('ok', false, 'code', 'db_error', 'error', SQLERRM);
end $$;

comment on function add_item_to_inventory(bigint, bigint, text, item_kind, integer, jsonb, text, boolean, boolean) is
    'Атомарная вставка или увеличение стака предмета в инвентаре; ошибка возвращается как db_error.';

revoke all on function add_item_to_inventory(bigint, bigint, text, item_kind, integer, jsonb, text, boolean, boolean) from public, anon;
grant execute on function add_item_to_inventory(bigint, bigint, text, item_kind, integer, jsonb, text, boolean, boolean) to service_role;

select register_migration('35_add_item_to_inventory.sql');