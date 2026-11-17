-- ============================================================================
-- Шаг 15: очистка артефактов целиком в Postgres.
--
-- Зачем: кнопка «Очистить» в кабинете должна использовать ту же механику,
-- что !очистить в боте: сначала свиток очищения, иначе платная попытка
-- у гадалки с риском усилить проклятие. Ролл значений и списание монет
-- выполняются здесь, а не в браузере и не в JS-движке бота.
--
-- Бот в режиме DB_BACKEND=supabase вызывает cleanse_artifact() через RPC.
-- Локальный SQLite очистку не поддерживает.
--
-- Запускать в Supabase → SQL Editor после 01–14. Скрипт идемпотентен.
-- ============================================================================

create table if not exists artifact_catalog (
    item_id       text primary key references items (id) on delete cascade,
    artifact_type text,
    rarity        text not null default 'common',
    price         integer not null default 0,
    effects       jsonb not null default '[]'::jsonb,
    curse_effects jsonb not null default '[]'::jsonb,
    curse_chance  numeric not null default 0
        check (curse_chance >= 0 and curse_chance <= 1),
    updated_at    timestamptz not null default now()
);

alter table artifact_catalog add column if not exists artifact_type text;
alter table artifact_catalog add column if not exists rarity text not null default 'common';
alter table artifact_catalog add column if not exists price integer not null default 0;
alter table artifact_catalog add column if not exists effects jsonb not null default '[]'::jsonb;
alter table artifact_catalog add column if not exists curse_effects jsonb not null default '[]'::jsonb;
alter table artifact_catalog add column if not exists curse_chance numeric not null default 0;
alter table artifact_catalog add column if not exists updated_at timestamptz not null default now();

comment on table artifact_catalog is
    'Эффекты, цена и шанс проклятия артефактов: источник для RPC покупки и очистки. Синхронизирует бот из artifacts.json.';

-- Каталог нужен только security definer-функциям, прямого чтения из веба нет.
alter table artifact_catalog enable row level security;
revoke all on artifact_catalog from anon, authenticated;
grant select, insert, update on artifact_catalog to service_role;

-- ---------------------------------------------------------------------------
-- Ролл одного эффекта: диапазон min..max → конкретное значение.
-- Округление совпадает с прежним роллом в боте.
-- ---------------------------------------------------------------------------

create or replace function artifact_roll_effect(p_effect jsonb)
returns jsonb
language plpgsql
volatile
as $$
declare
    v_min_text text := p_effect->>'min';
    v_max_text text := coalesce(p_effect->>'max', p_effect->>'min');
    v_min      numeric := coalesce((p_effect->>'min')::numeric, 0);
    v_max      numeric := coalesce((p_effect->>'max')::numeric, v_min);
    v_value    numeric := v_min + (v_max - v_min) * random();
    v_integer  boolean := coalesce(v_min_text ~ '^-?[0-9]+$', false)
                      and coalesce(v_max_text ~ '^-?[0-9]+$', false);
begin
    return jsonb_strip_nulls(jsonb_build_object(
        'type', p_effect->>'type',
        'target', p_effect->'target',
        'value', case
            when v_integer then floor(v_value + 0.5)
            else floor(v_value * 1000 + 0.5) / 1000
        end
    ));
end $$;

comment on function artifact_roll_effect(jsonb) is
    'Один эффект артефакта из диапазона min..max; округление как в боте.';

-- Все эффекты списка, с сохранением порядка.
create or replace function artifact_roll_effects(p_effects jsonb)
returns jsonb
language sql
volatile
as $$
    select coalesce(
        jsonb_agg(artifact_roll_effect(effect) order by ord),
        '[]'::jsonb
    )
    from jsonb_array_elements(coalesce(p_effects, '[]'::jsonb))
         with ordinality as t(effect, ord);
$$;

comment on function artifact_roll_effects(jsonb) is
    'Перероллить все эффекты артефакта из каталога.';

-- ---------------------------------------------------------------------------
-- Провал у гадалки: уже наролленное проклятие усиливается.
-- Повторяет worsenCurseValue из artifactEffects.js.
-- ---------------------------------------------------------------------------

