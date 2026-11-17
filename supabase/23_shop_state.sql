-- ============================================================================
-- Шаг 23: окно магазина артефактов, общее для бота и кабинета.
--
-- Магазин открывает только бот (команда !artshop_open, админка или случайный
-- ивент), но купить артефакт теперь можно и в кабинете. Поэтому окно магазина
-- хранится в базе: кабинет получает его через Realtime и не может «открыть»
-- магазин сам, а покупка проверяет окно прямо в buy_artifact.
--
-- Запускать в Supabase → SQL Editor после 22_sell_quantity.sql.
-- Скрипт идемпотентен.
-- ============================================================================

create table if not exists public.shop_state (
    channel_id          bigint      primary key references channels (id) on delete cascade,
    -- Момент закрытия. null или прошедшее время — магазин закрыт.
    artifact_open_until timestamptz,
    updated_at          timestamptz not null default now()
);

comment on table public.shop_state is
    'Состояние магазинов канала: окно артефактов пишет бот, кабинет только читает.';
comment on column public.shop_state.artifact_open_until is
    'До какого момента открыт магазин артефактов. Прошедшее время = закрыт.';

alter table public.shop_state enable row level security;

-- Кабинет читает состояние всех своих каналов: так он узнаёт, что магазин
-- открыт на другом канале, и может предложить переключиться.
drop policy if exists "shop_state: чтение" on public.shop_state;
create policy "shop_state: чтение" on public.shop_state
    for select to authenticated using (true);

revoke all on public.shop_state from anon, authenticated;
grant select on public.shop_state to authenticated;
grant select, insert, update, delete on public.shop_state to service_role;

-- Realtime: кабинет узнаёт об открытии сразу, без опроса и без команд в чате.
do $$
begin
    if not exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename = 'shop_state'
    ) then
        alter publication supabase_realtime add table public.shop_state;
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- artifact_shop_open(): одно место, где решается, открыт ли магазин
-- ---------------------------------------------------------------------------

create or replace function artifact_shop_open(p_channel_id bigint)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1
        from shop_state s
        where s.channel_id = p_channel_id
          and s.artifact_open_until > now()
    );
$$;

comment on function artifact_shop_open(bigint) is
    'Открыт ли магазин артефактов канала: проверяет окно shop_state.';

revoke all on function artifact_shop_open(bigint) from public, anon;
grant execute on function artifact_shop_open(bigint) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- buy_artifact(): покупка только при открытом магазине
-- ---------------------------------------------------------------------------
-- Проверки типа, уровня, денег и ролл статов остаются в buy_artifact_impl
-- (17_buy_artifact.sql). Здесь добавляется единственное условие — окно
-- магазина: без него кабинет мог бы купить артефакт в любой момент.
-- Переименование вместо копирования тела, чтобы правила покупки не разъехались.

do $$
begin
    if to_regprocedure('public.buy_artifact(text,bigint,bigint,text,text)') is not null
       and to_regprocedure('public.buy_artifact_impl(text,bigint,bigint,text,text)') is null then
        alter function public.buy_artifact(text, bigint, bigint, text, text)
            rename to buy_artifact_impl;
    end if;
end $$;

drop function if exists buy_artifact(text, bigint, bigint, text, text);

create or replace function buy_artifact(
    p_item_id    text,
    p_channel_id bigint,
    p_user_id    bigint default null,
    p_username   text default null,
    p_message_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_channel_id is null or p_item_id is null or btrim(p_item_id) = '' then
        return jsonb_build_object(
            'ok', false,
            'code', 'bad_request',
            'error', 'Нужны канал и артефакт.'
        );
    end if;

    if not artifact_shop_open(p_channel_id) then
        return jsonb_build_object(
            'ok', false,
            'code', 'shop_closed',
            'error', 'Магазин артефактов закрыт — он открывается ненадолго. Следите за чатом!'
        );
    end if;

    return buy_artifact_impl(p_item_id, p_channel_id, p_user_id, p_username, p_message_id);
end $$;

comment on function buy_artifact(text, bigint, bigint, text, text) is
    'Покупка артефакта при открытом магазине: проверка окна, затем buy_artifact_impl.';

-- Обёртку вызывают кабинет и бот, impl — только бот: иначе проверку окна
-- можно обойти прямым вызовом функции.
revoke all on function buy_artifact_impl(text, bigint, bigint, text, text) from public, anon, authenticated;
grant execute on function buy_artifact_impl(text, bigint, bigint, text, text) to service_role;

revoke all on function buy_artifact(text, bigint, bigint, text, text) from public, anon;
grant execute on function buy_artifact(text, bigint, bigint, text, text) to authenticated, service_role;
