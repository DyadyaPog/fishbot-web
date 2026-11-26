-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('57_zombie_write_idempotency.sql');

-- ============================================================================
-- Шаг 57: идемпотентность записей по сообщению Twitch.
--
-- «Зомби»-выполнение команды после таймаута может дойти до базы позже, когда
-- связь восстановится. Клиентская отмена (CommandHandler + abortContext)
-- гасит такие вызовы, но если один и тот же msg.id всё же пришёл дважды
-- (retry, повторная доставка, перезапуск), XP, уловы и износ не должны
-- примениться дважды. Ключ идемпотентности — (канал, игрок, действие,
-- origin_event_id).
--
-- Совместимых перегрузок без ключа идемпотентности нет: чистой базе они не
-- нужны, а бот всегда передаёт p_origin_event_id.
--
-- Запускать в Supabase → SQL Editor после 56_abyss_channel_config.sql.
-- Перед запуском один раз выполните 00_schema_migrations.sql.
-- Скрипт идемпотентен.
-- ============================================================================

create table if not exists processed_message_actions (
    channel_id      bigint      not null,
    user_id         bigint      not null,
    action          text        not null,
    origin_event_id text        not null,
    created_at      timestamptz not null default now(),
    primary key (channel_id, user_id, action, origin_event_id)
);

comment on table processed_message_actions is
    'Ключи идемпотентности записей бота: одно действие по одному сообщению применяется один раз.';

create index if not exists processed_message_actions_created_idx
    on processed_message_actions (created_at);

alter table processed_message_actions enable row level security;
-- Политик нет: таблицу пишут только security definer-функции бота.
revoke all on processed_message_actions from public, anon, authenticated;
grant select, insert on processed_message_actions to service_role;

drop function if exists record_catch(bigint, bigint, text, integer, integer, integer, integer);

create or replace function record_catch(
    p_channel_id      bigint,
    p_user_id         bigint,
    p_item_id         text,
    p_price           integer,
    p_xp_delta        integer,
    p_fish_delta      integer,
    p_catch_count     integer default 1,
    p_origin_event_id text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_count    integer := greatest(1, coalesce(p_catch_count, 1));
    v_inserted integer := 0;
begin
    -- Повтор того же сообщения не начисляет XP и не пишет улов повторно.
    if p_channel_id is not null
       and p_origin_event_id is not null and p_origin_event_id <> '' then
        insert into processed_message_actions (channel_id, user_id, action, origin_event_id)
        values (p_channel_id, p_user_id, 'record_catch', p_origin_event_id)
        on conflict do nothing;
        get diagnostics v_inserted = row_count;
        if v_inserted = 0 then
            return;
        end if;
    end if;

    update players
       set xp          = xp + coalesce(p_xp_delta, 0),
           fish_caught = fish_caught + coalesce(p_fish_delta, 0)
     where channel_id = p_channel_id
       and user_id    = p_user_id;

    insert into catches (channel_id, user_id, item_id, price)
    select p_channel_id, p_user_id, coalesce(p_item_id, ''), coalesce(p_price, 0)
      from generate_series(1, v_count);
end $$;

comment on function record_catch(bigint, bigint, text, integer, integer, integer, integer, text) is
    'Атомарно обновляет XP/счётчик уловов и пишет catches; повтор msg.id не применяется.';

revoke all on function record_catch(bigint, bigint, text, integer, integer, integer, integer, text) from public, anon;
grant execute on function record_catch(bigint, bigint, text, integer, integer, integer, integer, text) to service_role;

drop function if exists decrease_durability(bigint, bigint, boolean);

create or replace function decrease_durability(
    p_channel_id      bigint,
    p_user_id         bigint,
    p_skip_bait       boolean default false,
    p_origin_event_id text default null
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

comment on function decrease_durability(bigint, bigint, boolean, text) is
    'Атомарный износ надетого снаряжения; повтор msg.id не изнашивает вещи второй раз.';

revoke all on function decrease_durability(bigint, bigint, boolean, text) from public, anon;
grant execute on function decrease_durability(bigint, bigint, boolean, text) to service_role;

select register_migration('57_zombie_write_idempotency.sql');