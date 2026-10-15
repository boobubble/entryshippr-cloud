-- =====================================================================
-- EntrySetu security & integrity tests for the 2026-10-15 migrations.
-- FOR MANUAL REVIEW. Run in the Supabase SQL Editor of the NEW project AFTER:
--   entrysetu_schema.sql, migration_2026_10_15_import_weights.sql,
--   migration_2026_10_15_rate_cards_zones.sql, migration_2026_10_15_permission_hardening.sql,
--   migration_2026_10_15_cities_zones.sql
-- Section J covers: ₹0 invoice guard, sync_cities idempotency/concurrency, ambiguous-city confirmation.
-- Everything runs in one transaction and is ROLLED BACK.
-- A blocked action must fail with the EXACT expected SQLSTATE (and message, where
-- the block is our own rule); any other error is a FAIL, so a missing grant on a
-- helper can never produce a false PASS. Last notice: "ALL TESTS PASSED".
-- =====================================================================
begin;

create schema t15;
grant usage on schema t15 to authenticated;

create function t15.expect_fail(q text, label text, codes text[], msg_like text default null)
returns void language plpgsql as $$
declare v_state text; v_msg text;
begin
  begin execute q;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    if not (v_state = any(codes)) then raise exception 'FAIL: % — wrong error % (%), expected %', label, v_state, v_msg, codes; end if;
    if msg_like is not null and v_msg not ilike msg_like then raise exception 'FAIL: % — message "%" not like "%"', label, v_msg, msg_like; end if;
    raise notice 'PASS (blocked %) %', v_state, label; return;
  end;
  raise exception 'FAIL: % was allowed', label;
end $$;
create function t15.ok(cond boolean, label text) returns void language plpgsql as $$
begin if cond is true then raise notice 'PASS %', label; else raise exception 'FAIL: % (got %)', label, cond; end if; end $$;
create function t15.as_user(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
end $$;
grant execute on all functions in schema t15 to authenticated;
create table t15.inv (k text primary key, id uuid not null);
grant select, insert on t15.inv to authenticated;

-- =====================================================================
-- A. Privilege catalogue checks (run as postgres)
-- =====================================================================
do $$
declare t text; p text;
begin
  foreach t in array array['profiles','user_roles','clients','rate_cards','invoice_series','invoices',
                           'shipments','payments','webhook_events','import_mappings','zones','rate_slabs'] loop
    foreach p in array array['INSERT','UPDATE','TRUNCATE','REFERENCES','TRIGGER'] loop
      if has_table_privilege('authenticated', 'public.' || t, p) then
        raise exception 'FAIL: authenticated has table-wide % on %', p, t; end if;
    end loop;
    foreach p in array array['SELECT','INSERT','UPDATE','DELETE'] loop
      if has_table_privilege('anon', 'public.' || t, p) then raise exception 'FAIL: anon has % on %', p, t; end if;
    end loop;
    if not has_table_privilege('service_role', 'public.' || t, 'SELECT,INSERT,UPDATE,DELETE') then
      raise exception 'FAIL: service_role lost access to %', t; end if;
  end loop;
  foreach t in array array['user_roles','invoices','payments','webhook_events','rate_slabs','invoice_series','profiles'] loop
    if has_table_privilege('authenticated', 'public.' || t, 'DELETE') then raise exception 'FAIL: authenticated can DELETE %', t; end if;
  end loop;
  if has_table_privilege('authenticated', 'public.webhook_events', 'SELECT') then raise exception 'FAIL: webhook_events readable'; end if;
  raise notice 'PASS no table-wide INSERT/UPDATE for authenticated; anon has nothing; service_role intact';
end $$;

do $$
declare c text;
begin
  foreach c in array array['id','owner_id','invoice_id','created_at','billing_weight','weight_unit','rate_zone','rate_slab','rate_applied'] loop
    if has_column_privilege('authenticated', 'public.shipments', c, 'INSERT') or has_column_privilege('authenticated', 'public.shipments', c, 'UPDATE') then
      raise exception 'FAIL: authenticated can write shipments.%', c; end if;
  end loop;
  foreach c in array array['plan','plan_expires_at','trial_ends_at','joining_fee_paid','id','email'] loop
    if has_column_privilege('authenticated', 'public.profiles', c, 'UPDATE') then raise exception 'FAIL: authenticated can update profiles.%', c; end if;
  end loop;
  foreach c in array array['owner_id','id'] loop
    if has_column_privilege('authenticated', 'public.clients', c, 'UPDATE') or has_column_privilege('authenticated', 'public.zones', c, 'UPDATE')
       or has_column_privilege('authenticated', 'public.import_mappings', c, 'UPDATE') or has_column_privilege('authenticated', 'public.rate_cards', c, 'UPDATE') then
      raise exception 'FAIL: authenticated can change %', c; end if;
  end loop;
  if has_column_privilege('authenticated', 'public.invoice_series', 'fy', 'UPDATE') then raise exception 'FAIL: series fy updatable'; end if;
  raise notice 'PASS protected columns are not writable';
end $$;

do $$
declare r record; v_f regprocedure;
begin
  for r in select p.oid::regprocedure f, p.proconfig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prosecdef loop
    if r.proconfig is null or not ('search_path=""' = any(r.proconfig)) then
      raise exception 'FAIL: SECURITY DEFINER % has search_path %', r.f, r.proconfig; end if;
  end loop;
  foreach v_f in array array['public.activate_payment(text,text,bigint)','public.record_webhook_event(text,text)',
                             'public.admin_set_access(uuid,text,public.plan_kind)','public.shipment_rate(uuid,uuid,text,text,text,numeric)',
                             'public.shipments_apply_rate()','public.zones_normalise()','public.handle_new_user()']::regprocedure[] loop
    if has_function_privilege('authenticated', v_f, 'EXECUTE') or has_function_privilege('anon', v_f, 'EXECUTE') then
      raise exception 'FAIL: % executable by users', v_f; end if;
  end loop;
  if has_function_privilege('anon', 'public.save_rate_card(uuid,text,text,jsonb)', 'EXECUTE') then raise exception 'FAIL: anon can save rate cards'; end if;
  raise notice 'PASS SECURITY DEFINER functions pinned to empty search_path; privileged ones not user-callable';
end $$;

-- =====================================================================
-- B. Users and data
-- =====================================================================
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a1', 'authenticated', 'authenticated',
   't15-a@test.local', '', now(), '{"provider":"email","providers":["email"]}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000b1', 'authenticated', 'authenticated',
   't15-b@test.local', '', now(), '{"provider":"email","providers":["email"]}', '{}', now(), now());

