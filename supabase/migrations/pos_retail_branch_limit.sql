-- Retail: the admin limits how many shops/warehouses a Retail account may have.
-- pos_shops.branch_limit (default 1); trigger pos_data_branch_guard blocks inserting a new 'branches' row past the limit;
-- pos_session returns shop.branchLimit/branchUsed; pos_admin_shops returns branch_limit/branches_used;
-- packages[].branches sets the limit when an application is approved (pos_admin_approve_app).
alter table public.pos_shops add column if not exists branch_limit int not null default 1;