create or replace function artifact_worsen_value(
    p_type text,
    p_target text,
    p_value numeric,
    p_factor numeric
)
returns numeric
language sql
immutable
as $$
    select case p_type
        when 'cooldown_modifier' then p_value * p_factor
        when 'type_modifier' then
            case when p_target in ('trash', 'empty')
                then p_value * p_factor
                else p_value / p_factor
            end
        when 'rarity_modifier' then p_value / p_factor
        when 'xp_multiplier' then p_value / p_factor
        when 'gold_bonus' then
            case when p_value < 0 then p_value * p_factor else p_value / p_factor end
        when 'rarity_bonus' then
            case when p_value < 0 then p_value * p_factor else p_value / p_factor end
        else p_value
    end;
$$;

create or replace function artifact_worsen_effects(p_effects jsonb, p_factor numeric)
returns jsonb
language sql
volatile
as $$
    select coalesce(
        jsonb_agg(
            jsonb_strip_nulls(jsonb_build_object(
                'type', rolled->>'type',
                'target', rolled->'target',
                'value', case
                    when rolled->>'type' in ('gold_bonus', 'inventory_bonus')
                        then floor(artifact_worsen_value(
                            rolled->>'type',
                            rolled->>'target',
                            (rolled->>'value')::numeric,
                            p_factor
                        ) + 0.5)
                    else floor(artifact_worsen_value(
                        rolled->>'type',
                        rolled->>'target',
                        (rolled->>'value')::numeric,
                        p_factor
                    ) * 1000 + 0.5) / 1000
                end
            )) order by ord
        ),
        '[]'::jsonb
    )
    from jsonb_array_elements(coalesce(p_effects, '[]'::jsonb))
         with ordinality as t(effect, ord)
    cross join lateral (select artifact_roll_effect(effect) as rolled) r;
$$;

-- ---------------------------------------------------------------------------
-- Очистка: свиток первым, иначе гадалка.
-- Возвращает jsonb, чтобы сайт и бот получали одинаковый результат.
-- ---------------------------------------------------------------------------

drop function if exists cleanse_artifact(bigint);