set local role authenticated;
select t15.as_user('00000000-0000-0000-0000-0000000000a1');
insert into public.clients (name) values ('A1'), ('A2');
insert into public.zones (name, destinations, sort_order) values ('Local', '{" Mumbai ","Thane"}', 0), ('Metro', '{Delhi}', 1);
select t15.ok((select destinations from public.zones where name = 'Local') = '{Mumbai,Thane}', 'zone destinations trimmed');
select t15.expect_fail($$insert into public.zones (name, destinations) values ('Dup', '{mumbai}')$$,
  'destination cannot be in two zones', '{P0001}', '%already in another zone%');

reset role;
create table t15.ids as select
  (select id from public.clients where name = 'A1') a1, (select id from public.clients where name = 'A2') a2,
  (select id from public.zones where name = 'Local') zl, (select id from public.zones where name = 'Metro') zm;
grant select on t15.ids to authenticated;
set local role authenticated;
select t15.as_user('00000000-0000-0000-0000-0000000000a1');

-- Rate cards via RPC
select public.save_rate_card((select a1 from t15.ids), 'DOX', 'Standard', jsonb_build_array(
  jsonb_build_object('min_weight', 0,   'max_weight', 100, 'rates', jsonb_build_object((select zl from t15.ids), 20, (select zm from t15.ids), 35)),
  jsonb_build_object('min_weight', 101, 'max_weight', 250, 'rates', jsonb_build_object((select zl from t15.ids), 30))));
select public.save_rate_card((select a1 from t15.ids), 'NON-DOX', 'Standard', jsonb_build_array(
  jsonb_build_object('min_weight', 0,   'max_weight', 0.5, 'rates', jsonb_build_object((select zl from t15.ids), 60)),
  jsonb_build_object('min_weight', 0.5, 'max_weight', 5,   'rates', jsonb_build_object((select zl from t15.ids), 90))));
select public.save_rate_card(null, 'DOX', 'Fast', jsonb_build_array(
  jsonb_build_object('min_weight', 0, 'max_weight', 500, 'rates', jsonb_build_object((select zm from t15.ids), 99))));
select t15.ok((select count(*) from public.rate_slabs) = 5, 'rate cards saved');

select t15.expect_fail($$select public.save_rate_card(null, 'DOX', 'Standard', '[{"min_weight":0,"max_weight":100},{"min_weight":50,"max_weight":200}]')$$,
  'overlapping slabs rejected', '{P0001}', '%overlaps%');
select t15.expect_fail($$select public.save_rate_card(null, 'DOX', 'Standard', '[{"min_weight":10,"max_weight":5}]')$$,
  'max <= min rejected', '{P0001}', '%invalid%');
select t15.expect_fail($$select public.save_rate_card(null, 'DOX', 'Standard', '[{"min_weight":0,"max_weight":5,"rates":{"00000000-0000-0000-0000-000000000000":5}}]')$$,
  'unknown zone rejected', '{P0001}', '%Unknown zone%');
select t15.expect_fail($$select public.save_rate_card(null, 'DOX', 'Express', '[]')$$, 'invalid service rejected', '{P0001}');
select t15.expect_fail($$insert into public.rate_slabs (client_id, shipment_type, service, min_weight, max_weight) values (null, 'DOX', 'Standard', 0, 1)$$,
  'direct rate_slabs insert blocked', '{42501}');
