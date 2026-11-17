-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('18_admin_grant_artifact.sql');

-- ============================================================================
-- Шаг 18: админская выдача артефакта целиком в Postgres.
--
-- Ролл статов, проверка занятого типа, запись в инвентарь и событие
-- admin_grant выполняются одной транзакцией. Кабинет вызывает RPC через
-- service_role; локальный JS-ролл при выдаче больше не используется.
--
-- Запускать в Supabase → SQL Editor после 15_artifact_cleanse.sql и
-- 17_buy_artifact.sql. Скрипт идемпотентен.
-- ============================================================================

drop function if exists admin_grant_artifact(text, bigint, bigint, text, text);

create or replace function admin_grant_artifact(
    p_item_id text,
    p_channel_id bigint,
    p_user_id bigint,
    p_username text default null,
    p_message_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_role         text := auth.role();
    v_player       players%rowtype;
    v_catalog      artifact_catalog%rowtype;
    v_item         items%rowtype;
    v_owned        inventory%rowtype;
    v_owned_name   text;
    v_owned_types  integer;
    v_total_types  integer;
    v_cursed       boolean;
    v_effects      jsonb;
    v_meta         jsonb;
    v_inventory_id bigint;
begin
    -- Это привилегированная операция: только серверный ключ, не игрок.
    if coalesce(v_role, '') <> 'service_role' then
        raise exception 'выдача артефактов доступна только service_role'
            using errcode = '42501';
    end if;

    if p_channel_id is null
       or p_user_id is null
       or p_item_id is null
       or btrim(p_item_id) = '' then
        return jsonb_build_object(
            'ok', false,
            'code', 'bad_request',
            'error', 'Нужны канал, игрок и артефакт.'
        );
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
            'error', 'У артефакта нет каталога эффектов: выдача недоступна.'
        );
    end if;

    -- Блокируем игрока, чтобы две параллельные выдачи одного типа
    -- не прошли проверку одновременно.
    select * into v_player
    from players
    where channel_id = p_channel_id
      and user_id = p_user_id
    for update;

    if not found then
        return jsonb_build_object(
            'ok', false,
            'code', 'player_not_found',
            'error', 'Игрок не найден на этом канале.'
        );
    end if;

    select count(distinct c.artifact_type) into v_owned_types
    from inventory i
    join artifact_catalog c on c.item_id = i.item_id
    where i.channel_id = p_channel_id
      and i.user_id = p_user_id
      and i.item_type = 'artifact';

    select count(distinct c.artifact_type) into v_total_types
    from artifact_catalog c
    where c.artifact_type is not null;

    select i.* into v_owned
    from inventory i
    join artifact_catalog c on c.item_id = i.item_id
    where i.channel_id = p_channel_id
      and i.user_id = p_user_id
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

    v_cursed := random() < least(1, greatest(0, coalesce(v_catalog.curse_chance, 0)));
    v_effects := artifact_roll_effects(
        case when v_cursed then v_catalog.curse_effects else v_catalog.effects end
    );

    v_meta := jsonb_strip_nulls(jsonb_build_object(
        'name', v_item.name,
        'price', v_item.price,
        'rarity', v_catalog.rarity,
        'type', v_catalog.artifact_type,
        'description', v_item.description,
        'effects', v_effects,
        'cursed', v_cursed
    ));

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
        p_user_id,
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
        p_user_id,
        'admin_grant',
        nullif(p_message_id, ''),
        jsonb_build_object(
            'username', coalesce(nullif(p_username, ''), v_player.username),
            'artifactId', v_item.id,
            'artifactType', v_catalog.artifact_type,
            'rarity', v_catalog.rarity,
            'price', 0,
            'cursed', v_cursed,
            'effects', v_effects,
            'metadata', jsonb_build_object(
                'name', v_item.name,
                'source', 'web_admin'
            )
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
        'price', 0,
        'cursed', v_cursed,
        'effects', v_effects,
        'ownedTypes', v_owned_types,
        'totalTypes', v_total_types
    );
end $$;

comment on function admin_grant_artifact(text, bigint, bigint, text, text) is
    'Админская выдача артефакта: ролл статов, проверка типа, инвентарь и событие admin_grant.';

revoke all on function admin_grant_artifact(text, bigint, bigint, text, text) from public;
grant execute on function admin_grant_artifact(text, bigint, bigint, text, text) to service_role;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('18_admin_grant_artifact.sql');
