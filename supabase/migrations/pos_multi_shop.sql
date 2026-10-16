-- Multi-shop POS: shops, platform admins, monthly billing, per-shop data isolation.
-- Additive only: new tables are created and filled from the single-shop tables (pos_docs, pos_staff, cafe.state),
-- which stay in place but become admin-only.

-- ---------- platform tables ----------
create table if not exists public.pos_shops (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,30}$'),
  name text not null check (length(name) between 1 and 80),
  status text not null default 'active' check (status in ('active','suspended')),
  price numeric not null default 299 check (price >= 0),
  staff_limit int not null default 5 check (staff_limit between 0 and 200),
  expires_at timestamptz not null default now() + interval '30 days',
  note text,
  created_at timestamptz not null default now()
);
alter table public.pos_shops enable row level security;

create table if not exists public.pos_admins (email text primary key, created_at timestamptz not null default now());
alter table public.pos_admins enable row level security;

create table if not exists public.pos_platform (key text primary key, data jsonb not null default '{}'::jsonb, updated_at timestamptz not null default now());
alter table public.pos_platform enable row level security;

create table if not exists public.pos_payments (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.pos_shops(id),
  amount numeric not null check (amount >= 0),
  months int not null check (months between 1 and 24),
  slip text, note text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(), created_by text,
  reviewed_at timestamptz, reviewed_by text, admin_note text, period_to timestamptz
);
create index if not exists pos_payments_shop_idx on public.pos_payments(shop_id, created_at desc);
alter table public.pos_payments enable row level security;