select t15.expect_fail($$update public.rate_slabs set rates = '{}'$$, 'direct rate_slabs update blocked', '{42501}');
select t15.expect_fail($$delete from public.rate_slabs$$, 'direct rate_slabs delete blocked', '{42501}');
select t15.expect_fail($$select public.copy_rate_cards((select a1 from t15.ids), null, false)$$,
  'copy onto card with rates needs confirmation', '{P0001}', 'TARGET_HAS_RATES');
select t15.ok(public.copy_rate_cards((select a1 from t15.ids), (select a2 from t15.ids), false) = 4, 'copy to empty client works');

-- =====================================================================
-- C. Weights and server-side pricing
-- =====================================================================
insert into public.shipments (client_id, awb, destination, service, shipment_type, weight_f, weight_g, weight_h, weight_t, amount)
values ((select a1 from t15.ids), 'D1', 'mumbai', 'Standard', 'DOX', 50, 80, null, 10, 9999);
select t15.ok((select billing_weight = 80 and weight_unit = 'g' and weight = 0.080 from public.shipments where awb = 'D1'), 'DOX billing weight = max grams, kg = 0.080');
select t15.ok((select amount = 20 and rate_applied = 20 and rate_zone = 'Local' and rate_slab = '0–100 g' from public.shipments where awb = 'D1'),
  'browser amount 9999 ignored; card rate 20 applied');

insert into public.shipments (client_id, awb, destination, service, shipment_type, weight_f, weight_g)
values ((select a1 from t15.ids), 'D2', 'Thane', 'Standard', 'DOX', 100.4, 99);
select t15.ok((select billing_weight = 100.4 and weight = 0.101 and amount = 30 and rate_slab = '101–250 g' from public.shipments where awb = 'D2'),
  'DOX 100.4 g kept exact, billed as 101 g (0.101 kg), next slab — no undercharge');

insert into public.shipments (client_id, awb, destination, service, shipment_type, weight_f, weight_g, weight_t)
values ((select a1 from t15.ids), 'N1', 'Mumbai', 'Standard', 'NON-DOX', 0.25, 0.5, 0.125);
select t15.ok((select billing_weight = 0.5 and weight_unit = 'kg' and weight = 0.5 and amount = 60 from public.shipments where awb = 'N1'),
  'NON-DOX 0.5 kg on shared boundary uses lower slab');
insert into public.shipments (client_id, awb, destination, service, shipment_type, weight_h)
values ((select a1 from t15.ids), 'N2', 'Mumbai', 'Standard', 'NON-DOX', 3.25);
select t15.ok((select billing_weight = 3.25 and amount = 90 from public.shipments where awb = 'N2'), 'NON-DOX kg slab');

insert into public.shipments (client_id, awb, destination, service, shipment_type, weight_f)
values ((select a2 from t15.ids), 'F1', 'Delhi', 'Fast', 'DOX', 300);
select t15.ok((select amount = 99 and rate_zone = 'Metro' from public.shipments where awb = 'F1'), 'Default card used when client has none');

update public.shipments set amount = 1 where awb = 'D1';
select t15.ok((select amount = 20 from public.shipments where awb = 'D1'), 'amount tampering on update re-priced to 20');
update public.shipments set weight = 0.001 where awb = 'D1';
select t15.ok((select weight = 0.080 from public.shipments where awb = 'D1'), 'kg weight tampering reset');

-- (after migration 4) unpriceable shipments are stored as Needs Review with amount 0, never invoiced
insert into public.shipments (client_id, awb, destination, shipment_type, weight_f) select a1, 'X1', 'Pune', 'DOX', 50 from t15.ids;
select t15.ok((select pricing_status = 'needs_review' and amount = 0 and rate_applied is null and review_reason like '%has no zone%' from public.shipments where awb = 'X1'),
  'unknown/unmapped city -> needs review, not charged');
insert into public.shipments (client_id, awb, destination, shipment_type, weight_f) select a1, 'X2', 'Delhi', 'DOX', 200 from t15.ids;
select t15.ok((select pricing_status = 'needs_review' and review_reason like 'No Metro rate%' from public.shipments where awb = 'X2'), 'missing zone rate -> needs review');
insert into public.shipments (client_id, awb, destination, shipment_type, weight_f) select a1, 'X3', 'Mumbai', 'DOX', 900 from t15.ids;
select t15.ok((select pricing_status = 'needs_review' and review_reason = 'No slab covers 900 g' from public.shipments where awb = 'X3'), 'weight above slabs -> needs review');
insert into public.shipments (client_id, awb, destination, shipment_type, service, weight_f) select a1, 'X4', 'Mumbai', 'NON-DOX', 'Fast', 1 from t15.ids;
select t15.ok((select pricing_status = 'needs_review' and review_reason = 'No NON-DOX Fast rate card' from public.shipments where awb = 'X4'), 'no card -> needs review');
delete from public.shipments where awb in ('X1','X2','X3','X4');
select t15.expect_fail($$insert into public.shipments (client_id, awb, destination, shipment_type) select a1, 'X5', 'Mumbai', 'DOX' from t15.ids$$,
  'typed shipment without weights rejected', '{23514}');
