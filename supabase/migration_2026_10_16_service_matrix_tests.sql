-- =====================================================================
-- EntrySetu V1 — Service matrix tests. DEVELOPMENT ONLY (zfvnqcyqxxipjaugkmvf).
-- Run AFTER migration_2026_10_16_service_matrix.sql. One transaction, ROLLED BACK at the end.
-- Last notice: "ALL SERVICE MATRIX TESTS PASSED (31 assertions)" — raised only if all 31 passed.
-- =====================================================================
begin;
create schema tsm;
grant usage on schema tsm to authenticated, service_role;
create table tsm.log (n serial, label text);
grant insert, select on tsm.log to authenticated, service_role;
grant usage on sequence tsm.log_n_seq to authenticated, service_role;
create function tsm.expect_fail(q text, label text, codes text[]) returns void language plpgsql as $$
declare v_state text; v_msg text;
begin
  begin execute q;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    if not (v_state = any(codes)) then raise exception 'FAIL: % — wrong error % (%), expected %', label, v_state, v_msg, codes; end if;
    insert into tsm.log (label) values (label); raise notice 'PASS (blocked %) %', v_state, label; return;
  end;
  raise exception 'FAIL: % was allowed', label;
end $$;
create function tsm.ok(cond boolean, label text) returns void language plpgsql as $$
begin if cond is true then insert into tsm.log (label) values (label); raise notice 'PASS %', label; else raise exception 'FAIL: % (got %)', label, cond; end if; end $$;
create function tsm.as_user(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
end $$;
grant execute on all functions in schema tsm to authenticated, service_role;

create table tsm.ship_before as select * from public.shipments;
create table tsm.inv_before as select * from public.invoices;
create table tsm.slab_before as select * from public.rate_slabs;

-- A. Matrix
select tsm.ok(public.service_allowed('DOX','Standard') and public.service_allowed('DOX','Fast'), 'DOX: Standard, Fast');
select tsm.ok(public.service_allowed('NON-DOX','Surface') and public.service_allowed('NON-DOX','Air') and public.service_allowed('NON-DOX','Fast'), 'NON-DOX: Surface, Air, Fast');
select tsm.ok(not public.service_allowed('NON-DOX','Standard') and not public.service_allowed('DOX','Air') and not public.service_allowed('DOX','Surface'), 'other pairs not allowed');
select tsm.ok(not has_function_privilege('anon', 'public.save_rate_card(uuid,text,text,jsonb)', 'EXECUTE'), 'anon cannot save rate cards');

-- B. Seller with one zone mapped to Mumbai
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
 ('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-00000000c5a1','authenticated','authenticated','tsm-a@test.local','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
update public.profiles set state = 'Maharashtra' where id = '00000000-0000-0000-0000-00000000c5a1';
set local role authenticated;
select tsm.as_user('00000000-0000-0000-0000-00000000c5a1');
insert into public.clients (name, state, is_gst) values ('TSM ONE', 'Maharashtra', false), ('TSM TWO', 'Maharashtra', false);
insert into public.zones (name) values ('TSM WEST');
select count(*) from public.register_cities('{mumbai}');
insert into public.seller_city_zones (city_id, zone_id)
  select c.id, z.id from public.cities c, public.zones z where c.name_norm = 'mumbai' and z.name = 'TSM WEST' limit 1;
reset role;
create table tsm.v as select
  (select id from public.clients where name = 'TSM ONE') c1, (select id from public.clients where name = 'TSM TWO') c2,
  (select id from public.zones where name = 'TSM WEST') z;
grant select on all tables in schema tsm to authenticated, service_role;

-- C. Rate cards: each service saved separately
set local role authenticated;
select tsm.as_user('00000000-0000-0000-0000-00000000c5a1');
select tsm.ok(public.save_rate_card(null, 'NON-DOX', 'Surface', jsonb_build_array(jsonb_build_object('min_weight', 0, 'max_weight', 10, 'rates', jsonb_build_object((select z from tsm.v)::text, 40)))) = 1, 'save NON-DOX Surface card');
select tsm.ok(public.save_rate_card(null, 'NON-DOX', 'Fast', jsonb_build_array(jsonb_build_object('min_weight', 0, 'max_weight', 10, 'rates', jsonb_build_object((select z from tsm.v)::text, 90)))) = 1, 'save NON-DOX Fast card');
select tsm.ok(public.save_rate_card(null, 'DOX', 'Standard', jsonb_build_array(jsonb_build_object('min_weight', 0, 'max_weight', 500, 'rates', jsonb_build_object((select z from tsm.v)::text, 25)))) = 1, 'save DOX Standard card');
select tsm.ok(public.save_rate_card(null, 'DOX', 'Fast', jsonb_build_array(jsonb_build_object('min_weight', 0, 'max_weight', 500, 'rates', jsonb_build_object((select z from tsm.v)::text, 35)))) = 1, 'save DOX Fast card');
select tsm.expect_fail($q$select public.save_rate_card(null, 'NON-DOX', 'Standard', jsonb_build_array(jsonb_build_object('min_weight', 0, 'max_weight', 10, 'rates', '{}'::jsonb)))$q$, 'new NON-DOX Standard card refused', array['P0001']);
select tsm.expect_fail($q$select public.save_rate_card(null, 'DOX', 'Air', '[]'::jsonb)$q$, 'DOX Air card refused', array['P0001']);
select tsm.expect_fail($q$select public.save_rate_card(null, 'DOX', 'Surface', '[]'::jsonb)$q$, 'DOX Surface card refused', array['P0001']);

-- D. Pricing: Air never borrows Surface/Fast; missing Air = Needs Review at 0
insert into public.shipments (client_id, awb, destination, service, shipment_type, weight_f, weight, amount)
  select c1, 'TSM-AIR1', 'MUMBAI', 'Air', 'NON-DOX', 2, 2, 0 from tsm.v;
select tsm.ok((select pricing_status = 'needs_review' and amount = 0 from public.shipments where awb = 'TSM-AIR1'), 'Air without Air card -> Needs Review at 0 (Surface/Fast not used)');
insert into public.shipments (client_id, awb, destination, service, shipment_type, weight_f, weight, amount)
  select c1, 'TSM-SUR1', 'MUMBAI', 'Surface', 'NON-DOX', 2, 2, 0 from tsm.v;
select tsm.ok((select pricing_status = 'priced' and amount = 40 from public.shipments where awb = 'TSM-SUR1'), 'Surface priced from Surface card');
insert into public.shipments (client_id, awb, destination, service, shipment_type, weight_f, weight, amount)
  select c1, 'TSM-NF1', 'MUMBAI', 'Fast', 'NON-DOX', 2, 2, 0 from tsm.v;
select tsm.ok((select pricing_status = 'priced' and amount = 90 from public.shipments where awb = 'TSM-NF1'), 'NON-DOX Fast priced from NON-DOX Fast card');
insert into public.shipments (client_id, awb, destination, service, shipment_type, weight_f, weight, amount)
  select c1, 'TSM-DS1', 'MUMBAI', 'Standard', 'DOX', 200, 0.2, 0 from tsm.v;
select tsm.ok((select pricing_status = 'priced' and amount = 25 from public.shipments where awb = 'TSM-DS1'), 'DOX Standard unchanged');
insert into public.shipments (client_id, awb, destination, service, shipment_type, weight_f, weight, amount)
  select c1, 'TSM-DF1', 'MUMBAI', 'Fast', 'DOX', 200, 0.2, 0 from tsm.v;
select tsm.ok((select pricing_status = 'priced' and amount = 35 from public.shipments where awb = 'TSM-DF1'), 'DOX Fast unchanged');
select tsm.ok(public.save_rate_card(null, 'NON-DOX', 'Air', jsonb_build_array(jsonb_build_object('min_weight', 0, 'max_weight', 10, 'rates', jsonb_build_object((select z from tsm.v)::text, 65)))) = 1, 'save NON-DOX Air card');
insert into public.shipments (client_id, awb, destination, service, shipment_type, weight_f, weight, amount)
  select c1, 'TSM-AIR2', 'MUMBAI', 'Air', 'NON-DOX', 2, 2, 0 from tsm.v;
select tsm.ok((select pricing_status = 'priced' and amount = 65 from public.shipments where awb = 'TSM-AIR2'), 'Air priced from Air card only');
update public.shipments set weight = weight where awb = 'TSM-AIR1';
select tsm.ok((select pricing_status = 'priced' and amount = 65 from public.shipments where awb = 'TSM-AIR1'), 'review Air shipment reprices from Air card');

-- E. Shipments: no new NON-DOX Standard, no wrong pairs
select tsm.expect_fail($q$insert into public.shipments (client_id, awb, destination, service, shipment_type, weight_f, weight, amount) select c1, 'TSM-X1', 'MUMBAI', 'Standard', 'NON-DOX', 2, 2, 0 from tsm.v$q$, 'new NON-DOX Standard shipment refused', array['23514']);
select tsm.expect_fail($q$update public.shipments set service = 'Standard' where awb = 'TSM-SUR1'$q$, 'change Surface -> Standard refused', array['23514']);
select tsm.expect_fail($q$insert into public.shipments (client_id, awb, destination, service, shipment_type, weight_f, weight, amount) select c1, 'TSM-X2', 'MUMBAI', 'Air', 'DOX', 200, 0.2, 0 from tsm.v$q$, 'DOX Air shipment refused', array['23514']);
select tsm.expect_fail($q$insert into public.shipments (client_id, awb, destination, service, shipment_type, weight_f, weight, amount) select c1, 'TSM-X3', 'MUMBAI', 'Surface', 'DOX', 200, 0.2, 0 from tsm.v$q$, 'DOX Surface shipment refused', array['23514']);
reset role;

-- F. Legacy NON-DOX Standard rows (simulated as pre-existing: inserted with the guard disabled)
alter table public.shipments disable trigger shipments_aa_service_matrix;
alter table public.rate_slabs disable trigger rate_slabs_aa_service_matrix;
insert into public.rate_slabs (owner_id, client_id, shipment_type, service, min_weight, max_weight, rates, sort_order)
  select '00000000-0000-0000-0000-00000000c5a1', null, 'NON-DOX', 'Standard', 0, 10, jsonb_build_object(z::text, 30), 1 from tsm.v;
set local role authenticated;
select tsm.as_user('00000000-0000-0000-0000-00000000c5a1');
insert into public.shipments (client_id, awb, destination, service, shipment_type, weight_f, weight, amount)
  select c1, 'TSM-LEG1', 'MUMBAI', 'Standard', 'NON-DOX', 2, 2, 0 from tsm.v;
reset role;
alter table public.shipments enable trigger shipments_aa_service_matrix;
alter table public.rate_slabs enable trigger rate_slabs_aa_service_matrix;
set local role authenticated;
select tsm.as_user('00000000-0000-0000-0000-00000000c5a1');
select tsm.ok((select pricing_status = 'priced' and amount = 30 from public.shipments where awb = 'TSM-LEG1'), 'legacy NON-DOX Standard keeps its own legacy price');
update public.shipments set weight = 3, weight_f = 3 where awb = 'TSM-LEG1';
select tsm.ok((select service = 'Standard' and amount = 30 from public.shipments where awb = 'TSM-LEG1'), 'legacy shipment still editable, service unchanged');
update public.shipments set service = 'Surface' where awb = 'TSM-LEG1';
select tsm.ok((select service = 'Surface' and amount = 40 from public.shipments where awb = 'TSM-LEG1'), 'legacy shipment can move to Surface and uses Surface price');
select tsm.ok(public.copy_rate_cards(null, (select c2 from tsm.v), false) = 5, 'copy skips legacy NON-DOX Standard slabs');
select tsm.ok((select count(*) = 0 from public.rate_slabs where client_id = (select c2 from tsm.v) and shipment_type = 'NON-DOX' and service = 'Standard'), 'no legacy slab on the copy');
select tsm.ok(public.save_rate_card(null, 'NON-DOX', 'Standard', '[]'::jsonb) = 0
  and not exists (select 1 from public.rate_slabs where client_id is null and shipment_type = 'NON-DOX' and service = 'Standard'), 'legacy card can be cleared');
reset role;

-- G. Existing data untouched
select tsm.ok((select count(*) = 0 from (select * from tsm.ship_before except select * from public.shipments) d), 'existing shipments unchanged');
select tsm.ok((select count(*) = 0 from (select * from tsm.inv_before except select * from public.invoices) d), 'existing invoices unchanged');
select tsm.ok((select count(*) = 0 from (select * from tsm.slab_before except select * from public.rate_slabs) d), 'existing rate cards unchanged');

do $$ declare v_n int := (select count(*) from tsm.log); begin
  if v_n <> 31 then raise exception 'FAIL: % assertions passed, expected 31', v_n; end if;
  raise notice 'ALL SERVICE MATRIX TESTS PASSED (% assertions)', v_n;
end $$;
rollback;
