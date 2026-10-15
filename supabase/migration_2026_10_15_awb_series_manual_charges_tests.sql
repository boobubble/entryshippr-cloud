-- =====================================================================
-- EntrySetu V1 — AWB series + Manual charges tests. DEVELOPMENT ONLY (zfvnqcyqxxipjaugkmvf).
-- Run AFTER migration_2026_10_15_awb_series_manual_charges.sql. One transaction,
-- ROLLED BACK at the end: no test data kept, no real invoice numbers used.
-- Last notice: "ALL AWB SERIES AND MANUAL CHARGE TESTS PASSED".
-- =====================================================================
begin;
create schema tam;
grant usage on schema tam to authenticated, service_role;
-- Every passing assertion is recorded; the final block requires the exact expected count,
-- so the PASS message can only appear when every assertion ran and succeeded.
create table tam.log (n serial, label text);
grant insert, select on tam.log to authenticated, service_role;
grant usage on sequence tam.log_n_seq to authenticated, service_role;
create function tam.expect_fail(q text, label text, codes text[], msg_like text default null)
returns void language plpgsql as $$
declare v_state text; v_msg text;
begin
  begin execute q;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    if not (v_state = any(codes)) then raise exception 'FAIL: % — wrong error % (%), expected %', label, v_state, v_msg, codes; end if;
    if msg_like is not null and v_msg not ilike msg_like then raise exception 'FAIL: % — message "%" not like "%"', label, v_msg, msg_like; end if;
    insert into tam.log (label) values (label);
    raise notice 'PASS (blocked %) %', v_state, label; return;
  end;
  raise exception 'FAIL: % was allowed', label;
end $$;
create function tam.ok(cond boolean, label text) returns void language plpgsql as $$
begin if cond is true then insert into tam.log (label) values (label); raise notice 'PASS %', label; else raise exception 'FAIL: % (got %)', label, cond; end if; end $$;
create function tam.as_user(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
end $$;
create function tam.no_user() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
grant execute on all functions in schema tam to authenticated, service_role;

create table tam.ship_before as select * from public.shipments;
create table tam.inv_before as select * from public.invoices;

-- A. Structure and privileges
do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'shipments' and column_name = 'charge_mode') then
    raise exception 'FAIL: charge_mode missing'; end if;
  if exists (select 1 from public.shipments where charge_mode <> 'auto' or manual_amount is not null) and not exists (select 1 from tam.ship_before where charge_mode = 'manual') then
    raise exception 'FAIL: existing shipments not Auto'; end if;
  if has_table_privilege('authenticated', 'public.shipment_charge_audit', 'INSERT')
     or has_table_privilege('authenticated', 'public.shipment_charge_audit', 'UPDATE')
     or has_table_privilege('authenticated', 'public.shipment_charge_audit', 'DELETE')
     or has_table_privilege('service_role', 'public.shipment_charge_audit', 'INSERT')
     or has_table_privilege('service_role', 'public.shipment_charge_audit', 'DELETE') then raise exception 'FAIL: audit writable'; end if;
  if has_table_privilege('anon', 'public.awb_series', 'SELECT') or has_function_privilege('anon', 'public.next_awb(uuid)', 'EXECUTE') then
    raise exception 'FAIL: anon access'; end if;
  if has_column_privilege('authenticated', 'public.awb_series', 'owner_id', 'INSERT') then raise exception 'FAIL: owner_id settable'; end if;
  if has_function_privilege('authenticated', 'entrysetu_private.can_manual_charge(uuid)', 'EXECUTE') then raise exception 'FAIL: permission helper exposed'; end if;
  raise notice 'PASS structure and privileges';
end $$;