select t15.expect_fail($$insert into public.shipments (client_id, awb, destination, shipment_type, weight_f) select a1, 'X6', 'Mumbai', 'DOX', 0 from t15.ids$$,
  'zero weight rejected', '{23514}');
select t15.expect_fail($$insert into public.shipments (client_id, awb, weight_f, amount) select a1, 'X7', 5, 5 from t15.ids$$,
  'raw weights without type rejected', '{23514}');
select t15.expect_fail($$insert into public.shipments (client_id, awb, destination, shipment_type, service, weight_f) select a1, 'X8', 'Mumbai', 'DOX', 'Express', 5 from t15.ids$$,
  'typed shipment needs Standard/Fast', '{23514,P0001}');
select t15.expect_fail($$insert into public.shipments (client_id, awb, shipment_type, weight_f, billing_weight) select a1, 'X9', 'DOX', 5, 1 from t15.ids$$,
  'billing_weight not writable', '{42501,428C9}');
select t15.expect_fail($$update public.shipments set rate_applied = 1 where awb = 'D1'$$, 'rate_applied not writable', '{42501}');
select t15.expect_fail($$insert into public.shipments (client_id, awb, destination, shipment_type, weight_f) select a1, 'D1', 'Mumbai', 'DOX', 5 from t15.ids$$,
  'duplicate AWB rejected', '{23505}');

-- Manual (untyped) V2 shipment still works with user amount
insert into public.shipments (client_id, awb, weight, amount) select a1, 'M1', 1.2, 75 from t15.ids;
select t15.ok((select amount = 75 and billing_weight is null and rate_applied is null from public.shipments where awb = 'M1'), 'manual V2 shipment unchanged');

-- Mapping
insert into public.import_mappings (name, mapping) values ('Courier X', '{"awb":0}');
select t15.expect_fail($$update public.import_mappings set owner_id = gen_random_uuid()$$, 'mapping owner not changeable', '{42501}');

-- =====================================================================
-- D. Tenant isolation
-- =====================================================================
select t15.as_user('00000000-0000-0000-0000-0000000000b1');
select t15.ok((select count(*) from public.zones) = 0 and (select count(*) from public.rate_slabs) = 0
          and (select count(*) from public.import_mappings) = 0 and (select count(*) from public.shipments) = 0, 'B sees none of A''s data');
select t15.expect_fail($$select public.save_rate_card((select a1 from t15.ids), 'DOX', 'Standard', '[]')$$,
  'B cannot save card for A''s client', '{42501}', 'Client not found');
select t15.expect_fail($$select public.copy_rate_cards((select a1 from t15.ids), null, true)$$,
  'B cannot copy A''s cards', '{42501}', 'Client not found');
select t15.expect_fail($$select public.save_rate_card(null, 'DOX', 'Standard', jsonb_build_array(jsonb_build_object('min_weight',0,'max_weight',1,'rates',jsonb_build_object((select zl from t15.ids),5))))$$,
  'B cannot price with A''s zone', '{P0001}', '%Unknown zone%');
select t15.expect_fail($$insert into public.shipments (client_id, awb, destination, shipment_type, weight_f) select a1, 'B1', 'Mumbai', 'DOX', 5 from t15.ids$$,
  'B cannot add shipment to A''s client', '{23503,42501,P0001}');
update public.zones set destinations = '{Hacked}';
delete from public.zones;
select t15.expect_fail($$select public.shipment_rate(auth.uid(), null, 'DOX', 'Standard', 'Mumbai', 5)$$, 'users cannot call shipment_rate', '{42501}');
reset role;
select t15.ok((select count(*) from public.zones where owner_id = '00000000-0000-0000-0000-0000000000a1' and 'Mumbai' = any(destinations)) = 1,
  'B could not change or delete A''s zones');

-- =====================================================================
-- E. Expired trial = read-only
-- =====================================================================
update public.profiles set trial_ends_at = now() - interval '1 day', plan = null where id = '00000000-0000-0000-0000-0000000000a1';
set local role authenticated;
select t15.as_user('00000000-0000-0000-0000-0000000000a1');
select t15.ok((select count(*) from public.rate_slabs) > 0, 'expired user can still read rate cards');
select t15.expect_fail($$select public.save_rate_card(null, 'DOX', 'Standard', '[]')$$, 'expired: save card blocked', '{42501}', '%expired%');
select t15.expect_fail($$select public.copy_rate_cards((select a1 from t15.ids), (select a2 from t15.ids), true)$$, 'expired: copy blocked', '{42501}', '%expired%');
select t15.expect_fail($$insert into public.zones (name) values ('Z9')$$, 'expired: zone insert blocked', '{42501}');
select t15.expect_fail($$insert into public.import_mappings (name, mapping) values ('m2', '{}')$$, 'expired: mapping insert blocked', '{42501}');
select t15.expect_fail($$insert into public.shipments (client_id, awb, weight, amount) select a1, 'E1', 1, 1 from t15.ids$$, 'expired: shipment insert blocked', '{42501}');
delete from public.zones;               -- RLS: 0 rows
delete from public.import_mappings;     -- RLS: 0 rows
reset role;
select t15.ok((select count(*) from public.zones where owner_id = '00000000-0000-0000-0000-0000000000a1') = 2
          and (select count(*) from public.import_mappings where owner_id = '00000000-0000-0000-0000-0000000000a1') = 1,
  'expired: deletes had no effect');


