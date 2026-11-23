-- ============================================================================
-- Шаг 47: закрыть RPC request_bot_badge_access для authenticated.
--
-- После перехода на обмен кода через Supabase Edge Function (twitch-badge)
-- кабинет больше не вызывает request_bot_badge_access: функция twitch-badge
-- сама пишет bot_badge_requested_at и сбрасывает bot_badge_at под service_role
-- после проверки Twitch scope channel:bot. Поэтому authenticated больше не
-- должен иметь прямой путь к записи bot_badge-полей — ни через RPC, ни через
-- таблицу channels (которая у него и так только читается).
--
-- Роль service_role сохраняется: функция остаётся доступной для service_role
-- (отладка/совместимость), а фактически поля пишет только код под этим ключом.
--
-- Скрипт идемпотентен.
-- ============================================================================

select assert_migration('47_bot_badge_rpc_hardening.sql');

-- Закрываем вызов для authenticated. revoke ... from authenticated не трогает
-- service_role: у него права выданы отдельным grant.
revoke execute on function request_bot_badge_access() from authenticated;

-- На случай, если в базе функция всё ещё доступна public/anon (старые права),
-- закрываем и их явно — как требуют default privileges из шага 50.
revoke execute on function request_bot_badge_access() from public, anon;

-- Проверка: authenticated не должен уметь вызвать RPC ни при каких условиях.
-- (service_role сохраняет execute.)
do $$
begin
    if has_function_privilege('authenticated', 'public.request_bot_badge_access()', 'execute') then
        raise exception 'authenticated всё ещё может вызвать request_bot_badge_access()'
            using errcode = '42501';
    end if;
end $$;

-- Кабинет и анонимные клиенты не должны иметь UPDATE/INSERT/DELETE на
-- channels: все изменения bot_status/bot_banned/bot_badge_* идут через
-- security definer RPC или service_role. Убеждаемся, что на уровне таблицы у
-- authenticated/public/anon нет write-прав (идемпотентно).
revoke insert, update, delete on public.channels from authenticated, anon, public;

-- Итоговая проверка: authenticated может читать только публичные колонки и
-- не может писать в channels вообще.
do $$
begin
    if has_table_privilege('authenticated', 'public.channels', 'insert')
       or has_table_privilege('authenticated', 'public.channels', 'update')
       or has_table_privilege('authenticated', 'public.channels', 'delete') then
        raise exception 'authenticated retained write privileges on channels'
            using errcode = '42501';
    end if;
end $$;

comment on function request_bot_badge_access() is
    'Отмечает, что стример выдал channel:bot; бот перепроверит значок чат-бота. '
    'Только service_role: кабинет использует Edge Function twitch-badge.';

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('47_bot_badge_rpc_hardening.sql');