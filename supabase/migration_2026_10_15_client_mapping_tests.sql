-- =====================================================================
-- EntrySetu V2 — Phase 1 security tests: client rename + Excel alias mappings,
-- raw Excel client name, invoice bill-to snapshots. DEVELOPMENT ONLY. Run AFTER
-- migration_2026_10_15_client_mapping.sql. One transaction, ROLLED BACK —
-- leaves no test data. A blocked action must fail with the EXACT SQLSTATE.
-- Last notice: "ALL CLIENT MAPPING TESTS PASSED".
-- =====================================================================
begin;
create schema tcm;
grant usage on schema tcm to authenticated;
create function tcm.expect_fail(q text, label text, codes text[], msg_like text default null)
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
create function tcm.ok(cond boolean, label text) returns void language plpgsql as $$
begin if cond is true then raise notice 'PASS %', label; else raise exception 'FAIL: % (got %)', label, cond; end if; end $$;
create function tcm.as_user(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
end $$;
grant execute on all functions in schema tcm to authenticated;

-- A. Privilege catalogue
do $$ begin
  if not has_table_privilege('authenticated','public.clients','DELETE') then raise exception 'FAIL: existing client DELETE was removed'; end if;
  if has_table_privilege('anon','public.client_name_mappings','SELECT') then raise exception 'FAIL: anon can read mappings'; end if;
  if has_column_privilege('authenticated','public.client_name_mappings','owner_id','INSERT')
     or has_column_privilege('authenticated','public.client_name_mappings','owner_id','UPDATE')
     or has_column_privilege('authenticated','public.client_name_mappings','alias_norm','INSERT')
     or has_column_privilege('authenticated','public.client_name_mappings','alias_norm','UPDATE') then
    raise exception 'FAIL: owner_id/alias_norm writable'; end if;
  if has_column_privilege('authenticated','public.shipments','source_client_name','UPDATE') then raise exception 'FAIL: raw name updatable'; end if;
  if not has_column_privilege('authenticated','public.shipments','source_client_name','INSERT') then raise exception 'FAIL: raw name not insertable'; end if;
  if has_table_privilege('authenticated','public.invoices','INSERT') or has_table_privilege('authenticated','public.invoices','UPDATE')
     or has_column_privilege('authenticated','public.invoices','bill_to_name','UPDATE') then
    raise exception 'FAIL: sellers can write invoices'; end if;
  if exists (select 1 from public.invoices where bill_to_name is null) then raise exception 'FAIL: backfill left invoices without a snapshot'; end if;
  raise notice 'PASS privileges, delete unchanged, backfill complete';
end $$;

-- B. Two test sellers (trial profiles created by the existing signup trigger)
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
 ('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-0000000c0aa1','authenticated','authenticated','tcm-a@test.local','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-0000000c0bb1','authenticated','authenticated','tcm-b@test.local','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
create table tcm.inv_before as select id, invoice_no, total, cgst, sgst, igst from public.invoices;
create table tcm.amt_before as select id, amount, invoice_id from public.shipments;
create table tcm.snap_before as select id, bill_to_name, bill_to_gstin, bill_to_state from public.invoices;

set local role authenticated;
select tcm.as_user('00000000-0000-0000-0000-0000000c0aa1');
insert into public.clients (name, is_gst) values ('abc traders', true), ('ABC TRADERS', false), ('A KEEP', false), ('A EMPTY', true);
select tcm.as_user('00000000-0000-0000-0000-0000000c0bb1');
insert into public.clients (name) values ('B ONE');
reset role;
create table tcm.c as select
 (select id from public.clients where name='abc traders') a_gst, (select id from public.clients where name='ABC TRADERS') a_ng,
 (select id from public.clients where name='A KEEP') a_keep,
 (select id from public.clients where name='A EMPTY') a_empty, (select id from public.clients where name='B ONE') b_one;
grant select on tcm.c to authenticated;
-- C. Mappings: create, normalise, duplicates on INSERT and UPDATE, no overwrite
set local role authenticated;
select tcm.as_user('00000000-0000-0000-0000-0000000c0aa1');
insert into public.client_name_mappings (raw_name, client_id) select '  Abc   Trd  ', a_ng from tcm.c;
select tcm.ok((select alias_norm = 'abc trd' and raw_name = 'Abc Trd' from public.client_name_mappings), 'alias normalised');
insert into public.client_name_mappings (raw_name, client_id) select 'ABC T', a_ng from tcm.c;
select tcm.ok((select count(*) = 2 from public.client_name_mappings where client_id = (select a_ng from tcm.c)), 'many raw names -> one client');
select tcm.expect_fail($$insert into public.client_name_mappings (raw_name, client_id) select 'abc  TRD', a_gst from tcm.c$$, 'duplicate alias on INSERT', '{23505}');
select tcm.expect_fail($$update public.client_name_mappings set raw_name = 'ABC TRD' where alias_norm = 'abc t'$$, 'duplicate alias on UPDATE', '{23505}');
select tcm.ok((select client_id = (select a_ng from tcm.c) from public.client_name_mappings where alias_norm = 'abc trd'), 'existing mapping not overwritten');
select tcm.expect_fail($$insert into public.client_name_mappings (raw_name, client_id) values ('x', null)$$, 'client required', '{23502}');
select tcm.expect_fail($$insert into public.client_name_mappings (raw_name, client_id) select '   ', a_ng from tcm.c$$, 'empty name rejected', '{23514,P0001}');
update public.client_name_mappings set client_id = (select a_gst from tcm.c) where alias_norm = 'abc t';
select tcm.ok((select client_id = (select a_gst from tcm.c) from public.client_name_mappings where alias_norm = 'abc t'), 'mapping re-pointed by owner');

-- D. Tenant isolation / spoofing
select tcm.expect_fail($$insert into public.client_name_mappings (raw_name, client_id) select 'steal', b_one from tcm.c$$, 'cannot map to other seller client', '{23503}');
select tcm.expect_fail($$insert into public.client_name_mappings (owner_id, raw_name, client_id) select '00000000-0000-0000-0000-0000000c0bb1', 'spoof', a_ng from tcm.c$$, 'owner_id not writable', '{42501}');
select tcm.expect_fail($$insert into public.client_name_mappings (alias_norm, raw_name, client_id) select 'zz', 'spoof', a_ng from tcm.c$$, 'alias_norm not writable', '{42501}');
select tcm.as_user('00000000-0000-0000-0000-0000000c0bb1');
select tcm.ok((select count(*) = 0 from public.client_name_mappings), 'B cannot read A mappings');
update public.client_name_mappings set raw_name = 'hacked';
delete from public.client_name_mappings;
delete from public.clients where id = (select a_empty from tcm.c);
reset role;
select tcm.ok((select count(*) = 2 from public.client_name_mappings where owner_id = '00000000-0000-0000-0000-0000000c0aa1' and raw_name <> 'hacked'), 'A mappings untouched by B');
select tcm.ok((select count(*) = 1 from public.clients where name = 'A EMPTY'), 'A client untouched by B');

-- E. Raw Excel name: insert-only
set local role authenticated;
select tcm.as_user('00000000-0000-0000-0000-0000000c0aa1');
insert into public.shipments (client_id, awb, destination, weight, source_client_name) select a_keep, 'TCM1', 'Mumbai', 1, 'a keep pvt' from tcm.c;
select tcm.ok((select source_client_name = 'a keep pvt' from public.shipments where awb = 'TCM1'), 'raw name stored');
select tcm.expect_fail($$update public.shipments set source_client_name = 'changed' where awb = 'TCM1'$$, 'raw name not updatable', '{42501}');

-- F. Rename keeps Excel name; invoice snapshot frozen
select tcm.as_user('00000000-0000-0000-0000-0000000c0aa1');
update public.shipments set amount = 120 where awb = 'TCM1';
select tcm.ok((select public.create_invoice((select a_keep from tcm.c), current_date - 30, current_date) is not null), 'invoice issued');
select tcm.ok((select bill_to_name = 'A KEEP' from public.invoices where client_id = (select a_keep from tcm.c)), 'snapshot taken at issue');
create temp table tcm_inv as select id, invoice_no, total from public.invoices where client_id = (select a_keep from tcm.c);
update public.clients set name = 'JAI BALAJI TRADERS' where id = (select a_keep from tcm.c);
insert into public.client_name_mappings (raw_name, client_id) select 'A KEEP', a_keep from tcm.c;
select tcm.ok((select bill_to_name = 'A KEEP' from public.invoices where client_id = (select a_keep from tcm.c)), 'renamed client: invoice keeps original name');
select tcm.ok((select client_id = (select a_keep from tcm.c) from public.client_name_mappings where alias_norm = 'a keep'), 'old name maps to same client_id');
select tcm.ok((select count(*) = 0 from (select id, invoice_no, total from public.invoices where client_id = (select a_keep from tcm.c) except select * from tcm_inv) d), 'invoice number and total unchanged');
reset role;
select tcm.expect_fail($$update public.invoices set bill_to_name = 'CHANGED' where client_id = (select a_keep from tcm.c)$$, 'snapshot frozen even for owner role', '{42501}');

-- G. Existing Delete still works; mappings never dangle; expired plan read-only
set local role authenticated;
select tcm.as_user('00000000-0000-0000-0000-0000000c0aa1');
insert into public.client_name_mappings (raw_name, client_id) select 'EMPTY ALIAS', a_empty from tcm.c;
delete from public.clients where id = (select a_empty from tcm.c);
select tcm.ok((select count(*) = 0 from public.clients where id = (select a_empty from tcm.c)), 'existing Delete still works');
select tcm.ok((select count(*) = 0 from public.client_name_mappings where alias_norm = 'empty alias'), 'mapping removed with deleted client');
select tcm.expect_fail($$delete from public.clients where id = (select a_keep from tcm.c)$$, 'client with shipments/invoices still protected', '{23503}');
reset role;
update public.profiles set trial_ends_at = now() - interval '1 day', plan = null where id = '00000000-0000-0000-0000-0000000c0aa1';
set local role authenticated;
select tcm.as_user('00000000-0000-0000-0000-0000000c0aa1');
select tcm.ok((select count(*) >= 1 from public.client_name_mappings), 'expired seller can read mappings');
select tcm.expect_fail($$insert into public.client_name_mappings (raw_name, client_id) select 'late', a_gst from tcm.c$$, 'expired: no new mapping', '{42501}');
reset role;

-- H. Financial history unchanged
select tcm.ok((select count(*) = 0 from (select * from tcm.inv_before except select id, invoice_no, total, cgst, sgst, igst from public.invoices) d)
          and (select count(*) = (select count(*) from tcm.inv_before) from public.invoices), 'invoices unchanged');
select tcm.ok((select count(*) = 0 from (select * from tcm.amt_before except select id, amount, invoice_id from public.shipments) d), 'existing shipment amounts and billing unchanged');

select tcm.ok((select count(*) = 0 from (select * from tcm.snap_before except select id, bill_to_name, bill_to_gstin, bill_to_state from public.invoices) d), 'existing invoice snapshots unchanged');

do $$ begin raise notice 'ALL CLIENT MAPPING TESTS PASSED'; end $$;
rollback;
