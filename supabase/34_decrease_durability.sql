-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('34_decrease_durability.sql');

-- ============================================================================
-- Шаг 34: атомарный износ снаряжения за один вызов.
--
-- Раньше бот делал SELECT всех надетых предметов и отдельный PATCH/DELETE на
-- каждую строку. Теперь вся работа (списание прочности, удаление сломанного,
-- пересчёт стаков) выполняется одной транзакцией в Postgres и возвращает
-- список сломанных предметов. Это уменьшает число запросов к API Gateway
-- и устраняет гонки при параллельных забросах.
--
-- Запускать в Supabase → SQL Editor после 33_drop_legacy_fields.sql.
-- Скрипт идемпотентен.
-- ============================================================================

create or replace function decrease_durability(
    p_channel_id bigint,
    p_user_id    bigint,
    p_skip_bait  boolean default false
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
begin
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
        v_uses := v_uses - 1;

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

comment on function decrease_durability(bigint, bigint, boolean) is
    'Атомарный износ надетого снаряжения за один заброс: списывает прочность, удаляет сломанное, возвращает список сломанных предметов.';

revoke all on function decrease_durability(bigint, bigint, boolean) from public, anon;
grant execute on function decrease_durability(bigint, bigint, boolean) to service_role;

select register_migration('34_decrease_durability.sql');