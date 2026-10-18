-- Sign-in pages (signed-out visitors) show the platform admin's announcement; only that row is public.
create policy pos_platform_announce_anon on public.pos_platform for select to anon using (key = 'announce');
