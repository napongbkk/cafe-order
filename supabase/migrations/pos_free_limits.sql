-- Free mode limits: products per shop and bills per calendar month (Asia/Bangkok).
-- Admin sets billing.freeItems (default 50) and billing.freeBills (default 500).

create or replace function public.pos_free_limits()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'items', greatest(coalesce((select (data->>'freeItems')::int from public.pos_platform where key = 'billing'), 50), 0),
    'bills', greatest(coalesce((select (data->>'freeBills')::int from public.pos_platform where key = 'billing'), 500), 0)) $$;

create or replace function public.pos_month_start_ms()
returns bigint language sql stable set search_path = public, pg_temp as $$
  select (extract(epoch from (date_trunc('month', now() at time zone 'Asia/Bangkok') at time zone 'Asia/Bangkok')) * 1000)::bigint $$;

-- Products (cafe menu / retail products) and bills (cafe orders / retail sales) used by a shop.
create or replace function public.pos_free_usage(p_shop uuid)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'items', (select count(*) from public.pos_data where shop_id = p_shop and col in ('menu', 'products')),
    'bills', (select count(*) from public.pos_data where shop_id = p_shop and col in ('orders', 'sales')
               and case when jsonb_typeof(coalesce(data->'createdAt', data->'ts')) = 'number'
                        then (coalesce(data->>'createdAt', data->>'ts'))::numeric >= public.pos_month_start_ms() else false end)) $$;

create or replace function public.pos_free_guard()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare lim jsonb; u jsonb;
begin
  if new.col not in ('menu', 'products', 'orders', 'sales') then return new; end if;
  if not public.pos_free_mode() then return new; end if;
  if exists (select 1 from public.pos_data where shop_id = new.shop_id and col = new.col and id = new.id) then return new; end if;
  lim := public.pos_free_limits(); u := public.pos_free_usage(new.shop_id);
  if new.col in ('menu', 'products') and (u->>'items')::int >= (lim->>'items')::int then
    raise exception 'free_items_limit' using errcode = 'P0001';
  end if;
  if new.col in ('orders', 'sales') and (u->>'bills')::int >= (lim->>'bills')::int then
    raise exception 'free_bills_limit' using errcode = 'P0001';
  end if;
  return new;
end $$;

create trigger pos_data_free_guard before insert on public.pos_data for each row execute function public.pos_free_guard();

-- Public billing: free mode also tells the landing/signup pages the limits.
create or replace function public.pos_public_billing()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select case when coalesce((data->>'freeMode')::boolean, false) then
     jsonb_build_object('freeMode', true, 'freeItems', public.pos_free_limits()->'items', 'freeBills', public.pos_free_limits()->'bills', 'packages', jsonb_build_array(
       jsonb_build_object('id', 'free', 'product', 'cafe', 'name', 'ใช้งานฟรี', 'price', 0, 'months', 1, 'staff', public.pos_free_staff(), 'free', true),
       jsonb_build_object('id', 'free-r', 'product', 'retail', 'name', 'ใช้งานฟรี', 'price', 0, 'months', 1, 'staff', public.pos_free_staff(), 'free', true)))
   else jsonb_build_object('freeMode', false, 'packages', coalesce(data->'packages', '[]'::jsonb), 'price', coalesce((data->>'price')::numeric, 299),
     'priceRetail', coalesce((data->>'priceRetail')::numeric, 349), 'promptpay', data->>'promptpay', 'bankName', data->>'bankName',
     'bankNo', data->>'bankNo', 'accountName', data->>'accountName', 'note', data->>'note') end
   from public.pos_platform where key = 'billing' $$;

-- Session: shops in free mode get their limits and usage.
create or replace function public.pos_session(p_slug text default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare adm boolean := public.pos_is_admin(); sid uuid; rl text; s record; grace int; bill jsonb; fm boolean := public.pos_free_mode();
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
  return jsonb_build_object('email', public.pos_email(), 'admin', adm, 'role', rl,
    'billing', case when rl = 'manager' then bill end,
    'shop', case when s.id is null then null else jsonb_build_object('id', s.id, 'slug', s.slug, 'name', s.name, 'status', s.status, 'product', s.product,
      'price', s.price, 'staffLimit', case when fm then greatest(coalesce(s.staff_limit, 0), public.pos_free_staff()) else s.staff_limit end,
      'branchLimit', case when s.product = 'retail' then s.branch_limit end,
      'branchUsed', (select count(*) from public.pos_data where shop_id = s.id and col = 'branches'),
      'expiresAt', s.expires_at, 'graceUntil', s.expires_at + make_interval(days => grace),
      'locked', public.pos_shop_locked(s.id), 'userPrefix', s.user_prefix, 'trial', coalesce(s.trial, false) and not fm, 'free', fm,
      'freeLimits', case when fm then public.pos_free_limits() end,
      'freeUsage', case when fm then public.pos_free_usage(s.id) end,
      'staffUsed', (select count(*) from public.pos_members where shop_id = s.id and role = 'staff' and active)) end);
end $$;

-- Live usage for the shop's own POS (refreshed before a new bill / product).
create or replace function public.pos_my_free_usage()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare sid uuid := public.pos_my_shop();
begin
  if sid is null or not public.pos_free_mode() then return null; end if;
  return public.pos_free_limits() || jsonb_build_object('usedItems', (public.pos_free_usage(sid)->>'items')::int, 'usedBills', (public.pos_free_usage(sid)->>'bills')::int);
end $$;
grant execute on function public.pos_my_free_usage() to authenticated;
revoke execute on function public.pos_free_usage(uuid) from public, anon, authenticated;
