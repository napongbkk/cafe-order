-- Freemium: every shop can use Coconut POS (Cafe and Retail) for free with 50 products and 200 bills per month (Asia/Bangkok).
-- Going over needs a paid package (billing.packages), which lifts the limits for the paid period.
-- When a paid period ends (after the grace days) the shop drops back to the free limits instead of being locked.
-- Only a shop the admin suspends is locked.

alter table public.pos_shops add column if not exists free_plan boolean not null default false;

-- Shop is on the free tier: signed up on the free package, or its paid period has run out.
create or replace function public.pos_shop_free(p_sid uuid)
 returns boolean language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  select coalesce((select s.free_plan or coalesce(s.trial, false) or public.pos_free_mode()
      or now() > s.expires_at + make_interval(days => coalesce((select (data->>'graceDays')::int from public.pos_platform where key = 'billing'), 7))
    from public.pos_shops s where s.id = p_sid), true)
$function$;

-- Effective limits. NULL = no limit. On the free tier the free limits apply (an admin override on a free_plan shop still wins);
-- a paid shop uses the limits of the package it paid for (product_limit / bill_limit; 0 or NULL = no limit).
create or replace function public.pos_retail_limits(p_sid uuid)
 returns jsonb language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  with s as (select x.*, public.pos_shop_free(x.id) as fr,
                    now() > x.expires_at + make_interval(days => coalesce((select (data->>'graceDays')::int from public.pos_platform where key = 'billing'), 7)) as lapsed
             from public.pos_shops x where x.id = p_sid)
  select jsonb_build_object(
      'plan_free', s.fr,
      'products', case when s.fr and (s.lapsed and not s.free_plan or s.product_limit is null) then (public.pos_free_limits()->>'items')::int
                       when s.product_limit is null or s.product_limit = 0 then null else s.product_limit end,
      'bills', case when s.fr and (s.lapsed and not s.free_plan or s.bill_limit is null) then (public.pos_free_limits()->>'bills')::int
                    when s.bill_limit is null or s.bill_limit = 0 then null else s.bill_limit end)
  from s
$function$;

-- No more locking for unpaid shops: they keep selling within the free limits.
create or replace function public.pos_shop_locked(p_sid uuid)
 returns boolean language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$ select coalesce((select s.status = 'suspended' from public.pos_shops s where s.id = p_sid), true) $function$;

-- Sign-up approval: the free package starts on the free tier straight away (no paid period, no expiry to count down).
create or replace function public.pos_admin_approve_app(p_id uuid, p_slug text, p_note text)
 returns uuid language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare a record; sid uuid; pk jsonb; m int; d int; pr numeric; st int; base numeric; per interval; free boolean; prod text; br int;
begin
  if not public.pos_is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into a from public.pos_applications where id = p_id for update;
  if a.id is null or a.status <> 'pending' then raise exception 'not_pending' using errcode = 'P0001'; end if;
  if exists (select 1 from public.pos_members where email = lower(a.email)) then raise exception 'email_in_use' using errcode = 'P0001'; end if;
  pk := a.package; m := greatest(coalesce((pk->>'months')::int, 1), 1);
  prod := case when pk->>'product' = 'retail' then 'retail' else 'cafe' end;
  br := greatest(coalesce((pk->>'branches')::int, 1), 1);
  d := coalesce((pk->>'days')::int, 0); free := coalesce(a.amount, 0) = 0;
  st := case when free then coalesce((pk->>'staff')::int, public.pos_free_staff()) else coalesce((pk->>'staff')::int, 5) end;
  select case when prod = 'retail' then coalesce((data->>'priceRetail')::numeric, 349) else coalesce((data->>'price')::numeric, 299) end into base from public.pos_platform where key = 'billing';
  per := case when free then make_interval() when d > 0 then make_interval(days => d) else make_interval(months => m) end;
  pr := case when free then 0 else round(coalesce((pk->>'price')::numeric, a.amount) / m) end;
  insert into public.pos_shops(slug, name, price, staff_limit, expires_at, trial, free_plan, product, branch_limit, product_limit, bill_limit)
  values (lower(trim(p_slug)), a.shop_name, pr, st, now() + per, false, free, prod, br,
          case when free then null else public.pos_pkg_limit(pk->'items') end, case when free then null else public.pos_pkg_limit(pk->'bills') end)
  returning id into sid;
  insert into public.pos_members(email, shop_id, role, name) values (lower(a.email), sid, 'manager', trim(a.first_name || ' ' || a.last_name));
  if prod = 'retail' then
    insert into public.pos_data(shop_id, col, id, data) values
      (sid, 'settings', 'main', jsonb_build_object('id', 'main', 'shop', a.shop_name, 'address', a.address, 'phone', a.phone, 'vatMode', 'incl', 'vatRate', 7, 'pointPer', 25, 'footer', 'ขอบคุณที่อุดหนุน', 'display', true)),
      (sid, 'branches', 'b1', jsonb_build_object('id', 'b1', 'code', 'HQ', 'name', a.shop_name, 'type', 'branch'));
  else
    insert into public.pos_data(shop_id, col, id, data) values
      (sid, 'settings', 'shop', jsonb_build_object('name', a.shop_name, 'address', a.address, 'phone', a.phone, 'appOpen', false, 'appTake', true, 'zones', jsonb_build_array('ในร้าน'))),
      (sid, 'categories', 'c1', jsonb_build_object('name', 'เครื่องดื่ม', 'sort', 0));
  end if;
  if not free then
    insert into public.pos_payments(shop_id, amount, months, slip, note, status, created_at, created_by, reviewed_at, reviewed_by, admin_note, period_to, package)
    values (sid, a.amount, m, a.slip, 'สมัครเปิดร้าน · ' || coalesce(pk->>'name', ''), 'approved', a.created_at, lower(a.email), now(), public.pos_email(), left(nullif(trim(p_note), ''), 300), now() + per, pk);
  end if;
  update public.pos_applications set status = 'approved', shop_id = sid, reviewed_at = now(), reviewed_by = public.pos_email(), admin_note = left(nullif(trim(p_note), ''), 300) where id = p_id;
  return sid;
end $function$;

-- Paying for a package moves a free shop onto it (pos_pay_review already extends expires_at from now and applies the package limits).
create or replace function public.pos_free_plan_off()
 returns trigger language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
begin
  if new.status = 'approved' and old.status is distinct from 'approved' then
    update public.pos_shops set free_plan = false where id = new.shop_id and free_plan;
  end if;
  return new;
end $function$;
create trigger pos_payments_free_plan_off after update on public.pos_payments for each row execute function public.pos_free_plan_off();

-- Platform settings: packages are shown again (free mode off), free tier 50 products / 200 bills, and the 30-day trial
-- packages become the free packages (ids free / free-r, which the sign-up function already knows).
update public.pos_platform set data = data || jsonb_build_object('freeMode', false, 'freeItems', 50, 'freeBills', 200, 'packages', (
  select jsonb_agg(case when x->>'id' in ('trial', 'r-trial')
      then jsonb_build_object('id', case when x->>'product' = 'retail' then 'free-r' else 'free' end, 'product', coalesce(x->>'product', 'cafe'),
             'name', 'ใช้งานฟรี', 'months', 1, 'price', 0, 'free', true, 'staff', 1, 'branches', 1, 'items', 50, 'bills', 200)
      else x end order by o)
  from jsonb_array_elements(data->'packages') with ordinality t(x, o)))
where key = 'billing';

-- Shops that never paid are on the free tier.
update public.pos_shops s set free_plan = true, trial = false
where not exists (select 1 from public.pos_payments p where p.shop_id = s.id and p.status = 'approved');
