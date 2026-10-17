-- Easy POS Retail: free-plan limits (products, bills per month) and per-shop Google Sheet sync.
-- Limits: pos_shops.product_limit / bill_limit. NULL = by plan (free or trial: 50 products, 500 bills a month; paid: no limit),
--         0 = no limit, any other number = that limit (set by the admin). Enforced by a trigger on pos_data (Retail shops only).
-- Sheets: pos_shops.sheet_id (the shop's own spreadsheet, shared with the system's Google service account),
--         the service-account key is kept in pos_secrets (write-only for admins), the edge function pos-sheets copies data across.

alter table public.pos_shops add column if not exists product_limit int;
alter table public.pos_shops add column if not exists bill_limit int;
alter table public.pos_shops add column if not exists sheet_id text;
alter table public.pos_shops add column if not exists sheet_synced_at timestamptz;
alter table public.pos_shops add column if not exists sheet_error text;

create or replace function public.pos_retail_limits(p_sid uuid)
 returns jsonb language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  select case when s.product <> 'retail' then jsonb_build_object('products', null, 'bills', null) else
    jsonb_build_object(
      'plan_free', (coalesce(s.trial, false) or public.pos_free_mode()),
      'products', case when s.product_limit is null then (case when coalesce(s.trial, false) or public.pos_free_mode() then 50 end)
                       when s.product_limit = 0 then null else s.product_limit end,
      'bills', case when s.bill_limit is null then (case when coalesce(s.trial, false) or public.pos_free_mode() then 500 end)
                    when s.bill_limit = 0 then null else s.bill_limit end) end
  from public.pos_shops s where s.id = p_sid
$function$;
revoke all on function public.pos_retail_limits(uuid) from public, anon;
grant execute on function public.pos_retail_limits(uuid) to authenticated;

create or replace function public.pos_data_limit_guard()
 returns trigger language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare lim jsonb; n int; mstart timestamptz;
begin
  if new.col not in ('products', 'sales') or public.pos_is_admin() then return new; end if;
  if exists (select 1 from public.pos_data where shop_id = new.shop_id and col = new.col and id = new.id) then return new; end if;
  lim := public.pos_retail_limits(new.shop_id);
  if new.col = 'products' and (lim->>'products') is not null then
    select count(*) into n from public.pos_data where shop_id = new.shop_id and col = 'products';
    if n >= (lim->>'products')::int then raise exception 'product_limit' using errcode = 'P0001'; end if;
  elsif new.col = 'sales' and (lim->>'bills') is not null then
    mstart := date_trunc('month', now() at time zone 'Asia/Bangkok') at time zone 'Asia/Bangkok';
    select count(*) into n from public.pos_data where shop_id = new.shop_id and col = 'sales' and (case when (data->>'ts') ~ '^[0-9]+$' then to_timestamp(((data->>'ts')::numeric) / 1000) else updated_at end) >= mstart;
    if n >= (lim->>'bills')::int then raise exception 'bill_limit' using errcode = 'P0001'; end if;
  end if;
  return new;
end $function$;
drop trigger if exists pos_data_limit_guard on public.pos_data;
create trigger pos_data_limit_guard before insert on public.pos_data for each row execute function public.pos_data_limit_guard();

-- Session: limits and usage for the POS, sheet link for the shop.
create or replace function public.pos_session(p_slug text default null::text)
 returns jsonb language plpgsql stable security definer set search_path to 'public', 'pg_temp'
as $function$
declare adm boolean := public.pos_is_admin(); sid uuid; rl text; s record; grace int; bill jsonb; fm boolean := public.pos_free_mode(); lim jsonb;
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
  return jsonb_build_object('email', public.pos_email(), 'admin', adm, 'role', rl,
    'billing', case when rl = 'manager' then bill end,
    'shop', case when s.id is null then null else jsonb_build_object('id', s.id, 'slug', s.slug, 'name', s.name, 'status', s.status, 'product', s.product,
      'price', s.price, 'staffLimit', case when fm then greatest(coalesce(s.staff_limit, 0), public.pos_free_staff()) else s.staff_limit end,
      'branchLimit', case when s.product = 'retail' then s.branch_limit end,
      'branchUsed', (select count(*) from public.pos_data where shop_id = s.id and col = 'branches'),
      'productLimit', lim->'products', 'billLimit', lim->'bills', 'planFree', coalesce((lim->>'plan_free')::boolean, false),
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
      'products_used', (select count(*) from public.pos_data where shop_id = s.id and col = 'products'),
      'bills_month', (select count(*) from public.pos_data where shop_id = s.id and col = 'sales' and updated_at >= date_trunc('month', now() at time zone 'Asia/Bangkok') at time zone 'Asia/Bangkok'),
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

-- Admin stores the Google service-account key (write-only) and reads back only its e-mail.
create or replace function public.pos_admin_set_google_key(p_json text)
 returns text language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare j jsonb; em text;
begin
  if not public.pos_is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if nullif(trim(p_json), '') is null then delete from public.pos_secrets where key = 'GOOGLE_SA_JSON'; return null; end if;
  begin j := p_json::jsonb; exception when others then raise exception 'bad_json' using errcode = 'P0001'; end;
  em := j->>'client_email';
  if em is null or (j->>'private_key') is null then raise exception 'bad_key' using errcode = 'P0001'; end if;
  insert into public.pos_secrets(key, value) values ('GOOGLE_SA_JSON', p_json) on conflict (key) do update set value = excluded.value;
  insert into public.pos_platform(key, data) values ('google', jsonb_build_object('email', em)) on conflict (key) do update set data = jsonb_build_object('email', em);
  return em;
end $function$;
revoke all on function public.pos_admin_set_google_key(text) from public, anon;
grant execute on function public.pos_admin_set_google_key(text) to authenticated;
