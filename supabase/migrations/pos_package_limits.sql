-- Packages carry product and monthly bill limits (billing.packages[].items / .bills; 0 = no limit).
-- Approving a sign-up and approving a renewal paid for a package apply its price, staff, branches and limits to the shop.

alter table public.pos_payments add column if not exists package jsonb;

create or replace function public.pos_pkg_limit(v jsonb)
returns int language sql immutable as $$ select case when v is null or jsonb_typeof(v) = 'null' then null else greatest((v #>> '{}')::numeric::int, 0) end $$;

create or replace function public.pos_admin_approve_app(p_id uuid, p_slug text, p_note text)
 returns uuid language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare a record; sid uuid; pk jsonb; m int; d int; pr numeric; st int; base numeric; per interval; free boolean; freepk boolean; prod text; br int;
begin
  if not public.pos_is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into a from public.pos_applications where id = p_id for update;
  if a.id is null or a.status <> 'pending' then raise exception 'not_pending' using errcode = 'P0001'; end if;
  if exists (select 1 from public.pos_members where email = lower(a.email)) then raise exception 'email_in_use' using errcode = 'P0001'; end if;
  pk := a.package; m := greatest(coalesce((pk->>'months')::int, 1), 1);
  prod := case when pk->>'product' = 'retail' then 'retail' else 'cafe' end;
  br := greatest(coalesce((pk->>'branches')::int, 1), 1);
  d := coalesce((pk->>'days')::int, 0); free := coalesce(a.amount, 0) = 0;
  freepk := coalesce(pk->>'id', '') in ('free', 'free-r');
  st := case when freepk then public.pos_free_staff() when free then coalesce((pk->>'staff')::int, 0) else coalesce((pk->>'staff')::int, 5) end;
  select case when prod = 'retail' then coalesce((data->>'priceRetail')::numeric, 349) else coalesce((data->>'price')::numeric, 299) end into base from public.pos_platform where key = 'billing';
  per := case when freepk then make_interval(days => 30) when d > 0 then make_interval(days => d) else make_interval(months => m) end;
  pr := case when free then coalesce(base, 299) else round(coalesce((pk->>'price')::numeric, a.amount) / m) end;
  insert into public.pos_shops(slug, name, price, staff_limit, expires_at, trial, product, branch_limit, product_limit, bill_limit)
  values (lower(trim(p_slug)), a.shop_name, pr, st, now() + per, free and not freepk, prod, br,
          case when freepk then null else public.pos_pkg_limit(pk->'items') end, case when freepk then null else public.pos_pkg_limit(pk->'bills') end)
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

-- Renewal / upgrade: the manager picks a package. Monthly packages can be paid for several months at once.
create or replace function public.pos_pay_submit(p_sid uuid, p_months integer, p_slip text, p_note text, p_pkg text)
 returns uuid language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare pid uuid; pk jsonb; prod text; m int; amt numeric;
begin
  if not (public.pos_is_admin() or (p_sid = public.pos_my_shop() and public.pos_my_role() = 'manager')) then
    raise exception 'forbidden' using errcode = '42501'; end if;
  if p_slip is null or p_slip not like p_sid::text || '/%' then raise exception 'bad_slip' using errcode = 'P0001'; end if;
  if (select count(*) from public.pos_payments where shop_id = p_sid and status = 'pending') >= 5 then raise exception 'too_many_pending' using errcode = 'P0001'; end if;
  select coalesce(product, 'cafe') into prod from public.pos_shops where id = p_sid;
  select x into pk from public.pos_platform, jsonb_array_elements(data->'packages') x
   where key = 'billing' and x->>'id' = p_pkg and coalesce(x->>'product', 'cafe') = prod and coalesce((x->>'price')::numeric, 0) > 0 limit 1;
  if pk is null then raise exception 'bad_package' using errcode = 'P0001'; end if;
  if greatest(coalesce((pk->>'months')::int, 1), 1) > 1 then
    m := (pk->>'months')::int; amt := (pk->>'price')::numeric;
  else
    if p_months is null or p_months not between 1 and 24 then raise exception 'bad_months' using errcode = 'P0001'; end if;
    m := p_months; amt := (pk->>'price')::numeric * p_months;
  end if;
  insert into public.pos_payments(shop_id, amount, months, slip, note, created_by, package)
  values (p_sid, amt, m, p_slip, left(nullif(trim(p_note), ''), 300), public.pos_email(), pk) returning id into pid;
  return pid;
end $function$;
revoke all on function public.pos_pay_submit(uuid, integer, text, text, text) from public, anon;
grant execute on function public.pos_pay_submit(uuid, integer, text, text, text) to authenticated;

create or replace function public.pos_pay_review(p_id uuid, p_approve boolean, p_note text)
 returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare p record; newexp timestamptz; st int; prod text; pk jsonb;
begin
  if not public.pos_is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into p from public.pos_payments where id = p_id for update;
  if p.id is null or p.status <> 'pending' then raise exception 'not_pending' using errcode = 'P0001'; end if;
  if p_approve then
    pk := p.package;
    select coalesce(product, 'cafe') into prod from public.pos_shops where id = p.shop_id;
    if pk is not null then
      update public.pos_shops set expires_at = greatest(expires_at, now()) + make_interval(months => p.months),
        price = round(coalesce((pk->>'price')::numeric, 0) / greatest(coalesce((pk->>'months')::int, 1), 1)),
        staff_limit = coalesce((pk->>'staff')::int, staff_limit),
        branch_limit = case when prod = 'retail' then greatest(coalesce((pk->>'branches')::int, branch_limit, 1), 1) else branch_limit end,
        product_limit = public.pos_pkg_limit(pk->'items'), bill_limit = public.pos_pkg_limit(pk->'bills'),
        trial = false
      where id = p.shop_id returning expires_at into newexp;
    else
      select coalesce(max((x->>'staff')::int) filter (where (x->>'months')::int = p.months and coalesce((x->>'price')::numeric, 0) > 0),
                      max((x->>'staff')::int) filter (where coalesce((x->>'price')::numeric, 0) > 0), 5)
        into st from public.pos_platform, jsonb_array_elements(data->'packages') x where key = 'billing' and coalesce(x->>'product', 'cafe') = prod;
      update public.pos_shops set expires_at = greatest(expires_at, now()) + make_interval(months => p.months),
        staff_limit = case when trial then greatest(staff_limit, coalesce(st, 5)) else staff_limit end,
        trial = false
      where id = p.shop_id returning expires_at into newexp;
    end if;
  end if;
  update public.pos_payments set status = case when p_approve then 'approved' else 'rejected' end, reviewed_at = now(),
    reviewed_by = public.pos_email(), admin_note = left(nullif(trim(p_note), ''), 300), period_to = newexp where id = p_id;
  return jsonb_build_object('expiresAt', newexp);
end $function$;

-- Package tiers (the admin edits them in Settings). Same tiers for Cafe and Retail.
update public.pos_platform set data = data || jsonb_build_object('price', 49, 'priceRetail', 49, 'packages', (
  select jsonb_agg(t.p || jsonb_build_object('product', pr.prod, 'id', case when pr.prod = 'retail' then 'r-' else '' end || (t.p->>'id')) order by pr.o, t.o)
  from (values ('cafe', 1), ('retail', 2)) pr(prod, o),
       (values
         (1, '{"id":"trial","name":"ทดลองใช้ฟรี 30 วัน","days":30,"trial":true,"months":1,"price":0,"staff":0,"branches":1,"items":20,"bills":100}'::jsonb),
         (2, '{"id":"p49","name":"เริ่มต้น","months":1,"price":49,"staff":1,"branches":1,"items":50,"bills":500}'::jsonb),
         (3, '{"id":"p99","name":"มาตรฐาน","months":1,"price":99,"staff":3,"branches":1,"items":150,"bills":1500}'::jsonb),
         (4, '{"id":"p199","name":"โปร","months":1,"price":199,"staff":5,"branches":2,"items":500,"bills":5000}'::jsonb),
         (5, '{"id":"p499","name":"ธุรกิจ","months":1,"price":499,"staff":10,"branches":5,"items":2000,"bills":20000}'::jsonb)) t(o, p)))
where key = 'billing';
