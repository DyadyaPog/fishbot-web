-- Проверка порядка: файл применяется один раз и только после предыдущих шагов.
select assert_migration('31_unique_fish_claims.sql');

-- ============================================================================
-- Шаг 31: реестр занятых уникальных тегов рыбы.
--
-- Раньше бот вычислял занятые теги, читая все рыбы из inventory. На большом
-- инвентаре это упиралось в лимит Supabase и могло пропустить занятый тег.
-- Теперь занятость хранится отдельно и читается одним маленьким запросом:
--
--   select unique_tag from unique_fish_claims where channel_id = ...;
--
-- inventory_id связывает claim с конкретной строкой инвентаря. Благодаря
-- on delete cascade продажа (в том числе через кабинет), удаление игрока или
-- ручная очистка inventory автоматически освобождают тег.
--
-- Запускать в Supabase → SQL Editor после 30_hidden_sell_guard.sql.
-- Скрипт идемпотентен.
-- ============================================================================

create table if not exists public.unique_fish_claims (
    channel_id   bigint      not null references public.channels(id) on delete cascade,
    unique_tag   text        not null check (btrim(unique_tag) <> ''),
    inventory_id bigint      not null unique
                              references public.inventory(id) on delete cascade,
    acquired_at  timestamptz not null default now(),
    primary key (channel_id, unique_tag)
);

comment on table public.unique_fish_claims is
    'Занятые уникальные теги рыбы: одна рыба с тегом на канал. Строка удаляется каскадом вместе с inventory.';

-- Keyset-пагинация бота: channel_id + inventory_id.
create index if not exists idx_unique_fish_claims_channel_inventory
    on public.unique_fish_claims (channel_id, inventory_id);

alter table public.unique_fish_claims enable row level security;
revoke all on table public.unique_fish_claims from public, anon, authenticated;
grant select, insert, update, delete on table public.unique_fish_claims to service_role;

-- ---------------------------------------------------------------------------
-- Автоматический claim при вставке улова с meta.uniqueTag.
-- Если тег уже занят, unique(channel_id, unique_tag) отменяет вставку inventory.
-- ---------------------------------------------------------------------------
create or replace function public.claim_unique_fish()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_tag text := nullif(btrim(new.meta->>'uniqueTag'), '');
begin
    if new.item_type <> 'fish' or v_tag is null then
        return new;
    end if;

    insert into public.unique_fish_claims (
        channel_id,
        unique_tag,
        inventory_id,
        acquired_at
    )
    values (
        new.channel_id,
        v_tag,
        new.id,
        new.created_at
    );

    return new;
end $$;

comment on function public.claim_unique_fish() is
    'Создаёт claim уникального тега вместе со вставкой строки inventory.';

revoke all on function public.claim_unique_fish() from public, anon, authenticated;

drop trigger if exists inventory_unique_fish_claim on public.inventory;
create trigger inventory_unique_fish_claim
after insert on public.inventory
for each row execute function public.claim_unique_fish();

-- Уникальная механика новая: до этого шага уникальных рыб в inventory нет,
-- поэтому реестр стартует пустым. Все будущие claim'ы создаст триггер вместе
-- с вставкой строки inventory.

-- Отметка в учёте миграций.
select register_migration('31_unique_fish_claims.sql');
