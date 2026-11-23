-- ============================================================================
-- Шаг 50: отзывы игроков из кабинета.
--
-- Отзыв пишет только вошедший через Twitch игрок и только по каналу, где у
-- него есть профиль. Канал и автора функция берёт из auth/Twitch, поэтому
-- подставить чужой канал или имя нельзя.
--
-- Ограничения:
--   * пустой отзыв не принимается;
--   * минимум 20 символов и 3 слова — отсекает «спасибо» и «всё круто»;
--   * максимум 500 символов;
--   * не чаще одного отзыва в минуту и не больше пяти в день на игрока.
--
-- Таблица закрыта от кабинета: читать и писать её можно только через RPC
-- submit_player_feedback(), а service_role (админка/бот) видит всё.
--
-- Запускать в Supabase → SQL Editor после 49_bot_heartbeat.sql.
-- Если 00_schema_migrations.sql уже применялся, сначала запустите его ещё раз:
-- он добавит этот файл в migration_order, иначе assert_migration остановится.
-- Скрипт идемпотентен.
-- ============================================================================

select assert_migration('50_player_feedback.sql');

create table if not exists public.player_feedback (
    id         bigserial   primary key,
    channel_id bigint      not null references public.channels (id) on delete cascade,
    user_id    bigint      not null references public.accounts (user_id) on delete cascade,
    username   text,
    message    text        not null,
    created_at timestamptz not null default now(),
    constraint player_feedback_message_length
        check (char_length(message) between 20 and 500)
);

comment on table public.player_feedback is
    'Отзывы игроков из кабинета: автор, канал и текст.';
comment on column public.player_feedback.username is
    'Имя автора на момент отправки (players.username или Twitch display name).';

create index if not exists idx_player_feedback_user_created
    on public.player_feedback (user_id, created_at desc);
create index if not exists idx_player_feedback_channel_created
    on public.player_feedback (channel_id, created_at desc);

alter table public.player_feedback enable row level security;

-- Политик нет: кабинет ходит только через RPC, админка/бот — service_role.
revoke all on public.player_feedback from public, anon, authenticated;
grant select, insert, update, delete on public.player_feedback to service_role;
grant usage, select on sequence public.player_feedback_id_seq to service_role;

-- ---------------------------------------------------------------------------
-- submit_player_feedback(): отзыв вошедшего игрока по его каналу
-- ---------------------------------------------------------------------------

create or replace function submit_player_feedback(p_channel_id bigint, p_message text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_twitch    bigint;
    v_login     text;
    v_display   text;
    v_username  text;
    v_message   text := btrim(coalesce(p_message, ''));
    v_recent    integer;
    v_today     integer;
    v_id        bigint;
    v_created   timestamptz;
begin
    if auth.uid() is null then
        raise exception 'требуется вход через Twitch' using errcode = '28000';
    end if;

    select t.twitch_id, t.login, t.display_name
      into v_twitch, v_login, v_display
      from bot_caller_twitch() t;

    if p_channel_id is null then
        raise exception 'не указан канал' using errcode = '22023';
    end if;

    -- Отзыв разрешён только по каналу, где у игрока есть профиль: это тот же
    -- список, из которого кабинет строит селектор my_channels.
    select coalesce(nullif(p.username, ''), v_display, v_login)
      into v_username
      from players p
     where p.channel_id = p_channel_id
       and p.user_id    = v_twitch;

    if not found then
        raise exception 'на этом канале нет вашего профиля' using errcode = '42501';
    end if;

    if v_message = '' then
        raise exception 'отзыв не может быть пустым' using errcode = '22023';
    end if;

    if char_length(v_message) < 20 then
        raise exception 'отзыв слишком короткий: минимум 20 символов' using errcode = '22023';
    end if;

    if char_length(v_message) > 500 then
        raise exception 'отзыв слишком длинный: максимум 500 символов' using errcode = '22023';
    end if;

    if v_message !~ '[[:alnum:]]' then
        raise exception 'отзыв должен содержать текст' using errcode = '22023';
    end if;

    if array_length(regexp_split_to_array(v_message, '[[:space:]]+'), 1) < 3 then
        raise exception 'отзыв слишком короткий: нужно минимум 3 слова' using errcode = '22023';
    end if;

    -- Сериализуем одновременные отправки одного игрока: без блокировки два
    -- параллельных запроса могли бы оба пройти проверку «раз в минуту».
    perform pg_advisory_xact_lock(v_twitch);

    select count(*) into v_recent
      from player_feedback f
     where f.user_id = v_twitch
       and f.created_at > now() - interval '60 seconds';

    if v_recent > 0 then
        raise exception 'слишком часто: новый отзыв можно отправить через минуту'
            using errcode = 'P0001';
    end if;

    select count(*) into v_today
      from player_feedback f
     where f.user_id = v_twitch
       and f.created_at >= date_trunc('day', now());

    if v_today >= 5 then
        raise exception 'дневной лимит: не больше 5 отзывов в день'
            using errcode = 'P0001';
    end if;

    insert into player_feedback (channel_id, user_id, username, message)
    values (p_channel_id, v_twitch, v_username, v_message)
    returning id, created_at into v_id, v_created;

    return jsonb_build_object(
        'ok', true,
        'id', v_id,
        'createdAt', v_created
    );
end $$;

comment on function submit_player_feedback(bigint, text) is
    'Принимает отзыв вошедшего игрока по каналу, где у него есть профиль.';

revoke all on function submit_player_feedback(bigint, text) from public, anon;
grant execute on function submit_player_feedback(bigint, text) to authenticated, service_role;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('50_player_feedback.sql');