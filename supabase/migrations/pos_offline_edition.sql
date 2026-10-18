-- Coconut POS Stand alone (offline) edition. The shop's data lives on its own machine; the online system keeps the
-- shop, logins, packages and billing. The admin sees standalone shops separately, with the devices that checked in.
alter table public.pos_shops add column if not exists edition text not null default 'online';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'pos_shops_edition_chk') then
    alter table public.pos_shops add constraint pos_shops_edition_chk check (edition in ('online', 'offline'));
  end if; end $$;

create table if not exists public.pos_offline_devices(
  id text primary key, shop_id uuid not null references public.pos_shops(id) on delete cascade,
  kind text not null default 'server', name text, platform text, version text, lan text,
  products int, bills_month int, last_email text,
  first_seen timestamptz not null default now(), last_seen timestamptz not null default now());
alter table public.pos_offline_devices enable row level security;
create index if not exists pos_offline_devices_shop on public.pos_offline_devices(shop_id);

-- Called by the standalone app after a successful online sign-in, and again at least every few days.
create or replace function public.pos_offline_checkin(p_device jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare sid uuid := public.pos_my_shop(); ed text; did text := p_device->>'id'; days int; ses jsonb;
begin
  if sid is null then raise exception 'no_shop' using errcode = 'P0001'; end if;
  select edition into ed from public.pos_shops where id = sid;
  if ed <> 'offline' then raise exception 'not_offline' using errcode = 'P0001'; end if;
  if did is not null and did ~ '^[A-Za-z0-9_-]{8,64}$' then
    insert into public.pos_offline_devices(id, shop_id, kind, name, platform, version, lan, products, bills_month, last_email)
    values (did, sid, case when p_device->>'kind' = 'client' then 'client' else 'server' end, left(p_device->>'name', 80), left(p_device->>'platform', 40),
            left(p_device->>'version', 20), left(p_device->>'lan', 60), nullif(p_device->>'products', '')::int, nullif(p_device->>'bills', '')::int, public.pos_email())
    on conflict (id) do update set shop_id = excluded.shop_id, name = coalesce(excluded.name, pos_offline_devices.name), platform = coalesce(excluded.platform, pos_offline_devices.platform),
      version = coalesce(excluded.version, pos_offline_devices.version), lan = coalesce(excluded.lan, pos_offline_devices.lan),
      products = coalesce(excluded.products, pos_offline_devices.products), bills_month = coalesce(excluded.bills_month, pos_offline_devices.bills_month),
      last_email = excluded.last_email, last_seen = now();
  end if;
  select greatest(coalesce((data->>'offlineDays')::int, 7), 1) into days from public.pos_platform where key = 'billing';
  ses := public.pos_session(null);
  return ses || jsonb_build_object('offlineDays', coalesce(days, 7), 'serverTime', now(),
    'name', (select name from public.pos_members where email = public.pos_email() limit 1));
end $$;
revoke all on function public.pos_offline_checkin(jsonb) from public, anon;
grant execute on function public.pos_offline_checkin(jsonb) to authenticated;

create or replace function public.pos_admin_set_edition(p_sid uuid, p_edition text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.pos_is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_edition not in ('online', 'offline') then raise exception 'bad_edition' using errcode = 'P0001'; end if;
  update public.pos_shops set edition = p_edition where id = p_sid;
end $$;
revoke all on function public.pos_admin_set_edition(uuid, text) from public, anon;
grant execute on function public.pos_admin_set_edition(uuid, text) to authenticated;

create or replace function public.pos_admin_offline_devices()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.pos_is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(d) order by d.last_seen desc) from public.pos_offline_devices d), '[]'::jsonb);
end $$;
revoke all on function public.pos_admin_offline_devices() from public, anon;
grant execute on function public.pos_admin_offline_devices() to authenticated;

-- Session and admin list carry the edition (and, for standalone shops, the usage the app last reported).
create or replace function public.pos_session(p_slug text default null::text)
 returns jsonb language plpgsql stable security definer set search_path to 'public', 'pg_temp'