-- B. Two sellers
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
 ('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-00000000a5a1','authenticated','authenticated','tam-a@test.local','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-00000000a5b1','authenticated','authenticated','tam-b@test.local','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
update public.profiles set state = 'Maharashtra' where id in ('00000000-0000-0000-0000-00000000a5a1', '00000000-0000-0000-0000-00000000a5b1');

set local role authenticated;
select tam.as_user('00000000-0000-0000-0000-00000000a5a1');
insert into public.clients (name, state, is_gst) values ('TAM ONE', 'Maharashtra', false), ('TAM TWO', 'Maharashtra', false);
select tam.as_user('00000000-0000-0000-0000-00000000a5b1');
insert into public.clients (name, state, is_gst) values ('TAM B', 'Maharashtra', false);
reset role;
create table tam.c as select
  (select id from public.clients where name = 'TAM ONE') c1, (select id from public.clients where name = 'TAM TWO') c2,
  (select id from public.clients where name = 'TAM B') cb;
grant select on all tables in schema tam to authenticated, service_role;

-- C. AWB series
set local role authenticated;
select tam.as_user('00000000-0000-0000-0000-00000000a5a1');
select tam.ok((select count(*) = 0 from public.next_awb((select c1 from tam.c))), 'no series -> no suggestion');
insert into public.awb_series (prefix, start_number, digits) values ('bos', 101, 6);
select tam.ok((select prefix = 'BOS' from public.awb_series where client_id is null), 'prefix stored uppercase');
select tam.ok((select awb = 'BOS000101' and scope = 'default' from public.next_awb((select c1 from tam.c))), 'starts at start number with leading zeros');
insert into public.shipments (client_id, awb, destination, weight, amount) select c1, 'BOS000101', 'MUMBAI', 1, 50 from tam.c;
insert into public.shipments (client_id, awb, destination, weight, amount) select c1, 'BOS000105', 'MUMBAI', 1, 50 from tam.c;
select tam.ok((select awb = 'BOS000106' from public.next_awb((select c1 from tam.c))), 'after highest, gaps never reused');
insert into public.shipments (client_id, awb, destination, weight, amount) select c1, 'BOS12', 'MUMBAI', 1, 50 from tam.c;
insert into public.shipments (client_id, awb, destination, weight, amount) select c1, 'XBOS000900', 'MUMBAI', 1, 50 from tam.c;
select tam.ok((select awb = 'BOS000106' from public.next_awb((select c1 from tam.c))), 'other formats ignored');
select tam.ok((select awb = 'BOS000106' from public.next_awb(null)), 'default series without client');
insert into public.awb_series (client_id, prefix, start_number, digits) select c2, '', 7, 4 from tam.c;
select tam.ok((select awb = '0007' and scope = 'client' from public.next_awb((select c2 from tam.c))), 'client series preferred, numeric only');
select tam.ok((select awb = 'BOS000106' from public.next_awb((select c1 from tam.c))), 'other client keeps default series');
-- manual override + duplicate protection. NOTE: this is a SEQUENTIAL check inside one session.
-- Real two-session concurrency is tested separately by scripts/awb_concurrency_check.sh.
insert into public.shipments (client_id, awb, destination, weight, amount) select c2, 'MY-OWN-1', 'MUMBAI', 1, 50 from tam.c;
select tam.expect_fail($q$insert into public.shipments (client_id, awb, destination, weight, amount) select c2, '0007', 'MUMBAI', 1, 50 from tam.c; insert into public.shipments (client_id, awb, destination, weight, amount) select c1, '0007', 'MUMBAI', 1, 50 from tam.c$q$,
  'same AWB saved twice (sequential, same session)', array['23505']);
select tam.ok((select awb = '0007' from public.next_awb((select c2 from tam.c))), 'failed save consumed no number');
insert into public.shipments (client_id, awb, destination, weight, amount) select c2, '0007', 'MUMBAI', 1, 50 from tam.c;
select tam.ok((select awb = '0008' from public.next_awb((select c2 from tam.c))), 'suggestion moves only after a successful save');
insert into public.shipments (client_id, awb, destination, weight, amount) select c2, '0009', 'MUMBAI', 1, 50 from tam.c;
update public.awb_series set start_number = 8 where client_id = (select c2 from tam.c);
select tam.ok((select awb = '0010' from public.next_awb((select c2 from tam.c))), 'existing AWB never suggested');
select tam.expect_fail($q$insert into public.awb_series (prefix, start_number, digits) values ('X', 1, 3)$q$, 'second default series', array['23505']);
select tam.expect_fail($q$insert into public.awb_series (client_id, prefix, start_number, digits) select c1, 'A B', 1, 3 from tam.c$q$, 'bad prefix', array['23514']);
select tam.expect_fail($q$insert into public.awb_series (client_id, prefix, start_number, digits) select c1, 'A', 1000, 3 from tam.c$q$, 'start wider than digits', array['23514']);
update public.awb_series set start_number = 9998, digits = 4 where client_id = (select c2 from tam.c);
insert into public.shipments (client_id, awb, destination, weight, amount) select c2, '9999', 'MUMBAI', 1, 50 from tam.c;
select tam.expect_fail($q$select * from public.next_awb((select c2 from tam.c))$q$, 'series used up', array['P0001'], '%used up%');
-- prefix with / and -, exact digit count, non-numeric tails, 18-digit leading zeros, inactive client series
update public.awb_series set prefix = 'BOS/26-', start_number = 1, digits = 5 where client_id is null;
insert into public.shipments (client_id, awb, destination, weight, amount) select c1, x, 'MUMBAI', 1, 50 from tam.c,
  unnest(array['BOS/26-00041', 'BOS/26-000999', 'BOS/26-0004X', 'BOS/26-ABCDE', 'BOS/2600050', 'bos/26-00077']) x;
select tam.ok((select awb = 'BOS/26-00042' from public.next_awb((select c1 from tam.c))), 'prefix with / and - matched literally, other lengths/case/tails ignored');
update public.awb_series set prefix = 'L', start_number = 0, digits = 18 where client_id is null;
select tam.ok((select awb = 'L000000000000000000' from public.next_awb(null)), '18 digits keep every leading zero');
insert into public.shipments (client_id, awb, destination, weight, amount) select c1, 'L000000000000000000', 'MUMBAI', 1, 50 from tam.c;
select tam.ok((select awb = 'L000000000000000001' from public.next_awb(null)), '18-digit series increments exactly');
update public.awb_series set active = false where client_id = (select c2 from tam.c);
select tam.ok((select scope = 'default' and awb = 'L000000000000000001' from public.next_awb((select c2 from tam.c))), 'inactive client series falls back to default');
update public.awb_series set active = true where client_id = (select c2 from tam.c);
select tam.expect_fail($q$select * from public.next_awb((select c2 from tam.c))$q$, 'reactivated client series overrides default again (still used up)', array['P0001'], '%used up%');
-- tenant isolation
select tam.expect_fail($q$insert into public.awb_series (client_id, prefix, start_number, digits) select cb, 'Z', 1, 3 from tam.c$q$, 'series on another seller''s client', array['23503', '42501']);
select tam.as_user('00000000-0000-0000-0000-00000000a5b1');
select tam.ok((select count(*) = 0 from public.awb_series), 'seller B cannot see A''s series');
select tam.ok((select count(*) = 0 from public.next_awb(null)), 'seller B gets no suggestion from A''s series');
update public.awb_series set prefix = 'HACK';
delete from public.awb_series;
reset role;
select tam.ok((select count(*) = 2 and bool_and(prefix <> 'HACK') from public.awb_series where owner_id = '00000000-0000-0000-0000-00000000a5a1'), 'seller B cannot change or delete A''s series');

-- D. Manual charges
set local role authenticated;
select tam.as_user('00000000-0000-0000-0000-00000000a5a1');
-- typed shipment with no rate card -> Auto = Needs Review at 0
insert into public.shipments (client_id, awb, destination, service, shipment_type, weight_f, weight, amount)
select c1, 'TAM-M1', 'MUMBAI', 'Standard', 'NON-DOX', 2, 2, 0 from tam.c;
select tam.ok((select charge_mode = 'auto' and pricing_status = 'needs_review' and amount = 0 from public.shipments where awb = 'TAM-M1'), 'Auto is default, unpriced stays Needs Review at 0');
-- typed amount in Auto is still overwritten (unchanged behaviour)
update public.shipments set amount = 999 where awb = 'TAM-M1';
select tam.ok((select amount = 0 from public.shipments where awb = 'TAM-M1'), 'Auto ignores typed amount');
update public.shipments set charge_mode = 'manual', manual_amount = 150.50 where awb = 'TAM-M1';
select tam.ok((select amount = 150.50 and pricing_status = 'priced' and rate_zone is null from public.shipments where awb = 'TAM-M1'), 'Manual saves exact amount');
insert into public.shipments (client_id, awb, destination, service, shipment_type, weight_f, weight, amount, charge_mode, manual_amount)
select c1, 'TAM-M2', 'MUMBAI', 'Fast', 'DOX', 50, 0.05, 0, 'manual', 75 from tam.c;
select tam.ok((select amount = 75 and charge_mode = 'manual' from public.shipments where awb = 'TAM-M2'), 'Manual on insert');
select tam.expect_fail($q$update public.shipments set manual_amount = 0 where awb = 'TAM-M1'$q$, 'manual 0 refused', array['23514']);
select tam.expect_fail($q$update public.shipments set manual_amount = -5 where awb = 'TAM-M1'$q$, 'manual negative refused', array['23514']);
select tam.expect_fail($q$update public.shipments set manual_amount = null where awb = 'TAM-M1'$q$, 'manual without amount refused', array['23514']);
select tam.expect_fail($q$insert into public.shipments (client_id, awb, destination, weight, amount, charge_mode) select c1, 'TAM-M3', 'MUMBAI', 1, 0, 'manual' from tam.c$q$, 'manual insert without amount', array['23514']);
select tam.expect_fail($q$update public.shipments set charge_mode = 'fixed' where awb = 'TAM-M1'$q$, 'unknown mode refused', array['23514']);
-- later edits keep the manual amount
update public.shipments set weight_f = 5, weight = 5, destination = 'PUNE', service = 'Fast', amount = 1 where awb = 'TAM-M1';
select tam.ok((select amount = 150.50 and charge_mode = 'manual' from public.shipments where awb = 'TAM-M1'), 'edits never overwrite Manual amount');
reset role;
select tam.no_user();
set local role service_role;
select public.reprice_review('00000000-0000-0000-0000-00000000a5a1');
update public.shipments set destination = destination where awb = 'TAM-M1';
reset role;
select tam.ok((select amount = 150.50 and charge_mode = 'manual' from public.shipments where awb = 'TAM-M1'), 'repricing never overwrites Manual amount');
-- only the owner may use Manual mode
set local role service_role;
select tam.expect_fail($q$update public.shipments set manual_amount = 1 where awb = 'TAM-M1'$q$, 'service role cannot change manual charge', array['42501']);
select tam.expect_fail($q$update public.shipments set charge_mode = 'auto' where awb = 'TAM-M1'$q$, 'service role cannot switch mode', array['42501']);
select tam.expect_fail($q$insert into public.shipments (owner_id, client_id, awb, destination, weight, amount, charge_mode, manual_amount) select '00000000-0000-0000-0000-00000000a5a1', c1, 'TAM-SR', 'MUMBAI', 1, 0, 'manual', 10 from tam.c$q$, 'service role cannot insert manual', array['42501']);
reset role;
set local role authenticated;
select tam.as_user('00000000-0000-0000-0000-00000000a5b1');
update public.shipments set charge_mode = 'auto' where awb = 'TAM-M1';   -- RLS: matches nothing
reset role;
select tam.ok((select charge_mode = 'manual' from public.shipments where awb = 'TAM-M1'), 'other seller cannot touch Manual charges');
-- switching back to Auto recalculates
set local role authenticated;
select tam.as_user('00000000-0000-0000-0000-00000000a5a1');
update public.shipments set charge_mode = 'auto' where awb = 'TAM-M2';
select tam.ok((select charge_mode = 'auto' and manual_amount is null and pricing_status = 'needs_review' and amount = 0 from public.shipments where awb = 'TAM-M2'), 'back to Auto recalculates');
update public.shipments set charge_mode = 'manual', manual_amount = 80 where awb = 'TAM-M2';

-- E. Locks: draft reservation and invoicing
select tam.ok((select pricing_status = 'priced' from public.shipments where awb = 'TAM-M1'), 'manual shipment is invoiceable');
reset role;
create table tam.ids (k text, id uuid);
grant insert, select on tam.ids to authenticated; set local role authenticated;
select tam.as_user('00000000-0000-0000-0000-00000000a5a1');
insert into tam.ids select 'd1', public.create_invoice_draft((select c1 from tam.c), current_date - 30, current_date,
  array[(select id from public.shipments where awb = 'TAM-M1')]);
select tam.ok((select draft_invoice_id is not null from public.shipments where awb = 'TAM-M1'), 'manual shipment reserved by draft');
select tam.expect_fail($q$update public.shipments set manual_amount = 200 where awb = 'TAM-M1'$q$, 'manual amount locked on draft', array['P0001']);
select tam.expect_fail($q$update public.shipments set charge_mode = 'auto' where awb = 'TAM-M1'$q$, 'mode locked on draft', array['P0001']);
select tam.ok((select amount = 150.50 from public.invoice_lines where invoice_id = (select id from tam.ids where k = 'd1')), 'draft line uses manual amount');
select public.discard_invoice_draft((select id from tam.ids where k = 'd1'));
select tam.ok((select draft_invoice_id is null and amount = 150.50 and charge_mode = 'manual' from public.shipments where awb = 'TAM-M1'), 'discard releases, manual kept');
-- issue a legacy invoice for client c1 (all priced shipments in range)
delete from public.shipments where awb = 'TAM-M2';     -- audit 'delete' row expected
insert into tam.ids select 'i1', public.create_invoice((select c1 from tam.c), current_date - 30, current_date, current_date);
select tam.ok((select invoice_id is not null from public.shipments where awb = 'TAM-M1'), 'manual shipment invoiced');
update public.shipments set manual_amount = 200, charge_mode = 'manual' where awb = 'TAM-M1';   -- RLS: billed rows match nothing
select tam.ok((select amount = 150.50 and manual_amount = 150.50 from public.shipments where awb = 'TAM-M1'), 'manual locked after invoicing (seller)');
reset role;
select tam.no_user();
set local role service_role;
select tam.expect_fail($q$update public.shipments set manual_amount = 200 where awb = 'TAM-M1'$q$, 'manual locked after invoicing (service role)', array['P0001', '42501']);
reset role;
select tam.ok((select total > 0 from public.invoices where id = (select id from tam.ids where k = 'i1')), 'invoice issued');
-- Indirect / trusted-role changes on billed rows (protect_billed_shipment lets service_role through;
-- the charge guard must still refuse any change to amount or pricing fields)
select tam.no_user();
set local role service_role;
select tam.expect_fail($q$update public.shipments set amount = 1 where awb = 'BOS000101'$q$, 'service role cannot change amount of invoiced shipment', array['P0001'], '%locked%');
select tam.expect_fail($q$update public.shipments set pricing_status = 'needs_review' where awb = 'BOS000101'$q$, 'service role cannot change pricing status of invoiced shipment', array['P0001'], '%locked%');
select tam.expect_fail($q$update public.shipments set charge_mode = 'manual', manual_amount = 5 where awb = 'BOS000101'$q$, 'service role cannot switch invoiced shipment to manual', array['P0001']);
reset role;
select tam.expect_fail($q$update public.shipments set amount = 1 where awb = 'BOS000101'$q$, 'table owner cannot change amount of invoiced shipment', array['P0001'], '%locked%');
select tam.expect_fail($q$insert into public.shipments (owner_id, client_id, awb, destination, weight, amount, charge_mode, manual_amount) select '00000000-0000-0000-0000-00000000a5a1', c1, 'TAM-PG', 'MUMBAI', 1, 0, 'manual', 10 from tam.c$q$, 'table owner without a signed-in user cannot insert manual', array['42501']);
-- a session whose user id is the owner but whose request role is service_role is still refused
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-00000000a5a1', 'role', 'service_role')::text, true);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000a5a1', true);
set local role service_role;
select tam.expect_fail($q$insert into public.shipments (owner_id, client_id, awb, destination, weight, amount, charge_mode, manual_amount) select '00000000-0000-0000-0000-00000000a5a1', c1, 'TAM-SR2', 'MUMBAI', 1, 0, 'manual', 10 from tam.c$q$, 'service role carrying the owner id cannot insert manual', array['42501']);
reset role;
select tam.no_user();
-- cross-tenant: seller B cannot create a manual shipment for seller A (owner_id is not writable; RLS)
set local role authenticated;
select tam.as_user('00000000-0000-0000-0000-00000000a5b1');
select tam.expect_fail($q$insert into public.shipments (owner_id, client_id, awb, destination, weight, amount, charge_mode, manual_amount) select '00000000-0000-0000-0000-00000000a5a1', c1, 'TAM-X', 'MUMBAI', 1, 0, 'manual', 10 from tam.c$q$, 'seller B cannot insert manual shipment for seller A', array['42501']);
select tam.expect_fail($q$insert into public.shipments (client_id, awb, destination, weight, amount, charge_mode, manual_amount) select c1, 'TAM-X2', 'MUMBAI', 1, 0, 'manual', 10 from tam.c$q$, 'seller B cannot attach a manual shipment to seller A''s client', array['23503', '42501']);
reset role;