-- =====================================================================
-- F. Invoices: series protection, creation, sequential numbering, cancellation
-- =====================================================================
set local role authenticated;
select t15.as_user('00000000-0000-0000-0000-0000000000b1');
update public.profiles set state = 'Gujarat';
insert into public.clients (name, state, is_gst) values ('B-GST', 'Gujarat', true), ('B-IGST', 'Maharashtra', true), ('B-NG', 'Maharashtra', false);
reset role;
create table t15.b as select
  (select id from public.clients where name = 'B-GST') gst, (select id from public.clients where name = 'B-IGST') igst,
  (select id from public.clients where name = 'B-NG') ng, public.fy_label(current_date) fy;
grant select on t15.b to authenticated;
set local role authenticated;
select t15.as_user('00000000-0000-0000-0000-0000000000b1');

select t15.expect_fail($$insert into public.invoice_series (fy, kind, prefix, next_number) select fy, 'gst', 'X', 1 from t15.b$$, 'direct series insert blocked', '{42501}');
select public.set_invoice_series((select fy from t15.b), 'gst', 'INV', 5);
select t15.expect_fail($$update public.invoice_series set next_number = 1$$, 'direct next_number update blocked', '{42501}');
select t15.expect_fail($$update public.invoice_series set prefix = 'Z'$$, 'direct prefix update blocked', '{42501}');
select t15.expect_fail($$delete from public.invoice_series$$, 'series delete blocked', '{42501}');
select t15.expect_fail($$select public.set_invoice_series((select fy from t15.b), 'gst', 'INV', 3)$$, 'series cannot go backwards', '{P0001}', '%backwards%');
select t15.expect_fail($$select public.set_invoice_series((select fy from t15.b), 'gst', 'bad prefix!', 9)$$, 'invalid prefix rejected', '{P0001}');

insert into public.shipments (client_id, awb, weight, amount) select gst, 'B-S1', 1, 100 from t15.b;
insert into t15.inv select 'inv1', public.create_invoice((select gst from t15.b), current_date - 30, current_date);
select t15.ok((select seq = 5 and invoice_no = 'INV/' || fy || '/0005' and cgst = 9 and sgst = 9 and igst = 0 and total = 118
               from public.invoices where id = (select id from t15.inv where k = 'inv1')), 'first GST invoice uses configured start 5, CGST+SGST');
insert into public.shipments (client_id, awb, weight, amount) select gst, 'B-S2', 1, 200 from t15.b;
insert into t15.inv select 'inv2', public.create_invoice((select gst from t15.b), current_date - 30, current_date);
select t15.ok((select seq = 6 from public.invoices where id = (select id from t15.inv where k = 'inv2')), 'second invoice in same series = 6 (guard-trigger conflict fixed)');
insert into public.shipments (client_id, awb, weight, amount) select igst, 'B-S3', 1, 100 from t15.b;
insert into t15.inv select 'inv3', public.create_invoice((select igst from t15.b), current_date - 30, current_date);
select t15.ok((select seq = 7 and igst = 18 and cgst = 0 from public.invoices where id = (select id from t15.inv where k = 'inv3')), 'inter-state invoice = 7 with IGST');
insert into public.shipments (client_id, awb, weight, amount) select ng, 'B-S4', 1, 50 from t15.b;
insert into t15.inv select 'inv4', public.create_invoice((select ng from t15.b), current_date - 30, current_date);
select t15.ok((select invoice_no = 'BOS/' || fy || '/0001' and total = 50 and cgst + sgst + igst = 0 from public.invoices where id = (select id from t15.inv where k = 'inv4')),
  'Non-GST has its own series starting at 1, no tax');
select t15.expect_fail($$select public.set_invoice_series((select fy from t15.b), 'gst', 'INV', 7)$$, 'cannot reuse used numbers', '{P0001}', '%backwards%');
select t15.expect_fail($$select public.create_invoice((select gst from t15.b), current_date - 30, current_date)$$, 'no unbilled shipments -> no number reserved', '{P0001}', '%No unbilled%');
select t15.ok((select next_number = 8 from public.invoice_series where kind = 'gst'), 'failed invoice did not consume a number');

update public.shipments set amount = 1 where awb = 'B-S1';     -- RLS: billed rows not updatable (0 rows)
delete from public.shipments where awb = 'B-S1';               -- RLS: 0 rows
select t15.ok((select amount = 100 from public.shipments where awb = 'B-S1'), 'billed shipment frozen');
select t15.expect_fail($$update public.invoices set total = 0$$, 'invoice not editable', '{42501}');
select t15.expect_fail($$delete from public.invoices$$, 'invoice not deletable', '{42501}');

select public.cancel_invoice((select id from t15.inv where k = 'inv2'), 'test');
select t15.ok((select status = 'cancelled' from public.invoices where id = (select id from t15.inv where k = 'inv2'))
          and (select invoice_id is null from public.shipments where awb = 'B-S2'), 'cancel frees shipments');
