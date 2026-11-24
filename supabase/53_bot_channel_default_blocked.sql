-- ============================================================================
-- Шаг 53: новая заявка на бота по умолчанию заблокирована.
--
-- Раньше request_bot_channel() создавал строку channels с bot_banned = false:
-- стример нажимал «Подключить бота» и бот сам заходил в чат. Теперь любая
-- заявка (включая на уже существующую строку канала) начинается заблокированной:
-- бот не входит в чат, пока владелец бота не снимет блокировку в админ-панели.
-- Стример в кабинете видит «Подключение заблокировано» и обращение к
-- администратору бота.
--
-- Функция переопределяется целиком: create or replace не меняет сигнатуру.
-- Права (authenticated, service_role) сохраняются, но переопределяем их явно,
-- чтобы не зависеть от того, как были выданы раньше.
--
-- Запускать в Supabase → SQL Editor после 52_fix_search_path.sql.
-- Скрипт идемпотентен по учёту миграций.
-- ============================================================================

select assert_migration('53_bot_channel_default_blocked.sql');

-- --------------------------------------------------------------------------- 
-- request_bot_channel(): заявка стартует заблокированной
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
            id, login, display_name, owner_auth_id, bot_status, bot_requested_at,
            bot_banned, bot_banned_at
        )
        values (
            v_twitch, v_login, v_display, v_uid, 'pending', now(),
            true, now()
        )
        on conflict (id) do update
            set login            = excluded.login,
                display_name      = coalesce(excluded.display_name, channels.display_name),
                owner_auth_id     = coalesce(channels.owner_auth_id, excluded.owner_auth_id),
                -- Уже работающий бот не начинает подключаться заново.
                bot_status        = case when channels.bot_status = 'active'
                                         then 'active' else 'pending' end,
                bot_requested_at  = case when channels.bot_status = 'active'
                                         then channels.bot_requested_at else now() end,
                -- Новая заявка (в том числе на уже существующую строку канала)
                -- начинается заблокированной. Уже работающий бот при повторном
                -- нажатии не блокируется.
                bot_banned        = case when channels.bot_status = 'active'
                                         then channels.bot_banned else true end,
                bot_banned_at     = case when channels.bot_status = 'active'
                                         then channels.bot_banned_at
                                         else coalesce(channels.bot_banned_at, now()) end
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
    'Заявка стримера на подключение бота к собственному каналу (pending). '
    'Новая заявка по умолчанию заблокирована до решения владельца бота.';

revoke all on function request_bot_channel() from public, anon;
grant execute on function request_bot_channel() to authenticated, service_role;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('53_bot_channel_default_blocked.sql');
