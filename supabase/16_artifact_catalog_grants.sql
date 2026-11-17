-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('16_artifact_catalog_grants.sql', true);

-- Права для синхронизации каталога артефактов из бота.
-- RLS на таблице остаётся включённым; service_role обходит RLS,
-- но ему всё равно нужны табличные привилегии.

grant select, insert, update on table public.artifact_catalog to service_role;

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('16_artifact_catalog_grants.sql');
