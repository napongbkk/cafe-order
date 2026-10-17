-- Easy POS Retail: shops have a product type (cafe | retail).
-- Adds pos_shops.product, lets the admin create Retail shops, and returns the type in the admin list and the session.
-- Applied without dropping the old 8-argument pos_admin_create_shop: the 9-argument version has no default on p_product,
-- so cafe calls (8 args) keep using the old one and retail calls (with p_product) use this one.

alter table public.pos_shops add column if not exists product text not null default 'cafe';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'pos_shops_product_chk') then
    alter table public.pos_shops add constraint pos_shops_product_chk check (product in ('cafe','retail'));
  end if;
end $$;
-- pos_admin_create_shop(…, p_product text), pos_admin_shops() and pos_session() as applied in the database (see git history for the bodies).