as $function$
declare adm boolean := public.pos_is_admin(); sid uuid; rl text; s record; grace int; bill jsonb; fm boolean := public.pos_free_mode(); lim jsonb; u jsonb;
begin
  select data into bill from public.pos_platform where key = 'billing';
  grace := coalesce((bill->>'graceDays')::int, 7);
  if adm and nullif(trim(p_slug), '') is not null then
    select id into sid from public.pos_shops where slug = lower(trim(p_slug));
    rl := 'manager';
  else
    sid := public.pos_my_shop(); rl := public.pos_my_role();
  end if;
  select * into s from public.pos_shops where id = sid;
  lim := case when s.id is null then null else public.pos_retail_limits(s.id) end;
  u := case when s.id is null then null else public.pos_shop_usage(s.id) end;
  return jsonb_build_object('email', public.pos_email(), 'admin', adm, 'role', rl,
    'billing', case when rl = 'manager' then bill end,
    'shop', case when s.id is null then null else jsonb_build_object('id', s.id, 'slug', s.slug, 'name', s.name, 'status', s.status, 'product', s.product,
      'edition', coalesce(s.edition, 'online'),
      'price', s.price, 'staffLimit', case when fm then greatest(coalesce(s.staff_limit, 0), public.pos_free_staff()) else s.staff_limit end,
      'branchLimit', case when s.product = 'retail' then s.branch_limit end,
      'branchUsed', (select count(*) from public.pos_data where shop_id = s.id and col = 'branches'),
      'productLimit', lim->'products', 'billLimit', lim->'bills', 'productsUsed', u->'products', 'billsMonth', u->'bills',
      'planFree', coalesce((lim->>'plan_free')::boolean, false),
      'sheet', s.sheet_id is not null and s.sheet_id <> '', 'sheetSyncedAt', s.sheet_synced_at,
      'expiresAt', s.expires_at, 'graceUntil', s.expires_at + make_interval(days => grace),
      'locked', public.pos_shop_locked(s.id), 'userPrefix', s.user_prefix, 'trial', coalesce(s.trial, false) and not fm, 'free', fm,
      'staffUsed', (select count(*) from public.pos_members where shop_id = s.id and role = 'staff' and active)) end);
end $function$;

create or replace function public.pos_admin_shops()
 returns jsonb language plpgsql stable security definer set search_path to 'public', 'pg_temp'
as $function$
begin
  if not public.pos_is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by x->>'created_at') from (
    select jsonb_build_object('id', s.id, 'slug', s.slug, 'name', s.name, 'status', s.status, 'price', s.price, 'product', s.product,
      'edition', coalesce(s.edition, 'online'),
      'staff_limit', s.staff_limit, 'branch_limit', s.branch_limit, 'expires_at', s.expires_at, 'note', s.note, 'created_at', s.created_at,
      'product_limit', s.product_limit, 'bill_limit', s.bill_limit, 'limits', public.pos_retail_limits(s.id),
      'products_used', case when s.edition = 'offline' then (select products from public.pos_offline_devices where shop_id = s.id and kind = 'server' order by last_seen desc limit 1)
                            else (public.pos_shop_usage(s.id)->>'products')::int end,
      'bills_month', case when s.edition = 'offline' then (select bills_month from public.pos_offline_devices where shop_id = s.id and kind = 'server' order by last_seen desc limit 1)
                          else (public.pos_shop_usage(s.id)->>'bills')::int end,
      'devices', (select count(*) from public.pos_offline_devices where shop_id = s.id),
      'last_seen', (select max(last_seen) from public.pos_offline_devices where shop_id = s.id),
      'sheet_id', s.sheet_id, 'sheet_synced_at', s.sheet_synced_at, 'sheet_error', s.sheet_error,
      'locked', public.pos_shop_locked(s.id),
      'manager', (select jsonb_build_object('email', email, 'name', name) from public.pos_members where shop_id = s.id and role = 'manager' and active limit 1),
      'staff_used', (select count(*) from public.pos_members where shop_id = s.id and role = 'staff' and active),
      'branches_used', (select count(*) from public.pos_data where shop_id = s.id and col = 'branches'),
      'pending', (select count(*) from public.pos_payments where shop_id = s.id and status = 'pending'),
      'last_activity', case when s.edition = 'offline' then (select max(last_seen) from public.pos_offline_devices where shop_id = s.id)
                            else (select max(updated_at) from public.pos_data where shop_id = s.id and col = (case when s.product = 'retail' then 'sales' else 'orders' end)) end,
      'orders_30d', (select count(*) from public.pos_data where shop_id = s.id and col = (case when s.product = 'retail' then 'sales' else 'orders' end) and updated_at > now() - interval '30 days')) x
    from public.pos_shops s) t), '[]'::jsonb);
end $function$;
