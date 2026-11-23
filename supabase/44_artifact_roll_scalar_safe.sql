-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('44_artifact_roll_scalar_safe.sql');

-- ============================================================================
-- Шаг 44: устойчивость ролла статов артефактов к скалярам в effects/curse_effects.
--
-- В Postgres jsonb_array_elements падает с «cannot extract elements from a scalar»,
-- если передать не массив. Старая версия artifact_roll_effects делала
-- coalesce(p_effects, '[]'), который спасает только от NULL, но не от скаляра.
-- Теперь не-массивы приводятся к пустому массиву.
--
-- Запускать в Supabase → SQL Editor после 43_drop_unique_fish_index.sql.
-- Скрипт идемпотентен в смысле функций (create or replace), нормализация
-- данных выполняется один раз.
-- ============================================================================

create or replace function artifact_roll_effects(p_effects jsonb)
returns jsonb
language sql
volatile
as $$
    select coalesce(
        jsonb_agg(artifact_roll_effect(effect) order by ord),
        '[]'::jsonb
    )
    from jsonb_array_elements(
        case when jsonb_typeof(coalesce(p_effects, '[]'::jsonb)) = 'array'
             then coalesce(p_effects, '[]'::jsonb)
             else '[]'::jsonb
        end
    )
         with ordinality as t(effect, ord);
$$;

comment on function artifact_roll_effects(jsonb) is
    'Перероллить все эффекты артефакта из каталога. Устойчив к не-массивам.';

create or replace function artifact_worsen_effects(p_effects jsonb, p_factor numeric)
returns jsonb
language sql
volatile
as $$
    select coalesce(
        jsonb_agg(
            jsonb_strip_nulls(jsonb_build_object(
                'type', rolled->>'type',
                'target', rolled->'target',
                'value', case
                    when rolled->>'type' in ('gold_bonus', 'inventory_bonus')
                        then floor(artifact_worsen_value(
                            rolled->>'type',
                            rolled->>'target',
                            (rolled->>'value')::numeric,
                            p_factor
                        ) + 0.5)
                    else floor(artifact_worsen_value(
                        rolled->>'type',
                        rolled->>'target',
                        (rolled->>'value')::numeric,
                        p_factor
                    ) * 1000 + 0.5) / 1000
                end
            )) order by ord
        ),
        '[]'::jsonb
    )
    from jsonb_array_elements(
        case when jsonb_typeof(coalesce(p_effects, '[]'::jsonb)) = 'array'
             then coalesce(p_effects, '[]'::jsonb)
             else '[]'::jsonb
        end
    )
         with ordinality as t(effect, ord)
    cross join lateral (select artifact_roll_effect(effect) as rolled) r;
$$;

comment on function artifact_worsen_effects(jsonb, numeric) is
    'Усилить проклятие артефакта. Устойчив к не-массивам.';

-- Нормализация: любые скаляры/объекты в effects/curse_effects приводим к [].
update public.artifact_catalog
    set effects = '[]'::jsonb
    where jsonb_typeof(effects) is distinct from 'array';

update public.artifact_catalog
    set curse_effects = '[]'::jsonb
    where jsonb_typeof(curse_effects) is distinct from 'array';

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('44_artifact_roll_scalar_safe.sql');