select t15.expect_fail($$select public.cancel_invoice((select id from t15.inv where k = 'inv2'))$$, 'cannot cancel twice', '{P0001}', '%already cancelled%');
insert into t15.inv select 'inv5', public.create_invoice((select gst from t15.b), current_date - 30, current_date);
select t15.ok((select seq = 8 from public.invoices where id = (select id from t15.inv where k = 'inv5')), 're-billing after cancel takes 8; 6 never reused');

-- =====================================================================
-- G. Empty search_path: signup, service_role, payment activation, webhook, admin
-- =====================================================================
reset role;
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000c1', 'authenticated', 'authenticated',
        't15-c@test.local', '', now(), '{"provider":"email","providers":["email"]}', '{"business_name":"C Couriers"}', now(), now());
select t15.ok((select business_name = 'C Couriers' and trial_ends_at > now() from public.profiles where id = '00000000-0000-0000-0000-0000000000c1'),
  'signup trigger works with empty search_path');

set local role service_role;
select t15.ok((select count(*) from public.invoices) >= 5 and (select count(*) from public.shipments) > 0, 'service_role reads all tenants');
insert into public.payments (owner_id, plan, amount_paise, includes_joining_fee, razorpay_order_id)
values ('00000000-0000-0000-0000-0000000000c1', 'standard', 495600, true, 'order_t15_1'),
       ('00000000-0000-0000-0000-0000000000c1', 'unlimited', 212400, false, 'order_t15_2');
select t15.ok(public.activate_payment('order_t15_1', 'pay_t15_1', 495600) is true, 'payment activates once');
select t15.ok(public.activate_payment('order_t15_1', 'pay_t15_1', 495600) is false, 'repeat activation ignored');
select t15.expect_fail($$select public.activate_payment('order_t15_2', 'pay_t15_2', 1)$$, 'amount mismatch rejected', '{P0001}', '%Amount mismatch%');
select t15.expect_fail($$select public.activate_payment('nope', 'p', 1)$$, 'unknown order rejected', '{P0001}', '%Unknown order%');
select t15.ok((select plan = 'standard' and plan_expires_at > now() + interval '360 days' and joining_fee_paid
               from public.profiles where id = '00000000-0000-0000-0000-0000000000c1'), 'plan + joining fee recorded');
select t15.ok(public.record_webhook_event('evt_t15', 'payment.captured') is true and public.record_webhook_event('evt_t15', 'payment.captured') is false,
  'webhook event idempotent');
select public.admin_set_access('00000000-0000-0000-0000-0000000000c1', 'extend_trial');
select t15.ok((select trial_ends_at > now() + interval '4 days' from public.profiles where id = '00000000-0000-0000-0000-0000000000c1'), 'admin_set_access works');
reset role;

-- =====================================================================
-- H. Older kg rate cards are never a fallback; ₹0 protection
-- =====================================================================
set local role authenticated;
select t15.as_user('00000000-0000-0000-0000-0000000000c1');
select t15.expect_fail($$select public.activate_payment('order_t15_2', 'x', 212400)$$, 'user cannot activate payment', '{42501}');
insert into public.clients (name) values ('C1');
insert into public.zones (name, destinations) values ('West', '{Pune}');
insert into public.rate_cards (client_id, service, min_weight, max_weight, rate, extra_per_kg)
  select id, 'Standard', 0, 1, 50, 0 from public.clients where name = 'C1'
  union all select id, 'Standard', 1, 2, 70, 20 from public.clients where name = 'C1';
insert into public.rate_cards (client_id, service, min_weight, max_weight, rate) values (null, 'Fast', 0, 5, 0);
reset role;
create table t15.c as select (select id from public.clients where name = 'C1') c1, (select id from public.zones where name = 'West') zw;
grant select on t15.c to authenticated;
set local role authenticated;
select t15.as_user('00000000-0000-0000-0000-0000000000c1');

insert into public.shipments (client_id, awb, destination, shipment_type, weight_f) select c1, 'L1', 'Pune', 'NON-DOX', 1.5 from t15.c;
select t15.ok((select pricing_status = 'needs_review' and amount = 0 and review_reason like '%zone-wise rate card%' from public.shipments where awb = 'L1'), 'older kg slab is NOT a fallback: Needs Review');
insert into public.shipments (client_id, awb, destination, shipment_type, weight_f) select c1, 'L2', 'Pune', 'NON-DOX', 3.2 from t15.c;
select t15.ok((select pricing_status = 'needs_review' and amount = 0 from public.shipments where awb = 'L2'), 'older kg slab above top slab: Needs Review');
insert into public.shipments (client_id, awb, destination, shipment_type, weight_f) select c1, 'L3', 'Pune', 'DOX', 999.4 from t15.c;
select t15.ok((select weight = 1.000 and pricing_status = 'needs_review' from public.shipments where awb = 'L3'), 'DOX 999.4 g -> 1 kg stored; no zone-wise card -> Needs Review');
insert into public.shipments (client_id, awb, destination, shipment_type, service, weight_f) select c1, 'L4', 'Pune', 'DOX', 'Fast', 10 from t15.c;
select t15.ok((select pricing_status = 'needs_review' and amount = 0 and review_reason like '%zone-wise rate card%' from public.shipments where awb = 'L4'), 'legacy ₹0 default rate never applied (needs review)');
select t15.expect_fail($$select public.save_rate_card((select c1 from t15.c), 'DOX', 'Standard', jsonb_build_array(jsonb_build_object('min_weight',0,'max_weight',500,'rates',jsonb_build_object((select zw from t15.c),0))))$$,
  'zero zone rate rejected', '{P0001}', '%more than 0%');
