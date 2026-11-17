-- ============================================================================
-- Шаг 9: представления для кабинета.
--
-- my_channels      — каналы, на которых играл вошедший игрок, со его статами.
--                    Это данные для селектора канала: канал больше не задаётся
--                    в конфиге страницы, его выбирает игрок после входа.
-- channel_ranking  — рейтинг канала по балансу. Виден только по тем каналам,
--                    где у вошедшего есть свой профиль, поэтому чужие каналы
--                    через него не читаются.
--
-- Запускать в Supabase → SQL Editor. Скрипт идемпотентен.
-- ============================================================================

-- Каналы игрока. security_invoker = true: представление работает с правами
-- вызывающего, поэтому RLS на players/accounts (шаг 10) действует и здесь.
-- drop нужен, чтобы файл можно было перезапускать после добавления колонок:
-- create or replace view не умеет менять состав и порядок колонок.
drop view if exists my_channels;

create view my_channels
with (security_invoker = true) as
select
    p.channel_id,
    c.login,
    c.display_name,
    p.username,
    p.balance,
    p.xp,
    level_from_xp(p.xp) as level,
    xp_for_level(level_from_xp(p.xp))     as xp_for_current,
    xp_for_level(level_from_xp(p.xp) + 1) as xp_for_next,
    p.fish_caught
from players p
join channels c on c.id = p.channel_id
join accounts a on a.user_id = p.user_id
where a.auth_id = (select auth.uid())
order by c.login;

comment on view my_channels is
    'Каналы вошедшего игрока со его статами: источник для селектора канала.';

-- Рейтинг канала. Представление работает с правами владельца, поэтому доступ
-- ограничен явной проверкой: только каналы, где у auth.uid() есть игрок.
drop view if exists channel_ranking;

create view channel_ranking as
select
    p.channel_id,
    p.user_id,
    p.username,
    p.balance,
    p.xp,
    level_from_xp(p.xp) as level,
    p.fish_caught,
    rank() over (partition by p.channel_id order by p.balance desc) as place
from players p
where exists (
    select 1
    from players me
    join accounts a on a.user_id = me.user_id
    where me.channel_id = p.channel_id
      and a.auth_id = (select auth.uid())
);

comment on view channel_ranking is
    'Рейтинг канала по балансу; строки только по каналам, где вошедший играет.';

-- Supabase по умолчанию выдаёт authenticated все права на новые объекты в public,
-- поэтому отзываем всё у обеих ролей и оставляем только чтение.
revoke all on my_channels     from anon, authenticated;
revoke all on channel_ranking from anon, authenticated;

grant select on my_channels     to authenticated;
grant select on channel_ranking to authenticated;
