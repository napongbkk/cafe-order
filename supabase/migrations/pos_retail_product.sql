-- Easy POS Retail: shops have a product type (cafe | retail).
-- Adds pos_shops.product, lets the admin create Retail shops, and returns the type in the admin list and the session.

alter table public.pos_shops add column if not exists product text not null default 'cafe';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'pos_shops_product_chk') then
    alter table public.pos_shops add constraint pos_shops_product_chk check (product in ('cafe','retail'));
  end if;
end $$;

drop function if exists public.pos_admin_create_shop(text, text, text, text, numeric, integer, integer, text);
create or replace function public.pos_admin_create_shop(p_slug text, p_name text, p_manager text, p_manager_name text, p_price numeric, p_staff_limit integer, p_days integer, p_app_url text, p_product text default 'cafe')
 returns uuid language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare sid uuid; em text := lower(trim(p_manager)); pr text := case when p_product = 'retail' then 'retail' else 'cafe' end;
begin
  if not public.pos_is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if exists (select 1 from public.pos_members where email = em) then raise exception 'email_in_use' using errcode = 'P0001'; end if;
  insert into public.pos_shops(slug, name, price, staff_limit, expires_at, product)
  values (lower(trim(p_slug)), trim(p_name), coalesce(p_price, 299), coalesce(p_staff_limit, 5), now() + make_interval(days => greatest(coalesce(p_days, 30), 0)), pr)
  returning id into sid;
  insert into public.pos_members(email, shop_id, role, name) values (em, sid, 'manager', nullif(trim(p_manager_name), ''));
  if pr = 'cafe' then
    insert into public.pos_data(shop_id, col, id, data) values
      (sid, 'settings', 'shop', jsonb_build_object('name', trim(p_name), 'appOpen', false, 'appTake', true,
         'appUrl', coalesce(nullif(trim(p_app_url), ''), ''), 'zones', jsonb_build_array('ในร้าน'))),
      (sid, 'categories', 'c1', jsonb_build_object('name', 'เครื่องดื่ม', 'sort', 0));
  else
    insert into public.pos_data(shop_id, col, id, data) values
      (sid, 'settings', 'main', jsonb_build_object('id', 'main', 'shop', trim(p_name), 'vatMode', 'incl', 'vatRate', 7, 'pointPer', 25, 'footer', 'ขอบคุณที่อุดหนุน', 'display', true)),
      (sid, 'branches', 'b1', jsonb_build_object('id', 'b1', 'code', 'HQ', 'name', trim(p_name), 'type', 'branch'));
  end if;
  return sid;
end $function$;
revoke all on function public.pos_admin_create_shop(text, text, text, text, numeric, integer, integer, text, text) from public, anon;
grant execute on function public.pos_admin_create_shop(text, text, text, text, numeric, integer, integer, text, text) to authenticated;

create or replace function public.pos_admin_shops()
 returns jsonb language plpgsql stable security definer set search_path to 'public', 'pg_temp'
as $function$
begin
  if not public.pos_is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by x->>'created_at') from (
    select jsonb_build_object('id', s.id, 'slug', s.slug, 'name', s.name, 'status', s.status, 'price', s.price, 'product', s.product,
      'staff_limit', s.staff_limit, 'expires_at', s.expires_at, 'note', s.note, 'created_at', s.created_at,
      'locked', public.pos_shop_locked(s.id),
      'manager', (select jsonb_build_object('email', email, 'name', name) from public.pos_members where shop_id = s.id and role = 'manager' and active limit 1),
      'staff_used', (select count(*) from public.pos_members where shop_id = s.id and role = 'staff' and active),
      'pending', (select count(*) from public.pos_payments where shop_id = s.id and status = 'pending'),
      'last_activity', (select max(updated_at) from public.pos_data where shop_id = s.id and col = (case when s.product = 'retail' then 'sales' else 'orders' end)),
      'orders_30d', (select count(*) from public.pos_data where shop_id = s.id and col = (case when s.product = 'retail' then 'sales' else 'orders' end) and updated_at > now() - interval '30 days')) x
    from public.pos_shops s) t), '[]'::jsonb);
end $function$;

create or replace function public.pos_session(p_slug text default null::text)
 returns jsonb language plpgsql stable security definer set search_path to 'public', 'pg_temp'
as $function$
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
      'expiresAt', s.expires_at, 'graceUntil', s.expires_at + make_interval(days => grace),
      'locked', public.pos_shop_locked(s.id), 'userPrefix', s.user_prefix, 'trial', coalesce(s.trial, false) and not fm, 'free', fm,
      'staffUsed', (select count(*) from public.pos_members where shop_id = s.id and role = 'staff' and active)) end);
end $function$;