select t15.expect_fail($$select public.save_rate_card((select c1 from t15.c), 'DOX', 'Standard', jsonb_build_array(jsonb_build_object('min_weight',0,'max_weight',500,'rates',jsonb_build_object((select zw from t15.c),-5))))$$,
  'negative zone rate rejected', '{P0001}', '%more than 0%');
select public.save_rate_card((select c1 from t15.c), 'DOX', 'Standard', jsonb_build_array(jsonb_build_object('min_weight',0,'max_weight',500,'rates',jsonb_build_object((select zw from t15.c),25))));
insert into public.shipments (client_id, awb, destination, shipment_type, weight_f) select c1, 'L5', 'Pune', 'DOX', 300 from t15.c;
select t15.ok((select amount = 25 and rate_zone = 'West' from public.shipments where awb = 'L5'), 'zone-wise card takes over from legacy once saved');
select t15.ok((select count(*) = 0 from public.shipments where pricing_status = 'priced' and shipment_type is not null and amount <= 0), 'no typed shipment priced at ₹0');
select t15.ok((select pricing_status = 'needs_review' from public.shipments where awb = 'L1'), 'older kg slab still ignored after a DOX zone card exists (NON-DOX has none)');

-- =====================================================================
-- I. Cross-tenant regression (C vs A and B)
-- =====================================================================
select t15.ok((select count(*) from public.invoices) = 0 and (select count(*) from public.invoice_series) = 0
          and (select count(*) from public.payments where owner_id <> auth.uid()) = 0
          and (select count(*) from public.clients) = 1 and (select count(*) from public.zones) = 1, 'C sees only own rows');
select t15.expect_fail($$select public.create_invoice((select gst from t15.b), current_date - 30, current_date)$$, 'C cannot invoice B''s client', '{P0001}', 'Client not found');
select t15.expect_fail($$select public.cancel_invoice((select id from t15.inv where k = 'inv1'))$$, 'C cannot cancel B''s invoice', '{P0001}', '%not found%');
select public.set_invoice_series((select fy from t15.b), 'gst', 'C', 100);
select t15.expect_fail($$select public.save_rate_card((select c1 from t15.c), 'DOX', 'Fast', jsonb_build_array(jsonb_build_object('min_weight',0,'max_weight',1,'rates',jsonb_build_object((select zl from t15.ids),5))))$$,
  'C cannot use A''s zone', '{P0001}', '%Unknown zone%');
select t15.expect_fail($$insert into public.shipments (client_id, awb, weight, amount) select gst, 'C-X', 1, 1 from t15.b$$, 'C cannot use B''s client', '{23503,42501}');
reset role;
select t15.ok((select next_number = 9 and prefix = 'INV' from public.invoice_series
               where owner_id = '00000000-0000-0000-0000-0000000000b1' and kind = 'gst'), 'B''s series untouched by C');
select t15.ok((select status = 'issued' from public.invoices where id = (select id from t15.inv where k = 'inv1')), 'B''s invoice untouched by C');

-- =====================================================================
-- J. Cities & zones: invoice ₹0 guard, sync_cities idempotency, ambiguity
-- =====================================================================
-- J1. sync_cities is idempotent and adopts concurrently-inserted rows (as postgres)
select public.ensure_city('Zedtown', 'user', '00000000-0000-0000-0000-0000000000c1');   -- simulates a racing insert
create table t15.sync1 as select public.sync_cities($j$[
  {"name":"Aurangabad","state":"Maharashtra","aliases":["Sambhajinagar"]},
  {"name":"Aurangabad","state":"Bihar"},
  {"name":"Zedtown"},
  {"name":"Zedtown"},
  {"name":"Nashik","state":"Maharashtra","district":"Nashik"}]$j$::jsonb) r;
select t15.ok((select (r->>'added')::int = 3 and (r->>'aliases')::int = 1 from t15.sync1), 'sync adds 3 new cities, adopts existing Zedtown, no duplicate error');
select t15.ok((select count(*) = 1 from public.cities where name_norm = 'zedtown'), 'no duplicate city from racing insert');
select t15.ok((select (r->>'added')::int = 0 and (r->>'updated')::int = 0 and (r->>'aliases')::int = 0
               from (select public.sync_cities($j$[
  {"name":"Aurangabad","state":"Maharashtra","aliases":["Sambhajinagar"]},
  {"name":"Aurangabad","state":"Bihar"},{"name":"Zedtown"},
  {"name":"Nashik","state":"Maharashtra","district":"Nashik"}]$j$::jsonb) r) x), 'second identical sync is a no-op');
