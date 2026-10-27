-- GrokBooks 0016: daily schedule for generate_recurring_invoices() via pg_cron.
-- Harmless while every template has auto_generate = false (the function then does nothing).
create extension if not exists pg_cron;
select cron.schedule('generate-recurring-invoices', '0 11 * * *',   -- 11:00 UTC daily (5-6 AM America/Chicago)
                     $$select public.generate_recurring_invoices()$$);
