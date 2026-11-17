-- ============================================================================
-- Шаг 17: покупка артефакта целиком в Postgres.
--
-- Ролл статов, проверка типа, списание монет, запись в инвентарь и событие
-- выполняются одной транзакцией. Бот в режиме Supabase вызывает buy_artifact()
-- через RPC; отдельного JS-ролла при покупке больше нет.
--
-- Запускать в Supabase → SQL Editor после 15_artifact_cleanse.sql.
-- Скрипт идемпотентен.
-- ============================================================================

alter table artifact_catalog
    add column if not exists level_required integer not null default 1;

comment on column artifact_catalog.level_required is
    'Минимальный уровень игрока для покупки артефакта. Синхронизируется из artifacts.json.';

drop function if exists buy_artifact(text, bigint, bigint, text, text);

create or replace function buy_artifact(
    p_item_id text,
    p_channel_id bigint,
    p_user_id bigint default null,
    p_username text default null,
    p_message_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_uid          uuid := auth.uid();
    v_role         text := auth.role();
    v_user_id      bigint;
    v_player       players%rowtype;
    v_catalog      artifact_catalog%rowtype;
    v_item         items%rowtype;
    v_owned        inventory%rowtype;
    v_owned_name   text;
    v_owned_types  integer;
    v_total_types  integer;
    v_price        integer;
    v_balance      integer;
    v_cursed       boolean;
    v_effects      jsonb;
    v_meta         jsonb;
    v_inventory_id bigint;
    v_level        integer;
begin
    if p_channel_id is null or p_item_id is null or btrim(p_item_id) = '' then
        return jsonb_build_object(
            'ok', false,
            'code', 'bad_request',
            'error', 'Нужны канал и артефакт.'
        );
    end if;

    -- Кабинет вызывает RPC от имени вошедшего игрока; service_role — бот.
    if coalesce(v_role, '') = 'service_role' then
        v_user_id := p_user_id;
        if v_user_id is null then
            return jsonb_build_object(
                'ok', false,
                'code', 'bad_request',
                'error', 'Для service_role нужен p_user_id.'
            );
        end if;
    else
        if v_uid is null then
            raise exception 'требуется вход через Twitch' using errcode = '28000';
        end if;

        select a.user_id into v_user_id
        from accounts a
        where a.auth_id = v_uid;

        if not found then
            raise exception 'аккаунт не привязан к игроку' using errcode = '28000';
        end if;

        if p_user_id is not null and p_user_id <> v_user_id then
            raise exception 'нельзя купить артефакт другому игроку' using errcode = '42501';
        end if;
    end if;

    select * into v_item
    from items
    where id = p_item_id
      and kind = 'artifact';

    if not found then
        return jsonb_build_object(
            'ok', false,
            'code', 'not_found',
            'error', 'Артефакт не найден в каталоге предметов.'
        );
    end if;

    select * into v_catalog
    from artifact_catalog
    where item_id = p_item_id;

    if not found or v_catalog.artifact_type is null then
        return jsonb_build_object(
            'ok', false,
            'code', 'missing_catalog',
            'error', 'У артефакта нет каталога эффектов: покупка недоступна.'
        );
    end if;

    select * into v_player
    from players
    where channel_id = p_channel_id
      and user_id = v_user_id
    for update;

    if not found then
        return jsonb_build_object(
            'ok', false,
            'code', 'player_not_found',
            'error', 'Игрок не найден на этом канале.'
        );
    end if;

    v_level := level_from_xp(v_player.xp);
    if v_level < greatest(1, coalesce(v_catalog.level_required, 1)) then
        return jsonb_build_object(
            'ok', false,
            'code', 'level_too_low',
            'error', format(
                '«%s» нужен %s ур., а у вас %s.',
                v_item.name,
                greatest(1, coalesce(v_catalog.level_required, 1)),
                v_level
            ),
            'level', v_level,
            'requiredLevel', greatest(1, coalesce(v_catalog.level_required, 1))
        );
    end if;

    select count(distinct c.artifact_type) into v_owned_types
    from inventory i
    join artifact_catalog c on c.item_id = i.item_id
    where i.channel_id = p_channel_id
      and i.user_id = v_user_id
      and i.item_type = 'artifact';

    select count(distinct c.artifact_type) into v_total_types
    from artifact_catalog c
    where c.artifact_type is not null;

    select i.* into v_owned
    from inventory i
    join artifact_catalog c on c.item_id = i.item_id
    where i.channel_id = p_channel_id
      and i.user_id = v_user_id
      and i.item_type = 'artifact'
      and c.artifact_type = v_catalog.artifact_type
    order by i.id
    limit 1;

    if found then
        v_owned_name := coalesce(
            v_owned.meta->>'name',
            (select name from items where id = v_owned.item_id),
            v_owned.item_id
        );

        return jsonb_build_object(
            'ok', false,
            'code', 'type_occupied',
            'error', format(
                'Тип «%s» уже занят: «%s». Носить можно только один артефакт каждого типа.',
                v_catalog.artifact_type,
                v_owned_name
            ),
            'artifactType', v_catalog.artifact_type,
            'ownedName', v_owned_name,
            'ownedTypes', v_owned_types,
            'totalTypes', v_total_types
        );
    end if;

    v_price := case
        when coalesce(v_catalog.price, 0) > 0 then v_catalog.price
        else coalesce(v_item.price, 0)
    end;

    if v_player.balance < v_price then
        return jsonb_build_object(
            'ok', false,
            'code', 'insufficient_funds',
            'error', format(
                'Не хватает денег: «%s» стоит %s, у вас %s.',
                v_item.name,
                v_price,
                v_player.balance
            ),
            'price', v_price,
            'balance', v_player.balance
        );
    end if;

    v_cursed := random() < least(1, greatest(0, coalesce(v_catalog.curse_chance, 0)));
    v_effects := artifact_roll_effects(
        case when v_cursed then v_catalog.curse_effects else v_catalog.effects end
    );

    v_meta := jsonb_strip_nulls(jsonb_build_object(
        'name', v_item.name,
        'price', v_price,
        'rarity', v_catalog.rarity,
        'type', v_catalog.artifact_type,
        'description', v_item.description,
        'effects', v_effects,
        'cursed', v_cursed
    ));

    update players
    set balance = balance - v_price
    where channel_id = p_channel_id
      and user_id = v_user_id;

    v_balance := v_player.balance - v_price;

    insert into inventory (
        channel_id,
        user_id,
        item_id,
        item_type,
        quantity,
        meta,
        origin_event_id
    )
    values (
        p_channel_id,
        v_user_id,
        v_item.id,
        'artifact',
        1,
        v_meta,
        nullif(p_message_id, '')
    )
    returning id into v_inventory_id;

    v_owned_types := v_owned_types + 1;

    insert into events (channel_id, user_id, type, message_id, payload)
    values (
        p_channel_id,
        v_user_id,
        'purchase',
        nullif(p_message_id, ''),
        jsonb_build_object(
            'username', coalesce(nullif(p_username, ''), v_player.username),
            'artifactId', v_item.id,
            'artifactType', v_catalog.artifact_type,
            'rarity', v_catalog.rarity,
            'price', v_price,
            'cursed', v_cursed,
            'effects', v_effects,
            'metadata', jsonb_build_object('name', v_item.name)
        )
    );

    return jsonb_build_object(
        'ok', true,
        'inventoryId', v_inventory_id,
        'itemId', v_item.id,
        'name', v_item.name,
        'artifactId', v_item.id,
        'artifactType', v_catalog.artifact_type,
        'rarity', v_catalog.rarity,
        'price', v_price,
        'balance', v_balance,
        'cursed', v_cursed,
        'effects', v_effects,
        'ownedTypes', v_owned_types,
        'totalTypes', v_total_types
    );
end $$;

comment on function buy_artifact(text, bigint, bigint, text, text) is
    'Покупка артефакта: проверка типа и уровня, списание, ролл статов, инвентарь и событие.';

revoke all on function buy_artifact(text, bigint, bigint, text, text) from public;
grant execute on function buy_artifact(text, bigint, bigint, text, text) to authenticated, service_role;
