-- Visitor statistics for the platform admin. One row per (day, page, visitor); a visitor is a random id kept in the browser.
-- Signed-in POS users are marked logged with their shop. Days follow Asia/Bangkok.
create table if not exists public.pos_visits(
  day date not null, page text not null, vid text not null,
  hits int not null default 1, logged boolean not null default false, shop_id uuid,
  first_at timestamptz not null default now(), last_at timestamptz not null default now(),
  primary key (day, page, vid));
alter table public.pos_visits enable row level security;
create index if not exists pos_visits_day on public.pos_visits(day);

create or replace function public.pos_track(p_page text, p_vid text, p_slug text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare d date := (now() at time zone 'Asia/Bangkok')::date; sid uuid; lg boolean := auth.uid() is not null;
begin
  if p_page is null or p_page !~ '^[a-z0-9-]{2,24}$' or p_vid is null or p_vid !~ '^[A-Za-z0-9]{8,40}$' then return; end if;
  if lg then sid := public.pos_my_shop(); end if;
  if sid is null and nullif(trim(p_slug), '') is not null then select id into sid from public.pos_shops where slug = lower(trim(p_slug)); end if;
  insert into public.pos_visits(day, page, vid, logged, shop_id) values (d, p_page, p_vid, lg, sid)
  on conflict (day, page, vid) do update set hits = least(pos_visits.hits + 1, 100000), last_at = now(),
    logged = pos_visits.logged or excluded.logged, shop_id = coalesce(excluded.shop_id, pos_visits.shop_id);
end $$;
revoke all on function public.pos_track(text, text, text) from public;
grant execute on function public.pos_track(text, text, text) to anon, authenticated;

create or replace function public.pos_admin_visits(p_days int default 30)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare n int := least(greatest(coalesce(p_days, 30), 1), 365); d0 date; today date := (now() at time zone 'Asia/Bangkok')::date;
begin
  if not public.pos_is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  d0 := today - (n - 1);
  return jsonb_build_object(
    'days', n, 'today', today,
    'daily', (select coalesce(jsonb_agg(x order by x->>'day'), '[]'::jsonb) from (
      select jsonb_build_object('day', g::date, 'visitors', count(distinct v.vid), 'views', coalesce(sum(v.hits), 0),
        'users', count(distinct v.vid) filter (where v.logged), 'shops', count(distinct v.shop_id) filter (where v.logged)) x
      from generate_series(d0, today, interval '1 day') g left join public.pos_visits v on v.day = g::date group by g) t),
    'pages', (select coalesce(jsonb_agg(jsonb_build_object('page', page, 'visitors', vis, 'views', vw) order by vis desc), '[]'::jsonb) from (
      select page, count(distinct vid) vis, sum(hits) vw from public.pos_visits where day >= d0 group by page) p),
    'shops', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'slug', s.slug, 'days', q.dd, 'users', q.u, 'last', q.last) order by q.dd desc, q.last desc), '[]'::jsonb) from (
      select shop_id, count(distinct day) dd, count(distinct vid) u, max(last_at) last from public.pos_visits where day >= d0 and logged and shop_id is not null group by shop_id) q
      join public.pos_shops s on s.id = q.shop_id),
    'total', (select jsonb_build_object('visitors', count(distinct vid), 'views', coalesce(sum(hits), 0), 'users', count(distinct vid) filter (where logged),
      'shops', count(distinct shop_id) filter (where logged)) from public.pos_visits where day >= d0),
    'now', (select count(distinct vid) from public.pos_visits where last_at > now() - interval '5 minutes'));
end $$;
revoke all on function public.pos_admin_visits(int) from public, anon;
grant execute on function public.pos_admin_visits(int) to authenticated;
