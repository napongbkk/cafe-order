-- The landing page (signed-out visitors) reads the LINE contact settings; only that row is public.
create policy pos_platform_contact_anon on public.pos_platform for select to anon using (key = 'contact');
