-- Per-shop product and monthly bill limits for both Easy POS Cafe and Retail, set by the admin.
-- pos_shops.product_limit / bill_limit: NULL = by plan (free mode or trial: billing.freeItems / freeBills, default 50 / 500; paid: no limit),
-- 0 = no limit, N = that limit. Cafe counts menu items and orders; Retail counts products and sales. Months follow Asia/Bangkok.

create or replace function public.pos_retail_limits(p_sid uuid)
 returns jsonb language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  select jsonb_build_object(
      'plan_free', (coalesce(s.trial, false) or public.pos_free_mode()),
      'products', case when s.product_limit is null then (case when coalesce(s.trial, false) or public.pos_free_mode() then (public.pos_free_limits()->>'items')::int end)
                       when s.product_limit = 0 then null else s.product_limit end,
      'bills', case when s.bill_limit is null then (case when coalesce(s.trial, false) or public.pos_free_mode() then (public.pos_free_limits()->>'bills')::int end)
                    when s.bill_limit = 0 then null else s.bill_limit end)
  from public.pos_shops s where s.id = p_sid
$function$;

create or replace function public.pos_shop_usage(p_sid uuid)
 returns jsonb language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  with s as (select product = 'retail' as r from public.pos_shops where id = p_sid)
  select jsonb_build_object(
    'products', (select count(*) from public.pos_data d, s where d.shop_id = p_sid and d.col = case when s.r then 'products' else 'menu' end),
    'bills', (select count(*) from public.pos_data d, s where d.shop_id = p_sid and d.col = case when s.r then 'sales' else 'orders' end
              and case when jsonb_typeof(d.data->(case when s.r then 'ts' else 'createdAt' end)) = 'number'
                       then (d.data->>(case when s.r then 'ts' else 'createdAt' end))::numeric >= public.pos_month_start_ms()
                       else d.updated_at >= to_timestamp(public.pos_month_start_ms() / 1000.0) end))
$function$;
revoke execute on function public.pos_shop_usage(uuid) from public, anon, authenticated;

create or replace function public.pos_data_limit_guard()
 returns trigger language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare lim jsonb; u jsonb; r boolean;
begin
  if new.col not in ('products', 'sales', 'menu', 'orders') or public.pos_is_admin() then return new; end if;
  select product = 'retail' into r from public.pos_shops where id = new.shop_id;
  if r is null then return new; end if;
  if r and new.col not in ('products', 'sales') then return new; end if;
  if not r and new.col not in ('menu', 'orders') then return new; end if;
  if exists (select 1 from public.pos_data where shop_id = new.shop_id and col = new.col and id = new.id) then return new; end if;
  lim := public.pos_retail_limits(new.shop_id);
  if new.col in ('products', 'menu') then
    if (lim->>'products') is null then return new; end if;
    u := public.pos_shop_usage(new.shop_id);
    if (u->>'products')::int >= (lim->>'products')::int then raise exception 'product_limit' using errcode = 'P0001'; end if;
  else
    if (lim->>'bills') is null then return new; end if;
    u := public.pos_shop_usage(new.shop_id);
    if (u->>'bills')::int >= (lim->>'bills')::int then raise exception 'bill_limit' using errcode = 'P0001'; end if;
  end if;
  return new;
end $function$;

-- The earlier Cafe-only free guard is replaced by pos_data_limit_guard.
create or replace function public.pos_free_guard()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$ begin return new; end $$;

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
      'staff_limit', s.staff_limit, 'branch_limit', s.branch_limit, 'expires_at', s.expires_at, 'note', s.note, 'created_at', s.created_at,
      'product_limit', s.product_limit, 'bill_limit', s.bill_limit, 'limits', public.pos_retail_limits(s.id),
      'products_used', (public.pos_shop_usage(s.id)->>'products')::int,
      'bills_month', (public.pos_shop_usage(s.id)->>'bills')::int,
      'sheet_id', s.sheet_id, 'sheet_synced_at', s.sheet_synced_at, 'sheet_error', s.sheet_error,
      'locked', public.pos_shop_locked(s.id),
      'manager', (select jsonb_build_object('email', email, 'name', name) from public.pos_members where shop_id = s.id and role = 'manager' and active limit 1),
      'staff_used', (select count(*) from public.pos_members where shop_id = s.id and role = 'staff' and active),
      'branches_used', (select count(*) from public.pos_data where shop_id = s.id and col = 'branches'),
      'pending', (select count(*) from public.pos_payments where shop_id = s.id and status = 'pending'),
      'last_activity', (select max(updated_at) from public.pos_data where shop_id = s.id and col = (case when s.product = 'retail' then 'sales' else 'orders' end)),
      'orders_30d', (select count(*) from public.pos_data where shop_id = s.id and col = (case when s.product = 'retail' then 'sales' else 'orders' end) and updated_at > now() - interval '30 days')) x
    from public.pos_shops s) t), '[]'::jsonb);
end $function$;
