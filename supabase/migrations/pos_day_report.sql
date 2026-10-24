-- Daily sales e-mail: summary function (service role only) + hourly pg_cron call to the pos-report edge function.
-- pos_day_report(shop, from_ms, to_ms): bills, total, voids, totals by payment method, top 10 items (Cafe orders / Retail sales).
-- See the applied definition in the database; the cron job posts to /functions/v1/pos-report with header x-cron-key
-- read at run time from pos_secrets.REPORT_CRON_KEY (generated on first run).
create extension if not exists pg_cron;
insert into public.pos_secrets(key, value)
select 'REPORT_CRON_KEY', encode(extensions.gen_random_bytes(24), 'hex')
where not exists (select 1 from public.pos_secrets where key = 'REPORT_CRON_KEY');
select cron.schedule('pos-report-hourly', '0 * * * *', $cron$
  select net.http_post(
    url := 'https://roggqmvmgfxsxynulpvk.supabase.co/functions/v1/pos-report',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-key', (select value from public.pos_secrets where key = 'REPORT_CRON_KEY')),
    body := '{}'::jsonb)
$cron$);
