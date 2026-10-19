-- Renewals: at most 6 months per payment, charged at the monthly price x months (no discount).
-- No new payments while the admin has payments closed (billing.freeMode).
create or replace function public.pos_pay_submit(p_sid uuid, p_months integer, p_slip text, p_note text, p_pkg text)
 returns uuid language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare pid uuid; pk jsonb; prod text; m int; amt numeric;
begin
  if not (public.pos_is_admin() or (p_sid = public.pos_my_shop() and public.pos_my_role() = 'manager')) then
    raise exception 'forbidden' using errcode = '42501'; end if;
  if public.pos_free_mode() then raise exception 'payments_closed' using errcode = 'P0001'; end if;
  if p_slip is null or p_slip not like p_sid::text || '/%' then raise exception 'bad_slip' using errcode = 'P0001'; end if;
  if (select count(*) from public.pos_payments where shop_id = p_sid and status = 'pending') >= 5 then raise exception 'too_many_pending' using errcode = 'P0001'; end if;
  select coalesce(product, 'cafe') into prod from public.pos_shops where id = p_sid;
  select x into pk from public.pos_platform, jsonb_array_elements(data->'packages') x
   where key = 'billing' and x->>'id' = p_pkg and coalesce(x->>'product', 'cafe') = prod and coalesce((x->>'price')::numeric, 0) > 0 limit 1;
  if pk is null then raise exception 'bad_package' using errcode = 'P0001'; end if;
  if greatest(coalesce((pk->>'months')::int, 1), 1) > 1 then
    m := (pk->>'months')::int; amt := (pk->>'price')::numeric;
    if m > 6 then raise exception 'bad_months' using errcode = 'P0001'; end if;
  else
    if p_months is null or p_months not between 1 and 6 then raise exception 'bad_months' using errcode = 'P0001'; end if;
    m := p_months; amt := (pk->>'price')::numeric * p_months;
  end if;
  insert into public.pos_payments(shop_id, amount, months, slip, note, created_by, package)
  values (p_sid, amt, m, p_slip, left(nullif(trim(p_note), ''), 300), public.pos_email(), pk) returning id into pid;
  return pid;
end $function$;
revoke all on function public.pos_pay_submit(uuid, integer, text, text, text) from public, anon;
grant execute on function public.pos_pay_submit(uuid, integer, text, text, text) to authenticated;
