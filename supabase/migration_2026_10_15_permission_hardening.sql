-- =====================================================================
-- EntrySetu V2 migration 3 of 3: permission hardening (all tables + functions)
-- FOR MANUAL REVIEW ONLY. Run AFTER entrysetu_schema.sql,
-- migration_2026_10_15_import_weights.sql and migration_2026_10_15_rate_cards_zones.sql.
-- Idempotent. Changes privileges only — no data, RLS policy or function body changes.
--
-- Why: Supabase's default privileges give anon and authenticated table-wide
-- ALL on every new table in "public". V2 added narrower column grants but never
-- revoked those defaults, so column restrictions could be bypassed (RLS still
-- applied). This file revokes everything from PUBLIC/anon/authenticated and
-- re-grants the minimum the app uses. service_role keeps full access, so the
-- Razorpay webhook, payment activation and admin RPCs are unaffected.
--
-- Final privilege matrix for role "authenticated" (anon gets nothing):
--   profiles        SELECT | UPDATE(business_name, phone, gstin, address, state)
--   user_roles      SELECT
--   clients         SELECT, DELETE | INSERT/UPDATE(name, phone, email, gstin, address, state, is_gst, active)
--   rate_cards      SELECT, DELETE | INSERT/UPDATE(client_id, service, min_weight, max_weight, rate, extra_per_kg)
--   invoice_series  SELECT | INSERT(fy, kind, prefix, next_number) | UPDATE(prefix, next_number)   (no DELETE)
--   invoices        SELECT                       (issued/cancelled only via RPCs)
--   shipments       SELECT, DELETE | INSERT/UPDATE(client_id, awb, ship_date, destination, service, weight,
--                   pieces, amount, shipment_type, weight_f, weight_g, weight_h, weight_t)
--   payments        SELECT
--   webhook_events  none
--   import_mappings SELECT, DELETE | INSERT/UPDATE(name, mapping, updated_at)
--   zones           SELECT, DELETE | INSERT/UPDATE(name, destinations, sort_order)
--   rate_slabs      SELECT                       (written only via save_rate_card / copy_rate_cards)
-- Never writable by users: id, owner_id, created_at, plan fields, trial dates,
-- invoice_id, billing_weight, weight_unit, rate_zone, rate_slab, rate_applied.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Start from zero on every app table
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['profiles','user_roles','clients','rate_cards','invoice_series','invoices',
                           'shipments','payments','webhook_events','import_mappings','zones','rate_slabs'] loop
    execute format('revoke all on table public.%I from public, anon, authenticated', t);
    execute format('grant all on table public.%I to service_role', t);
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 2. Minimum grants for signed-in users (RLS still decides which rows)
-- ---------------------------------------------------------------------
grant select on public.profiles to authenticated;
grant update (business_name, phone, gstin, address, state) on public.profiles to authenticated;

grant select on public.user_roles to authenticated;

grant select, delete on public.clients to authenticated;
grant insert (name, phone, email, gstin, address, state, is_gst, active) on public.clients to authenticated;
grant update (name, phone, email, gstin, address, state, is_gst, active) on public.clients to authenticated;

grant select, delete on public.rate_cards to authenticated;
grant insert (client_id, service, min_weight, max_weight, rate, extra_per_kg) on public.rate_cards to authenticated;
grant update (client_id, service, min_weight, max_weight, rate, extra_per_kg) on public.rate_cards to authenticated;

grant select on public.invoice_series to authenticated;
grant insert (fy, kind, prefix, next_number) on public.invoice_series to authenticated;
grant update (prefix, next_number) on public.invoice_series to authenticated;

grant select on public.invoices to authenticated;

grant select, delete on public.shipments to authenticated;
grant insert (client_id, awb, ship_date, destination, service, weight, pieces, amount,
              shipment_type, weight_f, weight_g, weight_h, weight_t) on public.shipments to authenticated;
