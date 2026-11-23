-- ============================================================================
-- Шаг 46: доступ стримера к боту, админ-управление каналом, значок,
--         Twitch ID из auth.identities и безопасные колонки channels.
--
-- Объединённый шаг вместо отдельных 46_streamer_bot_access.sql,
-- 47_bot_channel_admin.sql, 48_bot_badge_access.sql,
-- 49_identity_provider_id.sql и 50_channel_column_grants.sql.
-- Ни один из этих шагов ещё не применялся, поэтому запускать нужно только
-- этот файл — один раз.
--
-- Внутри по порядку:
--   1. стример сам подключает бота к своему каналу (46);
--   2. владелец бота управляет каналом и блокировкой из админ-панели (47);
--   3. разрешение channel:bot для значка чат-бота (48);
--   4. claim_profile берёт Twitch ID из auth.identities, а не из metadata (49);
--   5. кабинет читает из channels только публичные колонки, а новые объекты
--      не получают широкие права anon (50).
--
-- Запускать в Supabase → SQL Editor после 45_jsonb_double_encode_fix.sql.
-- Скрипт идемпотентен.
-- ============================================================================

select assert_migration('46_bot_access_and_hardening.sql');

-- ===== 46_streamer_bot_access.sql =====

-- ============================================================================
-- Шаг 46: стример сам подключает бота к своему каналу.
--
-- Раньше канал попадал к боту только через TWITCH_CHANNEL в .env: стример
-- писал владельцу бота, тот правил файл и перезапускал процесс. Теперь
-- стример входит в кабинет через Twitch и просит подключить бота сам.
--
-- Право на канал доказывается самим Twitch ID: у каждого пользователя Twitch
-- есть ровно один канал с тем же ID. ID берём из auth.identities, а не из
-- raw_user_meta_data: metadata пользователя можно переписать через updateUser,
-- identities заполняет только провайдер. Поэтому RPC ниже меняют только
-- строку channels с id, равным Twitch ID вошедшего, — подставить чужой канал
-- нельзя.
--
-- Роли:
--   pending  — стример попросил бота; бот увидит заявку и войдёт в чат;
--   active   — бот действительно в чате. Ставит бот после входа, а вручную —
--              только админ-панель владельца бота (шаг 47);
--   disabled — стример отключил бота, бот выйдет из чата.
--
-- Скрипт идемпотентен.
-- ============================================================================

alter table public.channels
    add column if not exists owner_auth_id    uuid,
    add column if not exists bot_status       text not null default 'active',
    add column if not exists bot_requested_at timestamptz,
    add column if not exists bot_joined_at    timestamptz;

comment on column public.channels.owner_auth_id is
    'auth.users.id стримера, который подключил бота из кабинета. null — канал пришёл из .env.';
comment on column public.channels.bot_status is
    'pending — заявка из кабинета, active — бот в чате (ставит бот или админ-панель), disabled — стример отключил бота.';
comment on column public.channels.bot_requested_at is
    'Когда стример попросил подключить бота.';
comment on column public.channels.bot_joined_at is
    'Когда бот действительно вошёл в чат канала и подтвердил заявку.';

-- Статус — только из трёх значений: опечатка бота или кабинета не должна
-- тихо вывести канал из выборки.
do $$
begin
    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.channels'::regclass
          and conname = 'channels_bot_status_check'
    ) then
        alter table public.channels
            add constraint channels_bot_status_check
            check (bot_status in ('pending', 'active', 'disabled'));
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- bot_caller_twitch(): Twitch ID и логин вошедшего
-- ---------------------------------------------------------------------------
-- Повторяет разбор профиля из claim_profile() (10_rls.sql), но ничего не
-- пишет: RPC нужен только для проверки владельца канала. Клиентам функция не
-- выдаётся — только security definer-обёрткам ниже.

