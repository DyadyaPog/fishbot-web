-- ============================================================================
-- Шаг 48: дата входа в чат не переживает бан канала.
--
-- Кабинет показывает «в чате с …» по channels.bot_joined_at. При блокировке
-- бот выходит из чата, но колонка оставалась заполненной, поэтому после
-- разблокировки стример видел старое время входа, хотя бот только что вернулся.
--
-- Теперь admin_set_bot_channel при блокировке очищает bot_joined_at, а бот
-- заполняет его заново при повторном входе (markBotChannelJoined). Ручной
-- active через панель по-прежнему не подставляет время входа.
--
-- Запускать в Supabase → SQL Editor после 47_bot_badge_rpc_hardening.sql.
-- Скрипт идемпотентен.
-- ============================================================================

select assert_migration('48_bot_joined_at_cleanup.sql');

-- Строки, заблокированные до этого шага, тоже не должны хранить дату входа.
update public.channels
   set bot_joined_at = null
 where bot_banned
   and bot_joined_at is not null;

-- ---------------------------------------------------------------------------
-- admin_set_bot_channel(): блокировка очищает время входа
-- ---------------------------------------------------------------------------
-- Определение совпадает с шагом 46, кроме bot_joined_at в SET. Функция
-- остаётся только для service_role: админ-панель работает ключом бота.

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
                                   else bot_banned_at end,
           -- Бот вышел из чата: пусть время следующего входа запишет сам бот.
           bot_joined_at    = case when p_banned is true then null
                                   else bot_joined_at end
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
    'Статус бота и блокировка канала из админ-панели (только service_role); блокировка очищает bot_joined_at.';

revoke all on function admin_set_bot_channel(bigint, text, boolean) from public, anon, authenticated;
grant execute on function admin_set_bot_channel(bigint, text, boolean) to service_role;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('48_bot_joined_at_cleanup.sql');
