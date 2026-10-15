-- EntrySetu V1: store receiver name + receiver number on shipments (DEV review only — do not run on production).
-- Additive and re-runnable. Existing rows keep NULL (no backfill, nothing fabricated or overwritten).
alter table public.shipments add column if not exists receiver_name  text check (char_length(receiver_name)  <= 160);
alter table public.shipments add column if not exists receiver_phone text check (char_length(receiver_phone) <= 40);
-- Column-scoped writes, matching the existing shipments grants (RLS policies unchanged).
grant insert (receiver_name, receiver_phone) on public.shipments to authenticated;
grant update (receiver_name, receiver_phone) on public.shipments to authenticated;
notify pgrst, 'reload schema';
