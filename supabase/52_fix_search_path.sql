-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('52_fix_search_path.sql');

-- ============================================================================
-- Шаг 52: закрепление search_path для функций артефактов.
--
-- Supabase Security Advisor помечает функции без SET search_path как
-- «role mutable search_path». Закрепляем search_path = public, чтобы
-- разрешение имён объектов не зависело от роли вызывающего.
-- ALTER FUNCTION ... SET search_path идемпотентен и не меняет логику.
-- ============================================================================

alter function public.level_from_xp(integer) set search_path = public;
alter function public.xp_for_level(integer) set search_path = public;
alter function public.artifact_roll_effect(jsonb) set search_path = public;
alter function public.artifact_roll_effects(jsonb) set search_path = public;
alter function public.artifact_worsen_value(text, text, numeric, numeric) set search_path = public;
alter function public.artifact_worsen_effects(jsonb, numeric) set search_path = public;
alter function public.repair_cost_of(numeric, numeric, numeric) set search_path = public;

-- Отметка в учёте миграций.
select register_migration('52_fix_search_path.sql');