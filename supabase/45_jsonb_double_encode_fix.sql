-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('45_jsonb_double_encode_fix.sql');

-- ============================================================================
-- Шаг 45: исправление JSON, записанного двойным кодированием.
--
-- Причина: бот передавал в jsonb-колонки уже сериализованную строку
-- (JSON.stringify(...) + ::jsonb). Драйвер postgres.js сериализует строку для
-- jsonb ещё раз, поэтому в базе оказывалось не массив/объект, а jsonb-строка
-- вида '"[{\"type\":...}]"'. jsonb_typeof() для таких значений возвращает
-- 'string', jsonb_array_elements() падает с «cannot extract elements from a
-- scalar», а кабинет не видит статов артефактов и модификаторов снаряжения.
--
-- Код бота исправлен (значения передаются объектами, без JSON.stringify).
-- Здесь распаковываются строки, которые уже успели попасть в базу: строка
-- разбирается как JSON и заменяет саму себя. Если разобрать не удалось,
-- подставляется пустое значение того же вида, что ждут потребители.
--
-- Запускать в Supabase → SQL Editor после 44_artifact_roll_scalar_safe.sql.
-- Скрипт идемпотентен: значения, которые уже массив/объект, не меняются.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Распаковка строки: '"[1,2]"' → '[1,2]'. Не-строки возвращаются как есть,
-- несколько уровней кодирования снимаются за один вызов.
-- ---------------------------------------------------------------------------
create or replace function jsonb_unwrap_string(p_value jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
    v_value jsonb := p_value;
    v_text  text;
begin
    if v_value is null then
        return null;
    end if;

    for _ in 1..5 loop
        exit when jsonb_typeof(v_value) is distinct from 'string';

        v_text := v_value #>> '{}';
        exit when v_text is null or btrim(v_text) = '';

        begin
            v_value := v_text::jsonb;
        exception when others then
            -- Строка не является JSON: оставляем как есть, вызывающий код
            -- сам решит, чем её заменить.
            exit;
        end;
    end loop;

    return v_value;
end $$;

comment on function jsonb_unwrap_string(jsonb) is
    'Снимает двойное кодирование JSON: jsonb-строка разбирается как JSON.';

-- ---------------------------------------------------------------------------
-- Каталог артефактов: effects и curse_effects должны быть массивами.
-- ---------------------------------------------------------------------------
update public.artifact_catalog
   set effects = case
       when jsonb_typeof(jsonb_unwrap_string(effects)) = 'array'
           then jsonb_unwrap_string(effects)
       else '[]'::jsonb
   end
 where jsonb_typeof(effects) is distinct from 'array';

update public.artifact_catalog
   set curse_effects = case
       when jsonb_typeof(jsonb_unwrap_string(curse_effects)) = 'array'
           then jsonb_unwrap_string(curse_effects)
       else '[]'::jsonb
   end
 where jsonb_typeof(curse_effects) is distinct from 'array';

-- ---------------------------------------------------------------------------
-- Справочник предметов: модификаторы снаряжения должны быть объектами.
-- ---------------------------------------------------------------------------
update public.items
   set type_modifiers = case
       when jsonb_typeof(jsonb_unwrap_string(type_modifiers)) = 'object'
           then jsonb_unwrap_string(type_modifiers)
       else '{}'::jsonb
   end
 where jsonb_typeof(type_modifiers) is distinct from 'object';

update public.items
   set rarity_modifiers = case
       when jsonb_typeof(jsonb_unwrap_string(rarity_modifiers)) = 'object'
           then jsonb_unwrap_string(rarity_modifiers)
       else '{}'::jsonb
   end
 where jsonb_typeof(rarity_modifiers) is distinct from 'object';

-- ---------------------------------------------------------------------------
-- Инвентарь: meta — объект, вложенные effects/curse_effects — массивы.
-- ---------------------------------------------------------------------------
update public.inventory
   set meta = case
       when jsonb_typeof(jsonb_unwrap_string(meta)) = 'object'
           then jsonb_unwrap_string(meta)
       else '{}'::jsonb
   end
 where jsonb_typeof(meta) is distinct from 'object';

update public.inventory
   set meta = jsonb_set(meta, '{effects}', case
           when jsonb_typeof(jsonb_unwrap_string(meta -> 'effects')) = 'array'
               then jsonb_unwrap_string(meta -> 'effects')
           else '[]'::jsonb
       end, true)
 where jsonb_typeof(meta -> 'effects') = 'string';

update public.inventory
   set meta = jsonb_set(meta, '{curse_effects}', case
           when jsonb_typeof(jsonb_unwrap_string(meta -> 'curse_effects')) = 'array'
               then jsonb_unwrap_string(meta -> 'curse_effects')
           else '[]'::jsonb
       end, true)
 where jsonb_typeof(meta -> 'curse_effects') = 'string';

-- ---------------------------------------------------------------------------
-- События: payload — объект, вложенные effects — массив.
-- ---------------------------------------------------------------------------
update public.events
   set payload = case
       when jsonb_typeof(jsonb_unwrap_string(payload)) = 'object'
           then jsonb_unwrap_string(payload)
       else '{}'::jsonb
   end
 where jsonb_typeof(payload) is distinct from 'object';

update public.events
   set payload = jsonb_set(payload, '{effects}', case
           when jsonb_typeof(jsonb_unwrap_string(payload -> 'effects')) = 'array'
               then jsonb_unwrap_string(payload -> 'effects')
           else '[]'::jsonb
       end, true)
 where jsonb_typeof(payload -> 'effects') = 'string';

-- ---------------------------------------------------------------------------
-- Шансы игрока: types и rarities_if_fish — объекты.
-- ---------------------------------------------------------------------------
update public.player_chances
   set types = case
       when jsonb_typeof(jsonb_unwrap_string(types)) = 'object'
           then jsonb_unwrap_string(types)
       else '{}'::jsonb
   end
 where jsonb_typeof(types) is distinct from 'object';

update public.player_chances
   set rarities_if_fish = case
       when jsonb_typeof(jsonb_unwrap_string(rarities_if_fish)) = 'object'
           then jsonb_unwrap_string(rarities_if_fish)
       else '{}'::jsonb
   end
 where jsonb_typeof(rarities_if_fish) is distinct from 'object';

-- Отметка в учёте миграций: повторный запуск этого файла будет остановлен.
select register_migration('45_jsonb_double_encode_fix.sql');