create or replace function cleanse_artifact(
    p_inventory_id bigint,
    p_username text default null,
    p_message_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_uid        uuid := auth.uid();
    v_role       text := auth.role();
    v_item       inventory%rowtype;
    v_catalog    artifact_catalog%rowtype;
    v_player     players%rowtype;
    v_scroll     inventory%rowtype;
    v_meta       jsonb;
    v_effects    jsonb;
    v_method     text;
    v_cost       integer := 0;
    v_chance     numeric := 0;
    v_failed     boolean := false;
    v_cursed     boolean;
    v_balance    integer;
    v_old_failed integer;
    v_name       text;
    v_price      integer;
    v_rarity     text;
begin
    select * into v_item
    from inventory
    where id = p_inventory_id
    for update;

    if not found then
        return jsonb_build_object(
            'ok', false,
            'code', 'not_found',
            'error', 'Артефакт не найден в инвентаре.'
        );
    end if;

    if v_item.item_type <> 'artifact' then
        return jsonb_build_object(
            'ok', false,
            'code', 'not_artifact',
            'error', 'Это не артефакт.'
        );
    end if;

    -- Кабинет вызывает RPC от имени вошедшего игрока; service_role — бот.
    if coalesce(v_role, '') <> 'service_role' then
        if v_uid is null then
            raise exception 'требуется вход через Twitch' using errcode = '28000';
        end if;
        if not exists (
            select 1
            from accounts a
            where a.auth_id = v_uid
              and a.user_id = v_item.user_id
        ) then
            raise exception 'артефакт принадлежит другому игроку' using errcode = '42501';
        end if;
    end if;

    v_meta := coalesce(v_item.meta, '{}'::jsonb);
    if coalesce((v_meta->>'cursed')::boolean, false) is not true then
        return jsonb_build_object(
            'ok', false,
            'code', 'not_cursed',
            'error', 'Артефакт не проклят — очищать нечего.'
        );
    end if;

    select * into v_catalog
    from artifact_catalog
    where item_id = v_item.item_id;

    if not found then
        return jsonb_build_object(
            'ok', false,
            'code', 'missing_catalog',
            'error', 'Артефакт отсутствует в каталоге: перероллить его эффекты нельзя.'
        );
    end if;

    select * into v_player
    from players
    where channel_id = v_item.channel_id
      and user_id = v_item.user_id
    for update;

    if not found then
        return jsonb_build_object(
            'ok', false,
            'code', 'not_found',
            'error', 'Игрок не найден.'
        );
    end if;

    v_balance := v_player.balance;
    v_name := coalesce(v_meta->>'name', v_item.item_id);
    v_price := greatest(
        coalesce((v_meta->>'price')::integer, v_catalog.price),
        0
    );
    v_rarity := coalesce(v_meta->>'rarity', v_catalog.rarity);

    select * into v_scroll
    from inventory
    where channel_id = v_item.channel_id
      and user_id = v_item.user_id
      and item_id = 'scroll_of_cleansing'
      and item_type = 'consumable'
      and quantity > 0
    order by id
    limit 1
    for update;

    if found then
        if v_scroll.quantity > 1 then
            update inventory
            set quantity = quantity - 1, updated_at = now()
            where id = v_scroll.id;
        else
            delete from inventory where id = v_scroll.id;
        end if;

        v_method := 'scroll';
        v_effects := artifact_roll_effects(v_catalog.effects);
        v_cursed := false;
    else
        -- Коэффициенты очистки заданы здесь и являются источником истины.
        v_cost := greatest(1, ceil(v_price * 0.25)::integer);

        if v_balance < v_cost then
            return jsonb_build_object(
                'ok', false,
                'code', 'insufficient_funds',
                'error', format('Гадалка просит %s, а у вас %s.', v_cost, v_balance),
                'cost', v_cost,
                'balance', v_balance
            );
        end if;

        update players
        set balance = balance - v_cost
        where channel_id = v_item.channel_id
          and user_id = v_item.user_id;
        v_balance := v_balance - v_cost;

        v_chance := least(1, greatest(0, coalesce(v_catalog.curse_chance, 0) * 2));
        v_failed := random() < v_chance;

        if v_failed then
            v_effects := artifact_worsen_effects(v_catalog.curse_effects, 1.25);
            v_cursed := true;
            v_method := 'failed';
        else
            v_effects := artifact_roll_effects(v_catalog.effects);
            v_cursed := false;
            v_method := 'coins';
        end if;
    end if;

    v_old_failed := coalesce((v_meta->>'failed_cleanses')::integer, 0);
    v_meta := v_meta || jsonb_build_object(
        'effects', v_effects,
        'cursed', v_cursed,
        'cleansed', case
            when v_cursed then coalesce((v_meta->>'cleansed')::boolean, false)
            else true
        end,
        'failed_cleanses', case
            when v_failed then v_old_failed + 1
            else v_old_failed
        end
    );

    update inventory
    set meta = v_meta, updated_at = now()
    where id = v_item.id;

    insert into events (channel_id, user_id, type, message_id, payload)
    values (
        v_item.channel_id,
        v_item.user_id,
        case v_method
            when 'scroll' then 'reroll_scroll'
            when 'failed' then 'reroll_failure'
            else 'reroll_success'
        end,
        nullif(p_message_id, ''),
        jsonb_build_object(
            'username', coalesce(nullif(p_username, ''), v_player.username),
            'artifactId', v_item.item_id,
            'artifactType', v_catalog.artifact_type,
            'rarity', v_rarity,
            'price', v_cost,
            'cursed', v_cursed,
            'effects', v_effects,
            'metadata', jsonb_build_object('name', v_name, 'method', v_method)
        )
    );

    return jsonb_build_object(
        'ok', true,
        'method', v_method,
        'cost', v_cost,
        'curseChance', v_chance,
        'cursed', v_cursed,
        'effects', v_effects,
        'name', v_name,
        'balance', v_balance
    );
end $$;

comment on function cleanse_artifact(bigint, text, text) is
    'Снимает проклятие артефакта: свиток, иначе гадалка. Ролл и списание — в базе.';

revoke all on function cleanse_artifact(bigint, text, text) from public;
grant execute on function cleanse_artifact(bigint, text, text) to authenticated, service_role;

revoke all on function artifact_roll_effect(jsonb) from public, anon, authenticated;
revoke all on function artifact_roll_effects(jsonb) from public, anon, authenticated;
revoke all on function artifact_worsen_value(text, text, numeric, numeric) from public, anon, authenticated;
revoke all on function artifact_worsen_effects(jsonb, numeric) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Каталог из fishBot/src/config/artifacts.json.
-- Бот дополнительно обновляет его при запуске (syncItemsCatalog).
-- ---------------------------------------------------------------------------

insert into artifact_catalog (item_id, artifact_type, rarity, price, effects, curse_effects, curse_chance) values
    ('art_sock', 'catch', 'common', 3000, '[{"type":"type_modifier","target":"fish","min":0.99,"max":1.06},{"type":"type_modifier","target":"trash","min":0.96,"max":1.03},{"type":"type_modifier","target":"treasure","min":0.99,"max":1.04},{"type":"gold_bonus","min":-1,"max":3}]'::jsonb, '[{"type":"type_modifier","target":"fish","min":0.85,"max":0.94},{"type":"type_modifier","target":"trash","min":1.05,"max":1.12},{"type":"gold_bonus","min":-3,"max":-1}]'::jsonb, 0.3),
    ('art_compass', 'treasure', 'common', 3000, '[{"type":"type_modifier","target":"treasure","min":0.99,"max":1.07},{"type":"cooldown_modifier","min":0.96,"max":1.02}]'::jsonb, '[{"type":"type_modifier","target":"treasure","min":0.85,"max":0.94},{"type":"cooldown_modifier","min":1.03,"max":1.08}]'::jsonb, 0.3),
    ('art_copper_coin', 'gold', 'common', 3000, '[{"type":"gold_bonus","min":-1,"max":3},{"type":"type_modifier","target":"empty","min":0.99,"max":1.04}]'::jsonb, '[{"type":"gold_bonus","min":-4,"max":-1},{"type":"type_modifier","target":"empty","min":1.03,"max":1.08}]'::jsonb, 0.3),
    ('art_dry_rag', 'comfort', 'common', 3000, '[{"type":"cooldown_modifier","min":0.97,"max":1.01},{"type":"type_modifier","target":"trash","min":0.98,"max":1.03}]'::jsonb, '[{"type":"cooldown_modifier","min":1.03,"max":1.08},{"type":"type_modifier","target":"trash","min":1.04,"max":1.1}]'::jsonb, 0.3),
    ('art_spoon', 'gold', 'uncommon', 12000, '[{"type":"gold_bonus","min":-1,"max":4},{"type":"type_modifier","target":"fish","min":0.97,"max":1.01}]'::jsonb, '[{"type":"gold_bonus","min":-5,"max":-2},{"type":"type_modifier","target":"fish","min":0.88,"max":0.95}]'::jsonb, 0.24),
    ('art_lucky_scale', 'luck', 'uncommon', 12000, '[{"type":"rarity_modifier","target":"rare","min":0.99,"max":1.12},{"type":"type_modifier","target":"empty","min":0.95,"max":1.02},{"type":"double_catch_chance","min":0,"max":0.05},{"type":"gold_bonus","min":-1,"max":3}]'::jsonb, '[{"type":"rarity_modifier","target":"rare","min":0.85,"max":0.94},{"type":"type_modifier","target":"empty","min":1.03,"max":1.08},{"type":"gold_bonus","min":-3,"max":-1}]'::jsonb, 0.24),
    ('art_bent_nail', 'catch', 'uncommon', 12000, '[{"type":"double_catch_chance","min":0,"max":0.03},{"type":"type_modifier","target":"fish","min":0.98,"max":1.02}]'::jsonb, '[{"type":"type_modifier","target":"fish","min":0.86,"max":0.94}]'::jsonb, 0.24),
    ('art_whisper_shell', 'mystic', 'uncommon', 12000, '[{"type":"rarity_bonus","target":"rare","min":-0.2,"max":1.4},{"type":"xp_multiplier","min":0.97,"max":1.01},{"type":"gold_bonus","min":-1,"max":2}]'::jsonb, '[{"type":"rarity_modifier","target":"rare","min":0.86,"max":0.94},{"type":"xp_multiplier","min":0.94,"max":0.98},{"type":"gold_bonus","min":-3,"max":-1}]'::jsonb, 0.24),
    ('art_glass_float', 'comfort', 'rare', 35000, '[{"type":"bait_save_chance","min":0,"max":0.08},{"type":"cooldown_modifier","min":0.96,"max":1.02}]'::jsonb, '[{"type":"cooldown_modifier","min":1.04,"max":1.1},{"type":"type_modifier","target":"empty","min":1.04,"max":1.1}]'::jsonb, 0.2),
    ('art_cat_bell', 'catch', 'rare', 35000, '[{"type":"double_catch_chance","min":0,"max":0.06},{"type":"type_modifier","target":"trash","min":0.98,"max":1.1}]'::jsonb, '[{"type":"type_modifier","target":"trash","min":1.11,"max":1.2},{"type":"type_modifier","target":"fish","min":0.86,"max":0.94}]'::jsonb, 0.2),
    ('art_sunken_key', 'treasure', 'rare', 35000, '[{"type":"type_modifier","target":"treasure","min":0.99,"max":1.08},{"type":"type_modifier","target":"fish","min":0.95,"max":1.01}]'::jsonb, '[{"type":"type_modifier","target":"treasure","min":0.85,"max":0.93},{"type":"type_modifier","target":"fish","min":0.88,"max":0.95}]'::jsonb, 0.2),
    ('art_moon_pearl', 'mystic', 'rare', 35000, '[{"type":"rarity_modifier","target":"epic","min":0.98,"max":1.1},{"type":"cooldown_modifier","min":0.96,"max":1.05}]'::jsonb, '[{"type":"rarity_modifier","target":"epic","min":0.84,"max":0.92},{"type":"cooldown_modifier","min":1.05,"max":1.15}]'::jsonb, 0.2),
    ('art_abyss_eye', 'luck', 'epic', 80000, '[{"type":"gold_bonus","min":-35,"max":15},{"type":"type_modifier","target":"fish","min":0.9,"max":1.01},{"type":"type_modifier","target":"empty","min":0.99,"max":1.015}]'::jsonb, '[{"type":"rarity_modifier","target":"epic","min":0.82,"max":0.92},{"type":"type_modifier","target":"empty","min":1.05,"max":1.12}]'::jsonb, 0.16),
    ('art_horseshoe', 'gold', 'epic', 80000, '[{"type":"cooldown_modifier","min":0.95,"max":1.02},{"type":"gold_bonus","min":-2,"max":5},{"type":"type_modifier","target":"treasure","min":0.98,"max":1.01}]'::jsonb, '[{"type":"gold_bonus","min":-6,"max":-2},{"type":"cooldown_modifier","min":1.04,"max":1.1}]'::jsonb, 0.16),
    ('art_tide_clock', 'comfort', 'epic', 80000, '[{"type":"cooldown_modifier","min":0.93,"max":1.01},{"type":"type_modifier","target":"empty","min":0.98,"max":1.03}]'::jsonb, '[{"type":"cooldown_modifier","min":1.05,"max":1.12},{"type":"type_modifier","target":"empty","min":1.05,"max":1.12}]'::jsonb, 0.16),
    ('art_drowned_map', 'treasure', 'epic', 80000, '[{"type":"type_modifier","target":"treasure","min":0.98,"max":1.07},{"type":"rarity_modifier","target":"rare","min":0.97,"max":1.04},{"type":"gold_bonus","min":-1,"max":2}]'::jsonb, '[{"type":"type_modifier","target":"treasure","min":0.86,"max":0.94},{"type":"gold_bonus","min":-4,"max":-1}]'::jsonb, 0.16),
    ('art_tide_crown', 'treasure', 'legendary', 180000, '[{"type":"type_modifier","target":"treasure","min":0.97,"max":1.1},{"type":"xp_multiplier","min":0.98,"max":1.04},{"type":"type_modifier","target":"empty","min":0.99,"max":1.05}]'::jsonb, '[{"type":"type_modifier","target":"treasure","min":0.85,"max":0.93},{"type":"xp_multiplier","min":0.94,"max":0.98}]'::jsonb, 0.16),
    ('art_invisible_rod', 'catch', 'legendary', 180000, '[{"type":"double_catch_chance","min":0,"max":0.07},{"type":"rarity_modifier","target":"mythic","min":0.97,"max":1.04},{"type":"type_modifier","target":"trash","min":0.98,"max":1.02}]'::jsonb, '[{"type":"type_modifier","target":"fish","min":0.86,"max":0.94},{"type":"type_modifier","target":"trash","min":1.05,"max":1.12}]'::jsonb, 0.16),
    ('art_siren_harp', 'luck', 'legendary', 180000, '[{"type":"rarity_modifier","target":"legendary","min":0.97,"max":1.1},{"type":"cooldown_modifier","min":0.96,"max":1.02}]'::jsonb, '[{"type":"rarity_modifier","target":"legendary","min":0.82,"max":0.91},{"type":"cooldown_modifier","min":1.04,"max":1.1}]'::jsonb, 0.16),
    ('art_midas_hook', 'gold', 'legendary', 180000, '[{"type":"gold_bonus","min":-1,"max":4},{"type":"type_modifier","target":"treasure","min":0.98,"max":1.02}]'::jsonb, '[{"type":"gold_bonus","min":-8,"max":-3},{"type":"type_modifier","target":"treasure","min":0.88,"max":0.95}]'::jsonb, 0.16),
    ('art_poseidon_seal', 'catch', 'mythic', 400000, '[{"type":"type_modifier","target":"fish","min":0.96,"max":1.08},{"type":"type_modifier","target":"treasure","min":0.96,"max":1.08},{"type":"rarity_modifier","target":"mythic","min":0.97,"max":1.1},{"type":"cooldown_modifier","min":0.99,"max":1.06}]'::jsonb, '[{"type":"type_modifier","target":"fish","min":0.84,"max":0.92},{"type":"type_modifier","target":"treasure","min":0.84,"max":0.92},{"type":"rarity_modifier","target":"mythic","min":0.8,"max":0.9},{"type":"cooldown_modifier","min":1.04,"max":1.1}]'::jsonb, 0.08),
    ('art_fate_sock', 'comfort', 'mythic', 400000, '[{"type":"inventory_bonus","min":0,"max":2},{"type":"gold_bonus","min":-1,"max":4},{"type":"cooldown_modifier","min":0.97,"max":1.02}]'::jsonb, '[{"type":"gold_bonus","min":-8,"max":-3},{"type":"cooldown_modifier","min":1.04,"max":1.1}]'::jsonb, 0.08),
    ('art_world_anchor', 'treasure', 'mythic', 400000, '[{"type":"type_modifier","target":"treasure","min":0.98,"max":1.1},{"type":"gold_bonus","min":-2,"max":3},{"type":"type_modifier","target":"empty","min":0.99,"max":1.07}]'::jsonb, '[{"type":"type_modifier","target":"treasure","min":0.82,"max":0.91},{"type":"gold_bonus","min":-8,"max":-3},{"type":"type_modifier","target":"empty","min":1.06,"max":1.14}]'::jsonb, 0.08),
    ('art_star_scale', 'luck', 'mythic', 400000, '[{"type":"rarity_bonus","target":"mythic","min":-8,"max":4},{"type":"type_modifier","target":"fish","min":0.86,"max":1.01},{"type":"type_modifier","target":"empty","min":0.99,"max":1.005},{"type":"cooldown_modifier","min":0.99,"max":1.1}]'::jsonb, '[{"type":"rarity_modifier","target":"mythic","min":0.8,"max":0.9},{"type":"type_modifier","target":"fish","min":0.86,"max":0.94},{"type":"type_modifier","target":"empty","min":1.05,"max":1.12}]'::jsonb, 0.08)
on conflict (item_id) do update set
    artifact_type = excluded.artifact_type,
    rarity        = excluded.rarity,
    price         = excluded.price,
    effects       = excluded.effects,
    curse_effects = excluded.curse_effects,
    curse_chance  = excluded.curse_chance,
    updated_at    = now();