-- one login belongs to one shop
create table if not exists public.pos_members (
  email text primary key,
  shop_id uuid not null references public.pos_shops(id),
  role text not null check (role in ('manager','staff')),
  name text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists pos_members_shop_idx on public.pos_members(shop_id);
alter table public.pos_members enable row level security;

-- per-shop documents (replaces pos_docs)
create table if not exists public.pos_data (
  shop_id uuid not null references public.pos_shops(id),
  col text not null,
  id text not null,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (shop_id, col, id)
);
alter table public.pos_data enable row level security;

-- per-shop customer-app snapshot (replaces cafe.state)
create table if not exists cafe.shop_state (
  shop_id uuid not null references public.pos_shops(id),
  key text not null,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (shop_id, key)
);
alter table cafe.shop_state enable row level security;

-- ---------- move the existing shop in ----------
insert into public.pos_shops (slug, name, expires_at)
select 'main', coalesce((select data->>'name' from public.pos_docs where col = 'settings' and id = 'shop'), 'ร้านแรก'), now() + interval '30 days'
where not exists (select 1 from public.pos_shops);

insert into public.pos_admins (email) values ('napong.subanpong@gmail.com') on conflict do nothing;
insert into public.pos_platform (key, data) values ('billing', jsonb_build_object('price', 299, 'graceDays', 7, 'promptpay', '', 'bankName', '', 'bankNo', '', 'accountName', '', 'note', ''))
on conflict do nothing;

insert into public.pos_members (email, shop_id, role, name, active, created_at)
select lower(email), (select id from public.pos_shops where slug = 'main'), case when role = 'staff' then 'staff' else 'manager' end, name, active, created_at
from public.pos_staff on conflict do nothing;

insert into public.pos_data (shop_id, col, id, data, updated_at)
select (select id from public.pos_shops where slug = 'main'), col, id, data, updated_at from public.pos_docs on conflict do nothing;

insert into cafe.shop_state (shop_id, key, data, updated_at)
select (select id from public.pos_shops where slug = 'main'), key, data, updated_at from cafe.state on conflict do nothing;

alter table cafe.orders add column if not exists shop_id uuid references public.pos_shops(id);
update cafe.orders set shop_id = (select id from public.pos_shops where slug = 'main') where shop_id is null;
alter table cafe.orders alter column shop_id set not null;
create index if not exists cafe_orders_shop_status_idx on cafe.orders(shop_id, status, created_at);

-- ---------- identity helpers ----------
create or replace function public.pos_email() returns text language sql stable as
$$ select lower(coalesce(auth.jwt()->>'email', '')) $$;

create or replace function public.pos_is_admin() returns boolean language sql stable security definer set search_path = public, pg_temp as
$$ select exists (select 1 from public.pos_admins where lower(email) = public.pos_email()) $$;

create or replace function public.pos_my_shop() returns uuid language sql stable security definer set search_path = public, pg_temp as
$$ select shop_id from public.pos_members where email = public.pos_email() and active limit 1 $$;

create or replace function public.pos_my_role() returns text language sql stable security definer set search_path = public, pg_temp as
$$ select role from public.pos_members where email = public.pos_email() and active limit 1 $$;

create or replace function public.pos_shop_locked(p_sid uuid) returns boolean language sql stable security definer set search_path = public, pg_temp as
$$ select coalesce((select s.status = 'suspended'
      or now() > s.expires_at + make_interval(days => coalesce((select (data->>'graceDays')::int from public.pos_platform where key = 'billing'), 7))
    from public.pos_shops s where s.id = p_sid), true) $$;

create or replace function public.pos_can_read(p_sid uuid) returns boolean language sql stable as
$$ select public.pos_is_admin() or (p_sid is not null and p_sid = public.pos_my_shop()) $$;

create or replace function public.pos_can_write(p_sid uuid, p_col text) returns boolean language sql stable as
$$ select public.pos_is_admin()
    or (p_sid is not null and p_sid = public.pos_my_shop() and not public.pos_shop_locked(p_sid)
        and (p_col <> all (array['menu','categories','options','promos','settings','tables']) or public.pos_my_role() = 'manager')) $$;

-- the single-shop tables become admin-only (their policies call these)
create or replace function public.pos_role() returns text language sql stable as
$$ select case when public.pos_is_admin() then 'manager' end $$;
create or replace function public.pos_is_staff() returns boolean language sql stable as
$$ select public.pos_is_admin() $$;
create or replace function public.pos_is_manager() returns boolean language sql stable as
$$ select public.pos_is_admin() $$;

-- ---------- access rules ----------
create policy pos_data_read on public.pos_data for select to authenticated using (public.pos_can_read(shop_id));
create policy pos_data_insert on public.pos_data for insert to authenticated with check (public.pos_can_write(shop_id, col));
create policy pos_data_write on public.pos_data for all to authenticated using (public.pos_can_write(shop_id, col)) with check (public.pos_can_write(shop_id, col));

create policy pos_members_read on public.pos_members for select to authenticated using (
  email = public.pos_email() or public.pos_is_admin() or (shop_id = public.pos_my_shop() and public.pos_my_role() = 'manager'));
create policy pos_members_admin on public.pos_members for all to authenticated using (public.pos_is_admin()) with check (public.pos_is_admin());
create policy pos_members_manager on public.pos_members for all to authenticated
  using (shop_id = public.pos_my_shop() and public.pos_my_role() = 'manager' and role = 'staff' and not public.pos_shop_locked(shop_id))
  with check (shop_id = public.pos_my_shop() and public.pos_my_role() = 'manager' and role = 'staff' and not public.pos_shop_locked(shop_id));

create policy pos_shops_read on public.pos_shops for select to authenticated using (public.pos_can_read(id));
create policy pos_shops_admin on public.pos_shops for all to authenticated using (public.pos_is_admin()) with check (public.pos_is_admin());
create policy pos_admins_admin on public.pos_admins for all to authenticated using (public.pos_is_admin()) with check (public.pos_is_admin());
create policy pos_platform_read on public.pos_platform for select to authenticated using (true);
create policy pos_platform_admin on public.pos_platform for all to authenticated using (public.pos_is_admin()) with check (public.pos_is_admin());
create policy pos_payments_read on public.pos_payments for select to authenticated using (
  public.pos_is_admin() or (shop_id = public.pos_my_shop() and public.pos_my_role() = 'manager'));
create policy pos_payments_admin on public.pos_payments for all to authenticated using (public.pos_is_admin()) with check (public.pos_is_admin());

-- staff limit per shop, one manager per shop
create or replace function public.pos_members_guard() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare lim int; n int;
begin
  new.email := lower(trim(new.email));
  if new.email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'bad_email' using errcode = 'P0001'; end if;
  if new.active and new.role = 'staff' then
    select staff_limit into lim from public.pos_shops where id = new.shop_id;
    select count(*) into n from public.pos_members where shop_id = new.shop_id and role = 'staff' and active and email <> new.email;
    if n >= coalesce(lim, 0) then raise exception 'staff_limit' using errcode = 'P0001'; end if;
  end if;
  if new.active and new.role = 'manager' and exists (select 1 from public.pos_members where shop_id = new.shop_id and role = 'manager' and active and email <> new.email) then
    raise exception 'one_manager' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger pos_members_guard before insert or update on public.pos_members for each row execute function public.pos_members_guard();

-- ---------- document RPCs ----------
create or replace function public.pos_data_update(p_sid uuid, p_col text, p_id text, p_patch jsonb) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare r jsonb;
begin
  update public.pos_data set data = public.pos_jsonb_merge(data, p_patch), updated_at = now()
  where shop_id = p_sid and col = p_col and id = p_id returning data into r;
  if r is null then raise exception 'not_found' using errcode = 'P0002'; end if;
  return r;
end $$;

create or replace function public.pos_data_lease(p_sid uuid, p_col text, p_id text, p_holder text, p_ttl_ms integer) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare ok boolean := false; exp timestamptz := now() + make_interval(secs => greatest(1000, least(coalesce(p_ttl_ms, 30000), 600000)) / 1000.0);
begin
  insert into public.pos_data(shop_id, col, id, data) values (p_sid, p_col, p_id, jsonb_build_object('holder', p_holder, 'until', exp))
  on conflict (shop_id, col, id) do update set data = excluded.data, updated_at = now()
    where public.pos_data.data->>'holder' = p_holder or coalesce((public.pos_data.data->>'until')::timestamptz, 'epoch') < now()
  returning true into ok;
  return jsonb_build_object('acquired', coalesce(ok, false), 'expiresAt', exp);
end $$;

-- ---------- session, billing, admin ----------
create or replace function public.pos_session(p_slug text default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare adm boolean := public.pos_is_admin(); sid uuid; rl text; s record; grace int; bill jsonb;
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
    'shop', case when s.id is null then null else jsonb_build_object('id', s.id, 'slug', s.slug, 'name', s.name, 'status', s.status,
      'price', s.price, 'staffLimit', s.staff_limit, 'expiresAt', s.expires_at, 'graceUntil', s.expires_at + make_interval(days => grace),
      'locked', public.pos_shop_locked(s.id),
      'staffUsed', (select count(*) from public.pos_members where shop_id = s.id and role = 'staff' and active)) end);
end $$;

create or replace function public.pos_pay_submit(p_sid uuid, p_months int, p_slip text, p_note text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare pid uuid; pr numeric;
begin
  if not (public.pos_is_admin() or (p_sid = public.pos_my_shop() and public.pos_my_role() = 'manager')) then
    raise exception 'forbidden' using errcode = '42501'; end if;
  if p_months is null or p_months not between 1 and 24 then raise exception 'bad_months' using errcode = 'P0001'; end if;
  if p_slip is null or p_slip not like p_sid::text || '/%' then raise exception 'bad_slip' using errcode = 'P0001'; end if;
  if (select count(*) from public.pos_payments where shop_id = p_sid and status = 'pending') >= 5 then raise exception 'too_many_pending' using errcode = 'P0001'; end if;
  select price into pr from public.pos_shops where id = p_sid;
  insert into public.pos_payments(shop_id, amount, months, slip, note, created_by)
  values (p_sid, pr * p_months, p_months, p_slip, left(nullif(trim(p_note), ''), 300), public.pos_email()) returning id into pid;
  return pid;
end $$;

create or replace function public.pos_pay_review(p_id uuid, p_approve boolean, p_note text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare p record; newexp timestamptz;
begin
  if not public.pos_is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into p from public.pos_payments where id = p_id for update;
  if p.id is null or p.status <> 'pending' then raise exception 'not_pending' using errcode = 'P0001'; end if;
  if p_approve then
    update public.pos_shops set expires_at = greatest(expires_at, now()) + make_interval(months => p.months) where id = p.shop_id returning expires_at into newexp;
  end if;
  update public.pos_payments set status = case when p_approve then 'approved' else 'rejected' end, reviewed_at = now(),
    reviewed_by = public.pos_email(), admin_note = left(nullif(trim(p_note), ''), 300), period_to = newexp where id = p_id;
  return jsonb_build_object('expiresAt', newexp);
end $$;

create or replace function public.pos_admin_create_shop(p_slug text, p_name text, p_manager text, p_manager_name text,
  p_price numeric, p_staff_limit int, p_days int, p_app_url text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare sid uuid; em text := lower(trim(p_manager));
begin
  if not public.pos_is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if exists (select 1 from public.pos_members where email = em) then raise exception 'email_in_use' using errcode = 'P0001'; end if;
  insert into public.pos_shops(slug, name, price, staff_limit, expires_at)
  values (lower(trim(p_slug)), trim(p_name), coalesce(p_price, 299), coalesce(p_staff_limit, 5), now() + make_interval(days => greatest(coalesce(p_days, 30), 0)))
  returning id into sid;
  insert into public.pos_members(email, shop_id, role, name) values (em, sid, 'manager', nullif(trim(p_manager_name), ''));
  insert into public.pos_data(shop_id, col, id, data) values
    (sid, 'settings', 'shop', jsonb_build_object('name', trim(p_name), 'appOpen', false, 'appTake', true,
       'appUrl', coalesce(nullif(trim(p_app_url), ''), ''), 'zones', jsonb_build_array('ในร้าน'))),
    (sid, 'categories', 'c1', jsonb_build_object('name', 'เครื่องดื่ม', 'sort', 0));
  return sid;
end $$;

create or replace function public.pos_admin_set_manager(p_sid uuid, p_email text, p_name text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare em text := lower(trim(p_email));
begin
  if not public.pos_is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if exists (select 1 from public.pos_members where email = em and shop_id <> p_sid) then raise exception 'email_in_use' using errcode = 'P0001'; end if;
  update public.pos_members set active = false where shop_id = p_sid and role = 'manager' and email <> em;
  insert into public.pos_members(email, shop_id, role, name) values (em, p_sid, 'manager', nullif(trim(p_name), ''))
  on conflict (email) do update set role = 'manager', active = true, name = coalesce(excluded.name, public.pos_members.name);
end $$;

create or replace function public.pos_admin_shops() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.pos_is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by x->>'created_at') from (
    select jsonb_build_object('id', s.id, 'slug', s.slug, 'name', s.name, 'status', s.status, 'price', s.price,
      'staff_limit', s.staff_limit, 'expires_at', s.expires_at, 'note', s.note, 'created_at', s.created_at,
      'locked', public.pos_shop_locked(s.id),
      'manager', (select jsonb_build_object('email', email, 'name', name) from public.pos_members where shop_id = s.id and role = 'manager' and active limit 1),
      'staff_used', (select count(*) from public.pos_members where shop_id = s.id and role = 'staff' and active),
      'pending', (select count(*) from public.pos_payments where shop_id = s.id and status = 'pending'),
      'last_activity', (select max(updated_at) from public.pos_data where shop_id = s.id and col = 'orders'),
      'orders_30d', (select count(*) from public.pos_data where shop_id = s.id and col = 'orders' and updated_at > now() - interval '30 days')) x
    from public.pos_shops s) t), '[]'::jsonb);
end $$;

-- ---------- customer ordering per shop ----------
create or replace function public.cafe_shop_id(p_slug text) returns uuid language sql stable security definer set search_path = public, pg_temp as
$$ select case when nullif(trim(coalesce(p_slug, '')), '') is null then (select id from public.pos_shops order by created_at limit 1)
          else (select id from public.pos_shops where slug = lower(trim(p_slug))) end $$;

create or replace function public.cafe_menu(p_shop text) returns jsonb
language plpgsql stable security definer set search_path = cafe, public, pg_temp as $$
declare sid uuid := public.cafe_shop_id(p_shop); sh jsonb;
begin
  if sid is null then return jsonb_build_object('error', 'no_shop'); end if;
  sh := coalesce((select data from cafe.shop_state where shop_id = sid and key = 'shop'), '{}'::jsonb);
  if public.pos_shop_locked(sid) then sh := sh || jsonb_build_object('open', false); end if;
  return jsonb_build_object('slug', (select slug from public.pos_shops where id = sid),
    'menu', coalesce((select data from cafe.shop_state where shop_id = sid and key = 'menu'), '{}'::jsonb), 'shop', sh);
end $$;

-- older customer pages (no shop in the link) keep working against the first shop
create or replace function public.cafe_get_menu() returns jsonb language sql stable security definer set search_path = public, pg_temp as
$$ select public.cafe_menu(null) $$;

create or replace function public.cafe_order(p_shop text, p_table text, p_type text, p_items jsonb, p_name text default null,
  p_phone text default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = cafe, pg_temp as $function$
declare
  sid uuid := public.cafe_shop_id(p_shop);
  snap jsonb; shop jsonb; it jsonb; m jsonb; grp jsonb; ch jsonb; sel jsonb;
  qty int; unit numeric; total numeric := 0; out_items jsonb := '[]'::jsonb;
  names text[]; tname text; nsel int; nvalid int; recent int; o record;
begin
  if sid is null or public.pos_shop_locked(sid) then raise exception 'closed' using errcode = 'P0001'; end if;
  select data into shop from cafe.shop_state where shop_id = sid and key = 'shop';
  if shop is null or coalesce((shop->>'open')::boolean, false) is not true then raise exception 'closed' using errcode = 'P0001'; end if;
  select data into snap from cafe.shop_state where shop_id = sid and key = 'menu';
  if snap is null or jsonb_typeof(snap->'menu') <> 'array' then raise exception 'no_menu' using errcode = 'P0001'; end if;
  if p_type not in ('dine','take') then raise exception 'bad_type' using errcode = 'P0001'; end if;
  if p_type = 'take' and coalesce((shop->>'takeaway')::boolean, true) is not true then raise exception 'bad_type' using errcode = 'P0001'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 30 then raise exception 'bad_items' using errcode = 'P0001'; end if;
  if p_type = 'dine' then
    select t->>'name' into tname from jsonb_array_elements(coalesce(snap->'tables', '[]'::jsonb)) t where t->>'id' = p_table;
    if tname is null then raise exception 'bad_table' using errcode = 'P0001'; end if;
  end if;
  select count(*) into recent from cafe.orders where shop_id = sid and status = 'new' and created_at > now() - interval '10 minutes';
  if recent > 100 then raise exception 'busy' using errcode = 'P0001'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    m := null;
    select x into m from jsonb_array_elements(snap->'menu') x where x->>'id' = it->>'id';
    if m is null or coalesce((m->>'soldOut')::boolean, false) then raise exception 'item_unavailable' using errcode = 'P0001'; end if;
    qty := coalesce((it->>'qty')::int, 0);
    if qty < 1 or qty > 20 then raise exception 'bad_qty' using errcode = 'P0001'; end if;
    unit := (m->>'price')::numeric;
    names := array[]::text[];
    sel := coalesce(it->'choices', '[]'::jsonb);
    if jsonb_typeof(sel) <> 'array' then raise exception 'bad_choice' using errcode = 'P0001'; end if;
    nvalid := 0;
    for grp in select g from jsonb_array_elements(coalesce(snap->'options', '[]'::jsonb)) g
               where coalesce(m->'optionIds', '[]'::jsonb) ? (g->>'id') loop
      nsel := 0;
      for ch in select c from jsonb_array_elements(coalesce(grp->'choices', '[]'::jsonb)) c where sel ? (c->>'id') loop
        if coalesce((ch->>'soldOut')::boolean, false) then raise exception 'choice_unavailable' using errcode = 'P0001'; end if;
        nsel := nsel + 1;
        unit := unit + coalesce((ch->>'price')::numeric, 0);
        names := names || (ch->>'name');
      end loop;
      if coalesce((grp->>'required')::boolean, false) and nsel = 0 then raise exception 'choice_required' using errcode = 'P0001'; end if;
      if nsel > coalesce((grp->>'max')::int, 1) then raise exception 'too_many_choices' using errcode = 'P0001'; end if;
      nvalid := nvalid + nsel;
    end loop;
    if nvalid <> jsonb_array_length(sel) then raise exception 'bad_choice' using errcode = 'P0001'; end if;
    if nullif(trim(it->>'note'), '') is not null then names := names || left(trim(it->>'note'), 60); end if;
    total := total + unit * qty;
    out_items := out_items || jsonb_build_array(jsonb_build_object(
      'id', m->>'id', 'name', m->>'name', 'qty', qty, 'unit', unit, 'choices', sel, 'opts', array_to_string(names, ' · ')));
  end loop;
  insert into cafe.orders (shop_id, table_id, table_name, type, items, note, customer_name, phone, total)
  values (sid, case when p_type = 'dine' then p_table end, tname, p_type, out_items,
          left(nullif(trim(p_note), ''), 200), left(nullif(trim(p_name), ''), 60),
          nullif(left(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 12), ''), total)
  returning id, token into o;
  return jsonb_build_object('token', o.token, 'total', total);
end $function$;

create or replace function public.cafe_place_order(p_table text, p_type text, p_items jsonb, p_name text default null,
  p_phone text default null, p_note text default null) returns jsonb
language sql security definer set search_path = public, pg_temp as
$$ select public.cafe_order(null, p_table, p_type, p_items, p_name, p_phone, p_note) $$;

create or replace function public.pos_shop_sync(p_sid uuid, p_menu jsonb, p_shopdata jsonb, p_status jsonb) returns jsonb
language plpgsql security definer set search_path = cafe, public, pg_temp as $$
declare r jsonb;
begin
  if not (public.pos_is_admin() or (p_sid = public.pos_my_shop() and not public.pos_shop_locked(p_sid))) then
    raise exception 'forbidden' using errcode = '42501'; end if;
  if p_menu is not null then
    insert into cafe.shop_state(shop_id, key, data, updated_at) values (p_sid, 'menu', p_menu, now())
    on conflict (shop_id, key) do update set data = excluded.data, updated_at = now();
  end if;
  if p_shopdata is not null then
    insert into cafe.shop_state(shop_id, key, data, updated_at) values (p_sid, 'shop', p_shopdata, now())
    on conflict (shop_id, key) do update set data = excluded.data, updated_at = now();
  end if;
  if p_status is not null and jsonb_typeof(p_status) = 'array' then
    update cafe.orders c set status = case when c.status in ('cancelled','rejected') then c.status else v.s end,
      paid = coalesce(v.p, c.paid), updated_at = now()
    from (select (e->>0)::uuid as id, e->>1 as s, case when jsonb_typeof(e->2) = 'boolean' then (e->>2)::boolean end as p
          from jsonb_array_elements(p_status) e
          where e->>1 in ('accepted','making','ready','done','cancelled')) v
    where c.id = v.id and c.shop_id = p_sid and (c.status <> v.s or c.paid is distinct from coalesce(v.p, c.paid));
  end if;
  select coalesce(jsonb_agg(to_jsonb(o) order by o.created_at), '[]'::jsonb) into r from (
    select id, created_at, table_id, table_name, type, items, note, customer_name, phone, total
    from cafe.orders where shop_id = p_sid and status = 'new' order by created_at limit 20) o;
  return r;
end $$;

create or replace function public.pos_shop_accept(p_sid uuid, p_list jsonb) returns void
language plpgsql security definer set search_path = cafe, public, pg_temp as $$
begin
  if not (public.pos_is_admin() or p_sid = public.pos_my_shop()) then raise exception 'forbidden' using errcode = '42501'; end if;
  update cafe.orders c set status = 'accepted', pos_id = v.pid, pos_no = v.pno, updated_at = now()
  from (select (e->>'id')::uuid as id, e->>'pos_id' as pid, e->>'pos_no' as pno from jsonb_array_elements(p_list) e) v
  where c.id = v.id and c.shop_id = p_sid and c.status = 'new';
end $$;

-- old single-shop bridge calls are retired
create or replace function public.pos_app_sync(p_menu jsonb, p_shop jsonb, p_status jsonb) returns jsonb language plpgsql as
$$ begin raise exception 'upgrade_required' using errcode = 'P0001'; end $$;
create or replace function public.pos_app_accept(p_list jsonb) returns void language plpgsql as
$$ begin raise exception 'upgrade_required' using errcode = 'P0001'; end $$;

-- ---------- storage ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('pos-slips', 'pos-slips', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
create policy pos_slips_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'pos-slips' and (public.pos_is_admin() or ((storage.foldername(name))[1] = public.pos_my_shop()::text and public.pos_my_role() = 'manager')));
create policy pos_slips_read on storage.objects for select to authenticated using (
  bucket_id = 'pos-slips' and (public.pos_is_admin() or ((storage.foldername(name))[1] = public.pos_my_shop()::text and public.pos_my_role() = 'manager')));
create policy pos_media_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'pos-menu' and (public.pos_is_admin() or public.pos_my_role() = 'manager'));
create policy pos_media_remove on storage.objects for all to authenticated using (
  bucket_id = 'pos-menu' and (public.pos_is_admin() or public.pos_my_role() = 'manager'))
  with check (bucket_id = 'pos-menu' and (public.pos_is_admin() or public.pos_my_role() = 'manager'));

-- ---------- realtime ----------
alter publication supabase_realtime add table public.pos_data;
