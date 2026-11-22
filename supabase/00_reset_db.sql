-- ============================================================================
-- Шаг R: полное пересоздание схемы public (запускать только осознанно).
--
-- ВНИМАНИЕ: удаляет ВСЁ в схеме public — таблицы, вьюхи, функции, данные,
-- политики RLS и учёт миграций. Схемы auth и storage не трогаются: аккаунты
-- Supabase Auth остаются, но связка accounts (Twitch ID ↔ auth) пропадёт.
--
-- Зачем: если проще начать с нуля, чем разбираться, какие шаги применены.
-- После этого файла база пустая и все шаги идут строго по порядку —
-- 00, затем 01…31 (00b в этом случае не нужен).
--
-- Запускать в Supabase → SQL Editor, отдельным запросом.
-- ============================================================================

drop schema if exists public cascade;
create schema public;

-- Возвращаем права, которые Supabase выдаёт схеме public по умолчанию:
-- без них после пересоздания anon/authenticated не увидят даже свои вьюхи.
grant usage on schema public to anon, authenticated, service_role;
grant all   on schema public to postgres;

-- Права по умолчанию для объектов, которые создадут следующие шаги.
-- Это стандартное поведение Supabase: доступ к таблицам всё равно
-- ограничивают политики RLS, а функции шаги выдают точечно.
alter default privileges in schema public grant all on tables     to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions  to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences  to anon, authenticated, service_role;

select 'схема public пересоздана, шаги можно запускать с 00_schema_migrations.sql' as result;
