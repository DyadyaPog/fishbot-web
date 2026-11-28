-- Шаг 66: износ снаряжения порциями.
-- Левиафан бьёт по снаряжению атакующего сильнее обычного заброса, поэтому
-- decrease_durability получает p_amount: сколько прочности снять с каждой
-- надетой вещи. Вызов с четырьмя аргументами работает как раньше (одна
-- единица). Повтор того же origin_event_id по-прежнему не изнашивает дважды.
-- Запускать в Supabase → SQL Editor после 65_sell_all_loot.sql.

select assert_migration('66_decrease_durability_amount.sql');

-- Почему старая версия всё-таки удаляется.
--
-- Контракт старой версии сохранён: вызовы с 2, 3 и 4 аргументами работают как
-- раньше, недостающие значения берутся из defaults (p_amount = 1). Код бота
-- менять не нужно: вызов с четырьмя аргументами — это тот же самый износ на
-- единицу.
--
-- Но оставлять в базе обе версии нельзя: с двумя функциями одного имени вызов
-- с тремя аргументами подходит и той, и другой, и Postgres отвечает
-- «function decrease_durability(...) is not unique». Поэтому четырёхаргументная
-- перегрузка удаляется, а пятиаргументная становится единственной.
--
-- Более старые перегрузки (2 и 3 аргумента) на нормальной базе уже удалены
-- шагами 57/58; drop if exists ниже страхует базу, где эти шаги пропущены.
drop function if exists decrease_durability(bigint, bigint, boolean, text);
drop function if exists decrease_durability(bigint, bigint, boolean);
drop function if exists decrease_durability(bigint, bigint);

create or replace function decrease_durability(
    p_channel_id      bigint,
    p_user_id         bigint,
    p_skip_bait       boolean default false,
    p_origin_event_id text default null,
    p_amount          integer default 1
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row        inventory%rowtype;
    v_meta       jsonb;
    v_uses       numeric;
    v_max_uses   numeric;
    v_has_max    boolean;
    v_qty        integer;
    v_new_qty    integer;
    v_name       text;
    v_broken     jsonb := '[]'::jsonb;
    v_inserted   integer := 0;
    v_amount     integer := greatest(1, least(100, coalesce(p_amount, 1)));
begin
    -- Повтор того же сообщения не изнашивает снаряжение второй раз.
    if p_channel_id is not null
       and p_origin_event_id is not null and p_origin_event_id <> '' then
        insert into processed_message_actions (channel_id, user_id, action, origin_event_id)
        values (p_channel_id, p_user_id, 'decrease_durability', p_origin_event_id)
        on conflict do nothing;
        get diagnostics v_inserted = row_count;
        if v_inserted = 0 then
            return '[]'::jsonb;
        end if;
    end if;

    for v_row in
        select *
          from inventory
         where channel_id = p_channel_id
           and user_id    = p_user_id
           and is_equipped = true
           and item_type in ('rod', 'line', 'hook', 'bait')
         for update
    loop
        if p_skip_bait and v_row.item_type = 'bait' then
            continue;
        end if;

        v_meta := coalesce(v_row.meta, '{}'::jsonb);
        if jsonb_typeof(v_meta->'uses') <> 'number' then
            continue;
        end if;

        v_uses := (v_meta->>'uses')::numeric;
        if v_uses is null or v_uses = -1 or v_uses <= 0 then
            continue;
        end if;

        v_name := coalesce(v_meta->>'name', v_row.item_id);

        if jsonb_typeof(v_meta->'max_uses') = 'number' then
            v_max_uses := (v_meta->>'max_uses')::numeric;
        else
            v_max_uses := null;
        end if;
        v_has_max := v_max_uses is not null and v_max_uses > 0;

        v_qty := greatest(1, coalesce(v_row.quantity, 1));
        v_uses := v_uses - v_amount;

        if v_uses <= 0 then
            delete from inventory where id = v_row.id;
            v_broken := v_broken || jsonb_build_object(
                'name',              v_name,
                'item_id',           v_row.item_id,
                'item_type',         v_row.item_type,
                'remainingQuantity', 0,
                'uses',              0
            );
            continue;
        end if;

        if v_has_max then
            v_new_qty := greatest(1, ceil(v_uses / v_max_uses)::integer);
        else
            v_new_qty := v_qty;
        end if;

        v_meta := jsonb_set(v_meta, '{uses}', to_jsonb(v_uses));
        update inventory
           set meta       = v_meta,
               quantity   = v_new_qty,
               updated_at = now()
         where id = v_row.id;

        if v_has_max and v_new_qty < v_qty then
            v_broken := v_broken || jsonb_build_object(
                'name',              v_name,
                'item_id',           v_row.item_id,
                'item_type',         v_row.item_type,
                'remainingQuantity', v_new_qty,
                'uses',              v_max_uses
            );
        end if;
    end loop;

    return v_broken;
end $$;

comment on function decrease_durability(bigint, bigint, boolean, text, integer) is
    'Атомарный износ надетого снаряжения на p_amount единиц; повтор msg.id не изнашивает вещи второй раз.';

revoke all on function decrease_durability(bigint, bigint, boolean, text, integer) from public, anon;
grant execute on function decrease_durability(bigint, bigint, boolean, text, integer) to service_role;

select register_migration('66_decrease_durability_amount.sql');