-- E2. Finalize with a typed (DOX/NON-DOX) shipment — regression for the draft guard fix
set local role authenticated;
select tam.as_user('00000000-0000-0000-0000-00000000a5a1');
insert into public.shipments (client_id, awb, destination, service, shipment_type, weight_f, weight, amount, charge_mode, manual_amount)
select c2, 'TAM-F1', 'MUMBAI', 'Standard', 'NON-DOX', 1.5, 1.5, 0, 'manual', 120 from tam.c;
insert into tam.ids select 'd2', public.create_invoice_draft((select c2 from tam.c), current_date - 30, current_date,
  array[(select id from public.shipments where awb = 'TAM-F1')]);
insert into tam.ids select 'f2', public.finalize_invoice((select id from tam.ids where k = 'd2'));
select tam.ok((select invoice_id = (select id from tam.ids where k = 'd2') and draft_invoice_id is null and amount = 120 from public.shipments where awb = 'TAM-F1'), 'typed manual shipment finalizes and links to issued invoice');
-- E3. DOX + NON-DOX through save (line removed = release), discard and finalize
insert into public.shipments (client_id, awb, destination, service, shipment_type, weight_f, weight, amount, charge_mode, manual_amount)
select c2, 'TAM-D1', 'MUMBAI', 'Standard', 'DOX', 250, 0.25, 0, 'manual', 60 from tam.c;
insert into public.shipments (client_id, awb, destination, service, shipment_type, weight_f, weight, amount, charge_mode, manual_amount)
select c2, 'TAM-N1', 'PUNE', 'Fast', 'NON-DOX', 3, 3, 0, 'manual', 90 from tam.c;
insert into tam.ids select 'd3', public.create_invoice_draft((select c2 from tam.c), current_date - 30, current_date,
  array[(select id from public.shipments where awb = 'TAM-D1'), (select id from public.shipments where awb = 'TAM-N1')]);
