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
--   invoice_series  SELECT only — prefix / starting number changed via set_invoice_series(); numbers
--                   are consumed only by create_invoice()
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
-- 0. Invoice numbering fixes
--  a) create_invoice(): V2 ran INSERT ... ON CONFLICT DO NOTHING on every call.
--     BEFORE INSERT triggers fire before conflict detection, so guard_invoice_series
--     saw next_number = 1 <= max(seq) and aborted EVERY second invoice in a series.
--     Now the series row is inserted only when missing; numbering itself is unchanged
--     (row-locked UPDATE ... RETURNING, numbers reserved only after validation).
--  b) Users can no longer write invoice_series directly. set_invoice_series() lets
--     them set the prefix and move the next number FORWARD only (never below the
--     current next number or any used number).
-- ---------------------------------------------------------------------
create or replace function public.create_invoice(p_client_id uuid, p_from date, p_to date, p_invoice_date date default current_date)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_client public.clients;
  v_state text;
  v_kind public.invoice_kind;
  v_fy text;
  v_seq int;
  v_prefix text;
  v_count int;
  v_sub numeric(14,2);
  v_cgst numeric(14,2) := 0;
  v_igst numeric(14,2) := 0;
  v_id uuid;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not public.has_access() then raise exception 'Your trial or plan has expired. Renew to create invoices.'; end if;
  if p_from is null or p_to is null or p_from > p_to then raise exception 'Invalid billing period'; end if;
  if p_invoice_date is null then raise exception 'Invoice date required'; end if;

  select * into v_client from public.clients where id = p_client_id and owner_id = v_uid;
  if not found then raise exception 'Client not found'; end if;
  select state into v_state from public.profiles where id = v_uid;

  perform 1 from public.shipments
   where owner_id = v_uid and client_id = p_client_id and invoice_id is null
     and ship_date between p_from and p_to
   for update;
  select count(*), coalesce(sum(amount), 0) into v_count, v_sub from public.shipments
   where owner_id = v_uid and client_id = p_client_id and invoice_id is null
     and ship_date between p_from and p_to;
  if v_count = 0 then raise exception 'No unbilled shipments for this client in the selected period'; end if;

  v_kind := case when v_client.is_gst then 'gst'::public.invoice_kind else 'nongst'::public.invoice_kind end;
  v_fy := public.fy_label(p_invoice_date);

  if v_kind = 'gst' then
    if public.gst_state_code(v_state) is null then
      raise exception 'Set a valid business state in Settings before issuing GST invoices';
    end if;
    if public.gst_state_code(v_client.state) is null then
      raise exception 'Set a valid state for client % before issuing a GST invoice', v_client.name;
    end if;
    if public.gst_state_code(v_state) = public.gst_state_code(v_client.state) then
      v_cgst := round(v_sub * 0.09, 2);
    else
      v_igst := round(v_sub * 0.18, 2);
    end if;
  end if;

  -- series row created only when missing (avoids the guard-trigger conflict)
  if not exists (select 1 from public.invoice_series where owner_id = v_uid and fy = v_fy and kind = v_kind) then
    insert into public.invoice_series (owner_id, fy, kind, prefix, next_number)
    values (v_uid, v_fy, v_kind, case when v_kind = 'gst' then 'GST' else 'BOS' end, 1)
    on conflict (owner_id, fy, kind) do nothing;
  end if;
  update public.invoice_series set next_number = next_number + 1
   where owner_id = v_uid and fy = v_fy and kind = v_kind
   returning next_number - 1, prefix into v_seq, v_prefix;          -- row lock serialises numbering
  if v_seq is null then raise exception 'Invoice series unavailable'; end if;

  insert into public.invoices (owner_id, client_id, kind, fy, seq, invoice_no, invoice_date,
                               period_from, period_to, subtotal, cgst, sgst, igst, total)
  values (v_uid, p_client_id, v_kind, v_fy, v_seq,
          v_prefix || '/' || v_fy || '/' || lpad(v_seq::text, 4, '0'),
          p_invoice_date, p_from, p_to, v_sub, v_cgst, v_cgst, v_igst, v_sub + v_cgst * 2 + v_igst)
  returning id into v_id;

  update public.shipments set invoice_id = v_id
   where owner_id = v_uid and client_id = p_client_id and invoice_id is null
     and ship_date between p_from and p_to;
  return v_id;
end $$;

create or replace function public.set_invoice_series(p_fy text, p_kind public.invoice_kind, p_prefix text, p_next_number int)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_cur int; v_max int;
begin
  if v_uid is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  if not public.has_access() then raise exception 'Your trial or plan has expired' using errcode = '42501'; end if;
  if p_fy is null or p_fy !~ '^[0-9]{4}-[0-9]{2}$' or p_kind is null then raise exception 'Invalid series' using errcode = 'P0001'; end if;
  if p_prefix is null or p_prefix !~ '^[A-Za-z0-9/_-]{1,20}$' then raise exception 'Prefix: 1–20 letters, digits, / _ -' using errcode = 'P0001'; end if;
  if p_next_number is null or p_next_number < 1 or p_next_number > 99999999 then raise exception 'Invalid next number' using errcode = 'P0001'; end if;

  select next_number into v_cur from public.invoice_series
   where owner_id = v_uid and fy = p_fy and kind = p_kind for update;
  select coalesce(max(seq), 0) into v_max from public.invoices
   where owner_id = v_uid and fy = p_fy and kind = p_kind;
  if v_cur is not null and p_next_number < v_cur then
    raise exception 'Next number cannot go backwards (currently %)', v_cur using errcode = 'P0001'; end if;
  if p_next_number <= v_max then
    raise exception 'Next number must be greater than % (already used)', v_max using errcode = 'P0001'; end if;

  if v_cur is null then
    insert into public.invoice_series (owner_id, fy, kind, prefix, next_number)
    values (v_uid, p_fy, p_kind, p_prefix, p_next_number);
  else
    update public.invoice_series set prefix = p_prefix, next_number = p_next_number
     where owner_id = v_uid and fy = p_fy and kind = p_kind;
  end if;
end $$;

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

grant select on public.invoice_series to authenticated;   -- writes only via set_invoice_series / create_invoice

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
alter function public.set_invoice_series(text, public.invoice_kind, text, int) set search_path = '';

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
grant execute on function public.set_invoice_series(text, public.invoice_kind, text, int) to authenticated;
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
