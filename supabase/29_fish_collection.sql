-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('29_fish_collection.sql');

-- ============================================================================
-- Шаг 29: коллекция рыб в кабинете.
--
-- Добавляет путь к картинке в справочник items (и в публичную вьюху),
-- а также RPC, возвращающую distinct item_id пойманных рыб игрока на канале.
-- Картинки хранятся в репозитории (assets/fish-images), Storage не используется.
--
-- Запускать в Supabase → SQL Editor после 28_shop_items_modifiers.sql.
-- Скрипт идемпотентен.
-- ============================================================================

alter table if exists items add column if not exists image_path text;

-- Заполняем пути по умолчанию для рыб (только пустые), чтобы коллекция
-- работала сразу после применения миграции.
update public.items
   set image_path = 'assets/fish-images/' || id || '.webp'
 where kind = 'fish'
   and (image_path is null or btrim(image_path) = '');

-- Пересоздаём вьюху: create or replace view не умеет добавлять колонки.
drop view if exists public.items_public;

create view public.items_public as
select
    id,
    name,
    rarity,
    price,
    kind,
    level_required,
    max_uses,
    description,
    type_modifiers,
    rarity_modifiers,
    image_path
from public.items;

comment on view public.items_public is
    'Публичная часть справочника предметов для кабинета: только витринные колонки (включая image_path).';

revoke all on public.items_public from anon, authenticated;
grant select on public.items_public to authenticated;

-- RPC: distinct item_id рыб, пойманных игроком на канале.
-- Проверка: канал принадлежит auth.uid() через players/accounts.
create or replace function my_caught_fish_ids(p_channel_id bigint)
returns table(item_id text)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_user bigint;
begin
    if auth.uid() is null then
        raise exception 'требуется вход' using errcode = '28000';
    end if;

    select a.user_id into v_user
      from accounts a
     where a.auth_id = auth.uid()
     limit 1;

    if v_user is null then
        raise exception 'аккаунт не найден' using errcode = '28000';
    end if;

    -- Канал должен принадлежать этому игроку.
    if not exists (
        select 1 from players p
         where p.channel_id = p_channel_id
           and p.user_id = v_user
    ) then
        raise exception 'канал не принадлежит игроку' using errcode = '42501';
    end if;

    return query
        select distinct c.item_id
          from catches c
         where c.channel_id = p_channel_id
           and c.user_id = v_user;
end $$;

comment on function my_caught_fish_ids(bigint) is
    'Distinct item_id уловов игрока на канале (для коллекции).';

revoke all on function my_caught_fish_ids(bigint) from public, anon;
grant execute on function my_caught_fish_ids(bigint) to authenticated;

-- Отметка в учёте миграций.
select register_migration('29_fish_collection.sql');