select tam.ok((select count(*) = 2 from public.shipments where draft_invoice_id = (select id from tam.ids where k = 'd3')), 'DOX and NON-DOX reserved by draft');
select public.save_invoice_draft((select id from tam.ids where k = 'd3'), '{}'::jsonb,
  jsonb_build_array(jsonb_build_object('shipment_id', (select id from public.shipments where awb = 'TAM-D1'), 'weight', 0.25, 'rate', 65, 'amount', 65)), '[]'::jsonb);
select tam.ok((select draft_invoice_id is null and amount = 90 from public.shipments where awb = 'TAM-N1'), 'save draft releases removed NON-DOX line, amount unchanged');
select tam.ok((select draft_invoice_id is not null and amount = 60 from public.shipments where awb = 'TAM-D1'), 'save draft keeps DOX reserved; line edit does not touch the shipment');
select public.discard_invoice_draft((select id from tam.ids where k = 'd3'));
select tam.ok((select draft_invoice_id is null and amount = 60 and weight_f = 250 from public.shipments where awb = 'TAM-D1'), 'discard releases DOX shipment unchanged');
insert into tam.ids select 'd4', public.create_invoice_draft((select c2 from tam.c), current_date - 30, current_date,
  array[(select id from public.shipments where awb = 'TAM-D1'), (select id from public.shipments where awb = 'TAM-N1')]);