create or replace function bot_caller_twitch()
returns table (twitch_id bigint, login text, display_name text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_uid         uuid := auth.uid();
    v_twitch_text text;
    v_twitch      bigint;
    v_login       text;
    v_display     text;
begin
    if v_uid is null then
        raise exception 'требуется вход через Twitch' using errcode = '28000';
    end if;

    -- provider_id из identities не редактируется пользователем. В старых
    -- версиях Supabase ID провайдера лежит в identities.id, поэтому берём его
    -- как запасной вариант.
    select coalesce(
               nullif(i.identity_data->>'provider_id', ''),
               nullif(i.identity_data->>'sub', ''),
               case when i.id::text ~ '^[0-9]+$' then i.id::text end
           ),
           coalesce(
               i.identity_data->>'user_name',
               i.identity_data->>'preferred_username',
               i.identity_data->>'nickname'
           ),
           coalesce(
               i.identity_data->>'preferred_username',
               i.identity_data->>'user_name',
               i.identity_data->>'nickname'
           )
      into v_twitch_text, v_login, v_display
      from auth.identities i
     where i.user_id = v_uid
       and i.provider = 'twitch'
     limit 1;

    if v_twitch_text is null or btrim(v_twitch_text) !~ '^[0-9]+$' then
        raise exception 'в профиле нет Twitch ID (provider_id)' using errcode = '22023';
    end if;
    v_twitch := btrim(v_twitch_text)::bigint;

    -- Логин канала = логин пользователя на Twitch, поэтому # и регистр убираем.
    v_login := lower(regexp_replace(coalesce(v_login, ''), '^#', ''));
    if v_login !~ '^[a-z0-9_]{2,25}$' then
        raise exception 'в профиле нет логина Twitch' using errcode = '22023';
    end if;

    return query select v_twitch, v_login, nullif(btrim(coalesce(v_display, v_login)), '');
end $$;

comment on function bot_caller_twitch() is
    'Twitch ID и логин вошедшего: владелец канала для RPC подключения бота.';

-- ---------------------------------------------------------------------------
-- my_bot_channel(): что кабинет знает о боте на канале стримера
-- ---------------------------------------------------------------------------
-- Строка ищется по id, равному Twitch ID вошедшего: чужой канал не читается
-- и не подменяется, даже если у него известен логин.

create or replace function my_bot_channel()
returns table (
    channel_id   bigint,
    login        text,
    display_name text,
    bot_status   text,
    requested_at timestamptz,
    joined_at    timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_twitch bigint;
begin
    select t.twitch_id into v_twitch from bot_caller_twitch() t;

    return query
        select c.id, c.login, c.display_name, c.bot_status,
               c.bot_requested_at, c.bot_joined_at
          from channels c
         where c.id = v_twitch;
end $$;

comment on function my_bot_channel() is
    'Статус бота на собственном канале вошедшего стримера.';

-- ---------------------------------------------------------------------------
-- request_bot_channel(): стример просит подключить бота
-- ---------------------------------------------------------------------------
-- Заявка ставится в pending. В active переводит бот — после того как
-- реально вошёл в чат (markBotChannelJoined в src/db/postgres.js); вручную это
-- может сделать только админ-панель владельца (шаг 47). Поэтому кабинет не
-- может «нарисовать» работающего бота.

create or replace function request_bot_channel()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_uid     uuid := auth.uid();
    v_twitch  bigint;
    v_login   text;
    v_display text;
    v_status  text;
begin
    select t.twitch_id, t.login, t.display_name
      into v_twitch, v_login, v_display
      from bot_caller_twitch() t;

    begin
        insert into channels (
            id, login, display_name, owner_auth_id, bot_status, bot_requested_at
        )
        values (
            v_twitch, v_login, v_display, v_uid, 'pending', now()
        )
        on conflict (id) do update
            set login            = excluded.login,
                display_name      = coalesce(excluded.display_name, channels.display_name),
                owner_auth_id     = coalesce(channels.owner_auth_id, excluded.owner_auth_id),
                -- Уже работающий бот не начинает подключаться заново.
                bot_status        = case when channels.bot_status = 'active'
                                         then 'active' else 'pending' end,
                bot_requested_at  = case when channels.bot_status = 'active'
                                         then channels.bot_requested_at else now() end
        returning bot_status into v_status;
    exception when unique_violation then
        raise exception 'логин % уже занят другим каналом в базе', v_login
            using errcode = '23505';
    end;

    return jsonb_build_object(
        'ok', true,
        'status', v_status,
        'channelId', v_twitch,
        'login', v_login
    );
end $$;

comment on function request_bot_channel() is
    'Заявка стримера на подключение бота к собственному каналу (pending).';

-- ---------------------------------------------------------------------------
-- disable_bot_channel(): стример отключает бота
-- ---------------------------------------------------------------------------
-- Бот читает статус в цикле синхронизации и выходит из чата. Строка канала не
-- удаляется: история игроков, уловы и магазин остаются на месте.

create or replace function disable_bot_channel()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_uid    uuid := auth.uid();
    v_twitch bigint;
    v_login  text;
begin
    select t.twitch_id, t.login into v_twitch, v_login
      from bot_caller_twitch() t;

    update channels
       set bot_status    = 'disabled',
           owner_auth_id = coalesce(owner_auth_id, v_uid)
     where id = v_twitch;

    return jsonb_build_object(
        'ok', true,
        'status', 'disabled',
        'channelId', v_twitch,
        'login', v_login
    );
end $$;

comment on function disable_bot_channel() is
    'Отключает бота на собственном канале стримера; бот выходит из чата.';

-- ---------------------------------------------------------------------------
-- Права
-- ---------------------------------------------------------------------------
-- Внутренний разбор профиля клиентам не нужен: владелец канала проверяется
-- внутри security definer-функций.

revoke all on function bot_caller_twitch()   from public, anon, authenticated;
revoke all on function my_bot_channel()      from public, anon;
revoke all on function request_bot_channel() from public, anon;
revoke all on function disable_bot_channel() from public, anon;

grant execute on function my_bot_channel()      to authenticated, service_role;
grant execute on function request_bot_channel() to authenticated, service_role;
grant execute on function disable_bot_channel() to authenticated, service_role;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.

-- ===== 47_bot_channel_admin.sql =====

-- ============================================================================
-- Шаг 47: владелец бота управляет каналами из админ-панели.
--
-- Стример подключает бота сам (шаг 46), но если канал стал проблемным,
-- владельцу бота нужен способ отключить его, не залезая в SQL. Кроме статуса
-- есть отдельная блокировка стримера: «этот канал игнорируем для входа в чат»
-- независимо от того, что стример снова нажал в кабинете.
--
-- Порядок статусов прежний:
--   pending  — заявка из кабинета, бот ещё не вошёл;
--   active   — бот в чате; вручную этот статус может поставить панель,
--              но время реального входа (bot_joined_at) пишет только бот;
--   disabled — бот выключен.
--
-- Блокировка (bot_banned) не меняет статус: бот выходит из чата и пропускает
-- канал, пока блокировку не снимут. После снятия канал со статусом active
-- снова подхватывается, а disabled остаётся отключённым.
--
-- Скрипт идемпотентен.
-- ============================================================================

alter table public.channels
    add column if not exists bot_banned    boolean not null default false,
    add column if not exists bot_banned_at timestamptz;

comment on column public.channels.bot_banned is
    'Владелец бота заблокировал канал: бот не входит в чат и не берёт новые заявки из кабинета.';
comment on column public.channels.bot_banned_at is
    'Когда канал заблокировали в админ-панели; null — блокировки нет.';

-- ---------------------------------------------------------------------------
-- admin_set_bot_channel(): статус и блокировка канала из админ-панели
-- ---------------------------------------------------------------------------
-- Функция только для service_role: панель работает на машине владельца бота
-- и подключается тем же ключом, что и бот. Клиенты кабинета её не видят —
-- стример по-прежнему ходит только через request_bot_channel/disable_bot_channel
-- и не может снять собственную блокировку.

create or replace function admin_set_bot_channel(
    p_channel_id bigint,
    p_status     text default null,
    p_banned     boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_status text := nullif(btrim(coalesce(p_status, '')), '');
    v_row    channels;
begin
    if auth.role() is distinct from 'service_role' then
        raise exception 'изменять каналы может только бот' using errcode = '42501';
    end if;

    if p_channel_id is null then
        raise exception 'не указан канал' using errcode = '22023';
    end if;

    if v_status is null and p_banned is null then
        raise exception 'нечего менять: нужен статус или блокировка' using errcode = '22023';
    end if;

    if v_status is not null and v_status not in ('pending', 'active', 'disabled') then
        raise exception 'неизвестный статус канала: %', v_status using errcode = '22023';
    end if;

    update channels
       set bot_status       = coalesce(v_status, bot_status),
           -- Ручной active/pending — это тоже заявка: бот увидит канал в
           -- ближайшем цикле синхронизации и сам запишет реальное время
           -- входа. Панель bot_joined_at не подставляет — иначе в кабинете
           -- было бы "в чате с …" для канала, куда бот ещё не зашёл.
           bot_requested_at = case when v_status = 'pending' then now()
                                   else bot_requested_at end,
           bot_banned       = coalesce(p_banned, bot_banned),
           -- Повторное "забанить" не сдвигает дату первой блокировки.
           bot_banned_at    = case when p_banned is true then coalesce(bot_banned_at, now())
                                   when p_banned is false then null
                                   else bot_banned_at end
     where id = p_channel_id
    returning * into v_row;

    if v_row.id is null then
        raise exception 'канал % не найден в channels', p_channel_id using errcode = 'P0002';
    end if;

    return jsonb_build_object(
        'ok', true,
        'channelId', v_row.id,
        'login', v_row.login,
        'displayName', v_row.display_name,
        'botStatus', v_row.bot_status,
        'banned', v_row.bot_banned,
        'bannedAt', v_row.bot_banned_at,
        'requestedAt', v_row.bot_requested_at,
        'joinedAt', v_row.bot_joined_at,
        'ownerAuthId', v_row.owner_auth_id
    );
end $$;

comment on function admin_set_bot_channel(bigint, text, boolean) is
    'Статус бота и блокировка канала из админ-панели (только service_role).';

-- ---------------------------------------------------------------------------
-- my_bot_channel(): кабинет видит и блокировку
-- ---------------------------------------------------------------------------
-- Возвращаемый набор колонок меняется, поэтому функцию нужно пересоздать,
-- а не заменять: create or replace не меняет тип возврата.

drop function if exists my_bot_channel();

create or replace function my_bot_channel()
returns table (
    channel_id   bigint,
    login        text,
    display_name text,
    bot_status   text,
    banned       boolean,
    requested_at timestamptz,
    joined_at    timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_twitch bigint;
begin
    select t.twitch_id into v_twitch from bot_caller_twitch() t;

    return query
        select c.id, c.login, c.display_name, c.bot_status,
               c.bot_banned, c.bot_requested_at, c.bot_joined_at
          from channels c
         where c.id = v_twitch;
end $$;

comment on function my_bot_channel() is
    'Статус бота на собственном канале вошедшего стримера, включая блокировку.';

-- ---------------------------------------------------------------------------
-- request_bot_channel(): заблокированный канал заявку не принимает
-- ---------------------------------------------------------------------------

create or replace function request_bot_channel()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_uid     uuid := auth.uid();
    v_twitch  bigint;
    v_login   text;
    v_display text;
    v_status  text;
begin
    select t.twitch_id, t.login, t.display_name
      into v_twitch, v_login, v_display
      from bot_caller_twitch() t;

    -- Блокировку снимает только владелец бота в админ-панели: повторное
    -- нажатие «Подключить бота» её не обходит.
    if exists (
        select 1 from channels c where c.id = v_twitch and c.bot_banned
    ) then
        raise exception 'владелец бота заблокировал подключение для этого канала'
            using errcode = '42501';
    end if;

    begin
        insert into channels (
            id, login, display_name, owner_auth_id, bot_status, bot_requested_at
        )
        values (
            v_twitch, v_login, v_display, v_uid, 'pending', now()
        )
        on conflict (id) do update
            set login            = excluded.login,
                display_name      = coalesce(excluded.display_name, channels.display_name),
                owner_auth_id     = coalesce(channels.owner_auth_id, excluded.owner_auth_id),
                -- Уже работающий бот не начинает подключаться заново.
                bot_status        = case when channels.bot_status = 'active'
                                         then 'active' else 'pending' end,
                bot_requested_at  = case when channels.bot_status = 'active'
                                         then channels.bot_requested_at else now() end
        returning bot_status into v_status;
    exception when unique_violation then
        raise exception 'логин % уже занят другим каналом в базе', v_login
            using errcode = '23505';
    end;

    return jsonb_build_object(
        'ok', true,
        'status', v_status,
        'channelId', v_twitch,
        'login', v_login
    );
end $$;

comment on function request_bot_channel() is
    'Заявка стримера на подключение бота к собственному каналу (pending).';

-- ---------------------------------------------------------------------------
-- Права
-- ---------------------------------------------------------------------------

revoke all on function admin_set_bot_channel(bigint, text, boolean) from public, anon, authenticated;
grant execute on function admin_set_bot_channel(bigint, text, boolean) to service_role;

revoke all on function my_bot_channel() from public, anon;
grant execute on function my_bot_channel() to authenticated, service_role;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.

-- ===== 48_bot_badge_access.sql =====

-- ============================================================================
-- Шаг 48: стример выдаёт боту разрешение channel:bot для значка чат-бота.
--
-- Значок «Chat Bot» Twitch показывает только сообщениям, отправленным через
-- Send Chat Message с app access token, если у приложения есть разрешение
-- channel:bot от вещателя (или бот — модератор канала). Обычный user token
-- бота значка не даёт.
--
-- Разрешение выдаётся на странице Twitch (implicit flow) с client_id того же
-- приложения, что и у бота. Токен кабинет не хранит: он только сообщает боту,
-- что можно попробовать app-отправку снова. Реальный результат подтверждает
-- сам бот: успешная отправка через Send Chat Message = значок работает.
--
-- Скрипт идемпотентен.
-- ============================================================================

alter table public.channels
    add column if not exists bot_badge_requested_at timestamptz,
    add column if not exists bot_badge_at           timestamptz;

comment on column public.channels.bot_badge_requested_at is
    'Стример вернулся из Twitch с разрешением channel:bot; бот перепроверит значок.';
comment on column public.channels.bot_badge_at is
    'Бот отправил сообщение app-токеном и значок чат-бота подтверждён.';

-- ---------------------------------------------------------------------------
-- my_bot_channel(): кабинет видит статус значка
-- ---------------------------------------------------------------------------
-- Набор колонок снова меняется, поэтому функцию пересоздаём.

drop function if exists my_bot_channel();

create or replace function my_bot_channel()
returns table (
    channel_id         bigint,
    login              text,
    display_name       text,
    bot_status         text,
    banned             boolean,
    requested_at       timestamptz,
    joined_at          timestamptz,
    badge_requested_at timestamptz,
    badge_at           timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_twitch bigint;
begin
    select t.twitch_id into v_twitch from bot_caller_twitch() t;

    return query
        select c.id, c.login, c.display_name, c.bot_status,
               c.bot_banned, c.bot_requested_at, c.bot_joined_at,
               c.bot_badge_requested_at, c.bot_badge_at
          from channels c
         where c.id = v_twitch;
end $$;

comment on function my_bot_channel() is
    'Статус бота и значка чат-бота на собственном канале вошедшего стримера.';

-- ---------------------------------------------------------------------------
-- request_bot_badge_access(): стример вернулся из Twitch с channel:bot
-- ---------------------------------------------------------------------------
-- Функция не проверяет токен Twitch: подтвердить разрешение может только
-- бот — успешной отправкой app-токеном. Здесь фиксируется лишь просьба
-- перепроверить значок, чтобы бот не ждал перезапуска.

create or replace function request_bot_badge_access()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_twitch bigint;
    v_login  text;
    v_status text;
    v_banned boolean;
begin
    select t.twitch_id, t.login into v_twitch, v_login
      from bot_caller_twitch() t;

    select c.bot_status, c.bot_banned into v_status, v_banned
      from channels c
     where c.id = v_twitch;

    if not found then
        raise exception 'сначала подключите бота к каналу' using errcode = 'P0001';
    end if;

    if v_banned then
        raise exception 'владелец бота заблокировал этот канал' using errcode = '42501';
    end if;

    update channels
       set bot_badge_requested_at = now(),
           -- Старое подтверждение относилось к прежнему разрешению: покажем
           -- «проверяем», пока бот снова не отправит сообщение со значком.
           bot_badge_at = null
     where id = v_twitch;

    return jsonb_build_object(
        'ok', true,
        'channelId', v_twitch,
        'login', v_login,
        'status', v_status
    );
end $$;

comment on function request_bot_badge_access() is
    'Отмечает, что стример выдал channel:bot; бот перепроверит значок чат-бота.';

-- ---------------------------------------------------------------------------
-- Права
-- ---------------------------------------------------------------------------

revoke all on function my_bot_channel() from public, anon;
grant execute on function my_bot_channel() to authenticated, service_role;

revoke all on function request_bot_badge_access() from public, anon;
grant execute on function request_bot_badge_access() to authenticated, service_role;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.

-- ===== 49_identity_provider_id.sql =====

-- ============================================================================
-- Шаг 49: Twitch ID для claim_profile берём из auth.identities.
--
-- raw_user_meta_data обновляется через auth.updateUser({ data }), поэтому
-- provider_id в нём может переписать сам пользователь. Проверка владельца
-- канала в 46 уже использует identities; здесь закрываем тот же путь для
-- привязки игрового аккаунта в claim_profile().
--
-- Скрипт идемпотентен.
-- ============================================================================

create or replace function claim_profile()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
    v_uid         uuid := auth.uid();
    v_twitch_text text;
    v_twitch      bigint;
    v_username    text;
    v_owner       uuid;
begin
    if v_uid is null then
        raise exception 'требуется вход через Twitch' using errcode = '28000';
    end if;

    -- identities заполняет только провайдер; raw_user_meta_data — нет.
    select coalesce(
               nullif(i.identity_data->>'provider_id', ''),
               nullif(i.identity_data->>'sub', ''),
               case when i.id::text ~ '^[0-9]+$' then i.id::text end
           ),
           coalesce(
               i.identity_data->>'user_name',
               i.identity_data->>'preferred_username',
               i.identity_data->>'nickname'
           )
      into v_twitch_text, v_username
      from auth.identities i
     where i.user_id = v_uid
       and i.provider = 'twitch'
     limit 1;

    if v_twitch_text is null or btrim(v_twitch_text) !~ '^[0-9]+$' then
        raise exception 'в профиле нет Twitch ID (provider_id)' using errcode = '22023';
    end if;
    v_twitch := btrim(v_twitch_text)::bigint;

    select a.auth_id into v_owner
      from accounts a
     where a.user_id = v_twitch;

    if found then
        if v_owner is not null and v_owner <> v_uid then
            raise exception 'Twitch ID % уже привязан к другому аккаунту', v_twitch
                using errcode = '23505';
        end if;

        update accounts
           set auth_id  = v_uid,
               username = coalesce(nullif(v_username, ''), username)
         where user_id = v_twitch;
    else
        if exists (select 1 from accounts a where a.auth_id = v_uid) then
            raise exception 'этот вход уже привязан к другому Twitch ID' using errcode = '23505';
        end if;

        insert into accounts (user_id, auth_id, username)
        values (v_twitch, v_uid, nullif(v_username, ''));
    end if;

    return v_twitch;
end $$;

comment on function claim_profile() is
    'Привязывает Twitch ID вошедшего (auth.identities) к accounts.auth_id и возвращает Twitch ID.';

revoke all on function claim_profile() from public, anon;
grant execute on function claim_profile() to authenticated;


-- ===== 50_channel_column_grants.sql =====

-- ============================================================================
-- Шаг 50: кабинет читает из channels только публичные колонки.
--
-- Политика "channels: чтение" разрешает authenticated видеть строки каналов:
-- это нужно вьюхе my_channels (там только login/display_name). Но table-level
-- GRANT SELECT отдавал ещё owner_auth_id, bot_status, bot_banned, bot_badge_at
-- и bot_joined_at — то есть идентификатор владельца и служебное состояние бота
-- любого канала. Оставляем только публичный справочник.
--
-- Сами RPC (my_bot_channel, request_bot_channel, admin_set_bot_channel) и
-- админ-панель работают как security definer / service_role и эти колонки
-- по-прежнему видят.
--
-- Скрипт идемпотентен.
-- ============================================================================

revoke select on public.channels from anon, authenticated;

grant select (id, login, display_name) on public.channels to authenticated;

-- 00_reset_db.sql выдаёт anon широкие default privileges. Новые объекты после
-- этого шага не должны автоматически становиться доступны анонимам.
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke all on functions from anon;
-- Важно: встроенный EXECUTE для PUBLIC на новые функции per-schema
-- ALTER DEFAULT PRIVILEGES не отзывает. Поэтому каждая новая функция должна
-- явно закрываться revoke ... from public, anon (как это сделано в миграциях).


-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('46_bot_access_and_hardening.sql');