grant update (client_id, awb, ship_date, destination, service, weight, pieces, amount,
              shipment_type, weight_f, weight_g, weight_h, weight_t) on public.shipments to authenticated;

grant select on public.payments to authenticated;

grant select, delete on public.import_mappings to authenticated;
grant insert (name, mapping, updated_at) on public.import_mappings to authenticated;
grant update (name, mapping, updated_at) on public.import_mappings to authenticated;

grant select, delete on public.zones to authenticated;
grant insert (name, destinations, sort_order) on public.zones to authenticated;
grant update (name, destinations, sort_order) on public.zones to authenticated;

grant select on public.rate_slabs to authenticated;

-- ---------------------------------------------------------------------
-- 3. Functions: pin search_path, then minimum EXECUTE
-- ---------------------------------------------------------------------
alter function public.gst_state_code(text)                      set search_path = '';
alter function public.fy_label(date)                            set search_path = '';
alter function public.is_admin()                                set search_path = '';
alter function public.has_access()                              set search_path = '';
alter function public.handle_new_user()                         set search_path = '';
alter function public.enforce_client_limit()                    set search_path = '';
alter function public.guard_invoice_series()                    set search_path = '';
alter function public.protect_billed_shipment()                 set search_path = '';
alter function public.create_invoice(uuid, date, date, date)    set search_path = '';
alter function public.cancel_invoice(uuid, text)                set search_path = '';
alter function public.activate_payment(text, text, bigint)      set search_path = '';
alter function public.record_webhook_event(text, text)          set search_path = '';
alter function public.admin_set_access(uuid, text, public.plan_kind) set search_path = '';
alter function public.shipments_sync_weight()                   set search_path = '';
alter function public.zones_normalise()                         set search_path = '';
alter function public.save_rate_card(uuid, text, text, jsonb)   set search_path = '';
alter function public.copy_rate_cards(uuid, uuid, boolean)      set search_path = '';
alter function public.shipment_rate(uuid, uuid, text, text, text, numeric) set search_path = '';
alter function public.shipments_apply_rate()                    set search_path = '';

-- Start every app function from zero
do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_catalog.pg_proc p
            join pg_catalog.pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

-- Called by signed-in users (directly or inside RLS policies / CHECK constraints)
grant execute on function public.gst_state_code(text)                    to authenticated;
grant execute on function public.fy_label(date)                          to authenticated;
grant execute on function public.is_admin()                              to authenticated;
grant execute on function public.has_access()                            to authenticated;
grant execute on function public.create_invoice(uuid, date, date, date)  to authenticated;
grant execute on function public.cancel_invoice(uuid, text)              to authenticated;
grant execute on function public.save_rate_card(uuid, text, text, jsonb) to authenticated;
grant execute on function public.copy_rate_cards(uuid, uuid, boolean)    to authenticated;
-- Trigger functions run as the trigger's table owner context; they need no user EXECUTE.
-- service_role only: activate_payment, record_webhook_event, admin_set_access, shipment_rate.

-- ---------------------------------------------------------------------
-- 4. Future objects created by this role get no automatic access
-- ---------------------------------------------------------------------
alter default privileges in schema public revoke all on tables    from public, anon, authenticated;
alter default privileges in schema public revoke all on sequences from public, anon, authenticated;
alter default privileges in schema public revoke all on functions from public, anon, authenticated;
alter default privileges in schema public grant  all on tables    to service_role;
alter default privileges in schema public grant  all on sequences to service_role;
alter default privileges in schema public grant  execute on functions to service_role;

commit;

-- Read-only checks after running:
--   select table_name, grantee, privilege_type from information_schema.role_table_grants
--    where table_schema = 'public' and grantee in ('anon','authenticated','PUBLIC') order by 1,2,3;
--   select table_name, column_name, privilege_type from information_schema.column_privileges
--    where table_schema = 'public' and grantee = 'authenticated' and privilege_type in ('INSERT','UPDATE') order by 1,3,2;