insert into tam.ids select 'f4', public.finalize_invoice((select id from tam.ids where k = 'd4'));
select tam.ok((select count(*) = 2 and bool_and(invoice_id = (select id from tam.ids where k = 'd4') and draft_invoice_id is null)
  and sum(amount) = 150 from public.shipments where awb in ('TAM-D1', 'TAM-N1')), 'DOX and NON-DOX finalize, link to issued invoice, amounts kept');
select tam.ok((select total = 150 from public.invoices where id = (select id from tam.ids where k = 'd4')), 'issued Non-GST invoice total = stored amounts');
reset role;

-- F. Audit history
select tam.ok((select count(*) = 1 from public.shipment_charge_audit where awb = 'TAM-M1' and action = 'update' and old_mode = 'auto' and new_mode = 'manual' and new_amount = 150.50
  and actor = '00000000-0000-0000-0000-00000000a5a1'), 'audit: switch to manual');
select tam.ok((select count(*) = 1 from public.shipment_charge_audit where awb = 'TAM-M2' and action = 'insert' and new_amount = 75), 'audit: manual insert');
select tam.ok((select count(*) = 1 from public.shipment_charge_audit where awb = 'TAM-M2' and action = 'update' and new_mode = 'auto' and old_amount = 75), 'audit: back to auto');
select tam.ok((select count(*) = 1 from public.shipment_charge_audit where awb = 'TAM-M2' and action = 'delete' and old_amount = 80), 'audit: manual shipment deleted, history kept');
select tam.ok((select count(*) = 0 from public.shipment_charge_audit where awb = 'TAM-M1' and new_amount = 200), 'audit: refused changes not logged');
select tam.ok((select count(*) = 0 from public.shipment_charge_audit where awb like 'BOS%' or awb = '0007'), 'audit: auto-only shipments not logged');
select tam.ok((select count(*) = 0 from public.shipment_charge_audit a join public.shipments s on s.id = a.shipment_id
  where a.id = (select max(a2.id) from public.shipment_charge_audit a2 where a2.shipment_id = a.shipment_id)
    and a.action <> 'delete' and a.new_amount is distinct from s.amount), 'audit: latest entry equals the final stored amount');
