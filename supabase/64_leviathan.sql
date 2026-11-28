-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('64_leviathan.sql');

-- ============================================================================
-- Шаг 64: событие канала «Левиафан».
--
-- Механика целиком живёт в боте (src/engine/leviathan.js +
-- leviathanRuntime.js, вызов из !fish). Здесь только данные:
--   leviathan_hunts  — охота: HP, срок, состояние, виновник, лучший вклад;
--   leviathan_damage — вклад каждого игрока (урон, число ударов, первый удар).
--
-- Бот подключается как service_role и обходит RLS; политик для
-- authenticated нет: кабинет Левиафана пока не читает.
--
-- Запускать в Supabase → SQL Editor после 63_player_buffs.sql.
-- Перед запуском один раз выполните 00_schema_migrations.sql: он добавит файл
-- в migration_order. Скрипт идемпотентен.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Охоты: одна активная запись на канал
-- ---------------------------------------------------------------------------

create table if not exists leviathan_hunts (
    id                 bigserial   primary key,
    channel_id         bigint      not null references channels(id) on delete cascade,
    -- Сезон Бездны, в котором началась охота: награда и трофей относятся к нему.
    season_id          bigint      references abyss_seasons(id) on delete set null,
    started_at         timestamptz not null default now(),
    ends_at            timestamptz not null,
    hp_max             integer     not null check (hp_max > 0),
    hp                 integer     not null check (hp >= 0),
    state              text        not null default 'active'
                                   check (state in ('active', 'killed', 'escaped')),
    -- Кто разбудил, кто добил и кто получил трофей (лучший по вкладу).
    trigger_user_id    bigint,
    finisher_user_id   bigint,
    top_damage_user_id bigint,
    participants       integer     not null default 0 check (participants >= 0),
    -- Осколки выдаются ровно один раз: повторная обработка победы их не удвоит.
    rewards_paid_at    timestamptz,
    created_at         timestamptz not null default now()
);

comment on table leviathan_hunts is
    'Охоты на Левиафана: HP, срок, состояние, виновник, добивший и лучший по вкладу.';

-- Один активный Левиафан на канал: иначе чат не понимает, куда бить.
create unique index if not exists uq_leviathan_hunts_active
    on leviathan_hunts (channel_id) where state = 'active';

-- История и кулдауны (90 минут после победы, 120 после провала).
create index if not exists idx_leviathan_hunts_channel
    on leviathan_hunts (channel_id, started_at desc);

-- ---------------------------------------------------------------------------
-- Вклад игроков: одна строка на участника охоты
-- ---------------------------------------------------------------------------

create table if not exists leviathan_damage (
    hunt_id      bigint      not null references leviathan_hunts(id) on delete cascade,
    user_id      bigint      not null,
    damage       integer     not null default 0 check (damage >= 0),
    casts        integer     not null default 0 check (casts >= 0),
    first_hit_at timestamptz not null default now(),
    last_hit_at  timestamptz not null default now(),
    primary key (hunt_id, user_id)
);

comment on table leviathan_damage is
    'Вклад игроков в охоту: урон, число ударов и время первого удара (тай-брейк трофея).';

create index if not exists idx_leviathan_damage_top
    on leviathan_damage (hunt_id, damage desc, first_hit_at asc, user_id asc);

-- ---------------------------------------------------------------------------
-- Урон лески в фазе III: пустой заброс рвёт её на phase3_empty_line_damage.
-- Отдельная функция, потому что decrease_durability изнашивает всё снаряжение
-- на единицу, а здесь нужно снять несколько прочности только с лески.
-- ---------------------------------------------------------------------------

create or replace function leviathan_line_damage(
    p_channel_id bigint,
    p_user_id    bigint,
    p_amount     integer default 10
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row      inventory%rowtype;
    v_meta     jsonb;
    v_uses     numeric;
    v_max_uses numeric;
    v_has_max  boolean;
    v_qty      integer;
    v_new_qty  integer;
    v_name     text;
begin
    if coalesce(auth.role(), '') <> 'service_role' then
        raise exception 'leviathan_line_damage доступна только боту' using errcode = '42501';
    end if;

    if p_amount is null or p_amount < 1 then
        return jsonb_build_object('ok', false, 'code', 'bad_amount');
    end if;

    -- order by id: если надето несколько лесок, бьём самую старую строку,
    -- а не случайную.
    select * into v_row
    from inventory
    where channel_id = p_channel_id
      and user_id = p_user_id
      and item_type = 'line'
      and is_equipped = true
    order by id
    limit 1
    for update;

    if not found then
        return jsonb_build_object('ok', false, 'code', 'no_line');
    end if;

    v_meta := coalesce(v_row.meta, '{}'::jsonb);
    if jsonb_typeof(v_meta->'uses') <> 'number' then
        return jsonb_build_object('ok', false, 'code', 'no_uses');
    end if;

    v_uses := (v_meta->>'uses')::numeric;
    -- -1 — бесконечная леска: её не изнашиваем.
    if v_uses is null or v_uses < 0 then
        return jsonb_build_object('ok', false, 'code', 'no_uses');
    end if;

    v_name := coalesce(v_meta->>'name', v_row.item_id);
    if jsonb_typeof(v_meta->'max_uses') = 'number' then
        v_max_uses := (v_meta->>'max_uses')::numeric;
    else
        v_max_uses := null;
    end if;
    v_has_max := v_max_uses is not null and v_max_uses > 0;

    v_qty := greatest(1, coalesce(v_row.quantity, 1));
    v_uses := v_uses - p_amount;

    if v_uses <= 0 then
        delete from inventory where id = v_row.id;
        return jsonb_build_object(
            'ok', true,
            'name', v_name,
            'item_id', v_row.item_id,
            'broken', true,
            'uses_left', 0
        );
    end if;

    if v_has_max then
        v_new_qty := greatest(1, ceil(v_uses / v_max_uses)::integer);
    else
        v_new_qty := v_qty;
    end if;

    update inventory
    set meta = jsonb_set(v_meta, '{uses}', to_jsonb(v_uses)),
        quantity = v_new_qty,
        updated_at = now()
    where id = v_row.id;

    return jsonb_build_object(
        'ok', true,
        'name', v_name,
        'item_id', v_row.item_id,
        'broken', v_new_qty < v_qty,
        'uses_left', v_uses
    );
end $$;

comment on function leviathan_line_damage(bigint, bigint, integer) is
    'Снимает прочность с надетой лески (фаза III Левиафана); последний экземпляр удаляется.';

revoke all on function leviathan_line_damage(bigint, bigint, integer) from public, anon, authenticated;
grant execute on function leviathan_line_damage(bigint, bigint, integer) to service_role;

-- ---------------------------------------------------------------------------
-- RLS и права
-- ---------------------------------------------------------------------------

alter table leviathan_hunts  enable row level security;
alter table leviathan_damage enable row level security;

-- Политик нет: читает и пишет только бот (service_role обходит RLS).
grant select, insert, update, delete
    on leviathan_hunts, leviathan_damage
    to service_role;

grant usage, select on sequence leviathan_hunts_id_seq to service_role;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('64_leviathan.sql');