select t15.ok((select count(*) = 2 from public.cities where name_norm = 'aurangabad'), 'Aurangabad still exactly 2 rows');
select t15.expect_fail($$select public.sync_cities('{"x":1}'::jsonb)$$, 'sync rejects non-array payload', '{P0001}', 'Invalid registry');
set local role authenticated;
select t15.as_user('00000000-0000-0000-0000-0000000000c1');
select t15.expect_fail($$select public.sync_cities('[]'::jsonb)$$, 'users cannot run sync_cities', '{42501}');

-- J2. Ambiguous city is never auto-resolved by an existing zone mapping
insert into public.seller_city_zones (city_id, zone_id)
  select c.id, (select zw from t15.c) from public.cities c where c.name_norm = 'aurangabad' and c.state = 'Maharashtra';
select t15.ok((select status = 'ambiguous' and city_id is null from public.register_cities('{Aurangabad}')), 'mapping one candidate does NOT resolve the ambiguous name');
insert into public.shipments (client_id, awb, destination, shipment_type, weight_f) select c1, 'AMB1', 'Aurangabad', 'DOX', 300 from t15.c;
select t15.ok((select pricing_status = 'needs_review' and city_id is null and amount = 0 from public.shipments where awb = 'AMB1'), 'ambiguous shipment stays Needs Review');
insert into public.seller_city_aliases (alias_norm, city_id) select 'Aurangabad', id from public.cities where name_norm = 'aurangabad' and state = 'Maharashtra';
select t15.ok((select pricing_status = 'priced' and amount = 25 and rate_zone = 'West' from public.shipments where awb = 'AMB1'), 'explicit seller confirmation resolves and re-prices');
-- cross-tenant: B neither sees nor benefits from or changes C's confirmation
select t15.as_user('00000000-0000-0000-0000-0000000000b1');
select t15.ok((select count(*) = 0 from public.seller_city_aliases) and (select count(*) = 0 from public.seller_city_zones), 'B sees none of C''s aliases/mappings');
select t15.ok((select status = 'ambiguous' from public.register_cities('{Aurangabad}')), 'C''s confirmation does not apply to B');
select t15.expect_fail($$insert into public.seller_city_aliases (owner_id, alias_norm, city_id) select '00000000-0000-0000-0000-0000000000c1', 'aurangabad bihar', id from public.cities where name_norm = 'aurangabad' and state = 'Bihar'$$,
  'B cannot write an alias for C', '{42501}');
update public.seller_city_aliases set city_id = (select id from public.cities where name_norm = 'aurangabad' and state = 'Bihar');  -- RLS: 0 rows
delete from public.seller_city_aliases;   -- RLS: 0 rows
delete from public.seller_city_zones;     -- RLS: 0 rows
select t15.as_user('00000000-0000-0000-0000-0000000000c1');
select t15.ok((select count(*) = 1 from public.seller_city_aliases) and (select count(*) = 1 from public.seller_city_zones), 'C''s alias and mapping untouched by B');

-- J3. Invoices are blocked when any selected shipment is ₹0 or less
insert into public.shipments (client_id, awb, ship_date, weight, amount) select c1, 'Z0', current_date - 100, 1, 0 from t15.c;   -- untyped manual
insert into public.shipments (client_id, awb, ship_date, weight, amount) select c1, 'Z1', current_date - 100, 1, 40 from t15.c;
select t15.expect_fail($$select public.create_invoice((select c1 from t15.c), current_date - 100, current_date - 100)$$,
  'invoice blocked by ₹0 untyped shipment', '{P0001}', '%₹0 or less%');
select t15.ok((select count(*) = 0 from public.invoices), 'no invoice created and no number consumed');
select t15.ok((select bool_and(invoice_id is null) from public.shipments where awb in ('Z0','Z1')), 'shipments stay unbilled');
select t15.expect_fail($$update public.shipments set invoice_id = (select id from t15.inv where k = 'inv1') where awb = 'Z0'$$,
  'user cannot set invoice_id directly', '{42501}');
update public.shipments set amount = 30 where awb = 'Z0';
update public.clients set is_gst = false where name = 'C1';
select t15.ok((select public.create_invoice((select c1 from t15.c), current_date - 100, current_date - 100) is not null), 'invoice allowed once amount > 0');
reset role;
select t15.expect_fail($$update public.shipments set amount = 0 where awb = 'Z0'$$, 'billed shipment amount cannot drop to ₹0', '{23514,P0001,42501}');
select t15.expect_fail($$insert into public.shipments (owner_id, client_id, awb, weight, amount, invoice_id)
  select '00000000-0000-0000-0000-0000000000c1', c1, 'Z2', 1, 0, (select invoice_id from public.shipments where awb = 'Z0') from t15.c$$,
  'DB constraint: ₹0 shipment can never carry an invoice', '{23514}');

do $$ begin raise notice 'ALL TESTS PASSED'; end $$;
rollback;
