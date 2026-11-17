-- Права для синхронизации каталога артефактов из бота.
-- RLS на таблице остаётся включённым; service_role обходит RLS,
-- но ему всё равно нужны табличные привилегии.

grant select, insert, update on table public.artifact_catalog to service_role;