select tam.ok((select count(*) > 0 and bool_and(actor_role = 'authenticated') from public.shipment_charge_audit where owner_id = '00000000-0000-0000-0000-00000000a5a1'), 'audit: records the request role, not the function owner');
set local role authenticated;
select tam.as_user('00000000-0000-0000-0000-00000000a5b1');
select tam.ok((select count(*) = 0 from public.shipment_charge_audit), 'audit: other seller sees nothing');
select tam.as_user('00000000-0000-0000-0000-00000000a5a1');
select tam.ok((select count(*) >= 4 from public.shipment_charge_audit), 'audit: owner can read history');
select tam.expect_fail($q$update public.shipment_charge_audit set new_amount = 1$q$, 'audit update (seller)', array['42501']);
select tam.expect_fail($q$delete from public.shipment_charge_audit$q$, 'audit delete (seller)', array['42501']);
select tam.expect_fail($q$insert into public.shipment_charge_audit (owner_id, shipment_id, awb, action) values (auth.uid(), gen_random_uuid(), 'X', 'insert')$q$, 'audit insert (seller)', array['42501']);
reset role;
set local role service_role;
select tam.expect_fail($q$delete from public.shipment_charge_audit$q$, 'audit delete (service role)', array['42501']);
reset role;
select tam.expect_fail($q$update public.shipment_charge_audit set new_amount = 1$q$, 'audit update (table owner)', array['P0001']);
select tam.expect_fail($q$delete from public.shipment_charge_audit$q$, 'audit delete (table owner)', array['P0001']);
select tam.expect_fail($q$truncate public.shipment_charge_audit$q$, 'audit truncate (table owner)', array['P0001']);

-- G. Existing data untouched
select tam.ok((select count(*) = 0 from (select * from tam.ship_before except select * from public.shipments) d), 'existing shipments unchanged');
select tam.ok((select count(*) = 0 from (select * from tam.inv_before except select * from public.invoices) d), 'existing invoices unchanged');

do $$ declare v_n int := (select count(*) from tam.log); begin
  if v_n <> __EXPECTED__ then raise exception 'FAIL: % assertions passed, expected __EXPECTED__', v_n; end if;
  raise notice 'ALL AWB SERIES AND MANUAL CHARGE TESTS PASSED (% assertions)', v_n;
end $$;
rollback;
