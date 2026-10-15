-- =====================================================================
-- EntrySetu V1 — Editable Bill To Name tests. DEVELOPMENT ONLY (zfvnqcyqxxipjaugkmvf).
-- Run AFTER migration_2026_10_15_invoice_bill_to_name.sql. One transaction,
-- ROLLED BACK at the end: no test data kept, no real invoice numbers used.
-- Last notice: "ALL BILL TO NAME TESTS PASSED".
-- =====================================================================
begin;
create schema tbt;
grant usage on schema tbt to authenticated, service_role;
create function tbt.expect_fail(q text, label text, codes text[], msg_like text default null)
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
create function tbt.ok(cond boolean, label text) returns void language plpgsql as $$
begin if cond is true then raise notice 'PASS %', label; else raise exception 'FAIL: % (got %)', label, cond; end if; end $$;
create function tbt.as_user(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
end $$;
-- save helper: header only, lines/charges re-sent unchanged from the stored draft
create function tbt.save(p_id uuid, p_header jsonb) returns public.invoices language sql as $$
  select public.save_invoice_draft(p_id, p_header,
    (select jsonb_agg(jsonb_build_object('shipment_id', shipment_id, 'weight', weight, 'rate', rate,
                                         'amount', amount, 'declared_value', declared_value) order by position)
       from public.invoice_lines where invoice_id = p_id),
    coalesce((select jsonb_agg(jsonb_build_object('code', code, 'label', label, 'mode', mode, 'base', base, 'value', value) order by position)
       from public.invoice_charges where invoice_id = p_id), '[]'::jsonb))
$$;
grant execute on all functions in schema tbt to authenticated, service_role;

create table tbt.inv_before as select * from public.invoices;
create table tbt.client_before as select * from public.clients;

-- A. Column, constraint and privileges
do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'invoices' and column_name = 'bill_to_name_custom') then
    raise exception 'FAIL: bill_to_name_custom missing'; end if;
  if exists (select 1 from public.invoices where bill_to_name_custom) and not exists (select 1 from tbt.inv_before) then
    raise exception 'FAIL: unexpected custom rows'; end if;
  if has_table_privilege('authenticated', 'public.invoices', 'UPDATE') or has_column_privilege('authenticated', 'public.invoices', 'bill_to_name', 'UPDATE') then
    raise exception 'FAIL: sellers can update invoices directly'; end if;
  if has_function_privilege('authenticated', 'public.invoice_recalc(uuid)', 'EXECUTE') then raise exception 'FAIL: recalc exposed'; end if;
  if has_function_privilege('anon', 'public.save_invoice_draft(uuid, jsonb, jsonb, jsonb)', 'EXECUTE')
     or has_function_privilege('anon', 'public.reissue_invoice(uuid, public.invoice_kind)', 'EXECUTE') then raise exception 'FAIL: anon can run RPCs'; end if;
  if not has_function_privilege('authenticated', 'public.save_invoice_draft(uuid, jsonb, jsonb, jsonb)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.reissue_invoice(uuid, public.invoice_kind)', 'EXECUTE') then raise exception 'FAIL: sellers lost RPC access'; end if;
  raise notice 'PASS column, constraint and privileges';
end $$;

-- B. Two sellers, one client each
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
 ('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-0000000b7aa1','authenticated','authenticated','tbt-a@test.local','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-0000000b7bb1','authenticated','authenticated','tbt-b@test.local','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
update public.profiles set state = 'Maharashtra', gstin = '27ABCDE1234F1Z5' where id = '00000000-0000-0000-0000-0000000b7aa1';
update public.profiles set state = 'Karnataka', gstin = null where id = '00000000-0000-0000-0000-0000000b7bb1';

set local role authenticated;
select tbt.as_user('00000000-0000-0000-0000-0000000b7aa1');
insert into public.clients (name, state, is_gst) values ('TBT TRADERS', 'Maharashtra', true);
insert into public.shipments (client_id, awb, ship_date, destination, weight)
select c.id, x.awb, current_date - 2, 'MUMBAI', 1 from public.clients c, (values ('TBT1'), ('TBT2')) x(awb) where c.name = 'TBT TRADERS';
update public.shipments set amount = 100 where awb in ('TBT1', 'TBT2');
select tbt.as_user('00000000-0000-0000-0000-0000000b7bb1');
insert into public.clients (name, state, is_gst) values ('TBT B CLIENT', 'Karnataka', false);
insert into public.shipments (client_id, awb, ship_date, destination, weight)
select id, 'TBTB1', current_date - 2, 'MYSURU', 1 from public.clients where name = 'TBT B CLIENT';
update public.shipments set amount = 90 where awb = 'TBTB1';
reset role;
create table tbt.c as select
  (select id from public.clients where name = 'TBT TRADERS') a_c, (select id from public.clients where name = 'TBT B CLIENT') b_c;
create table tbt.ids (k text primary key, id uuid);
grant select on tbt.c to authenticated, service_role;
grant select, insert, update on tbt.ids to authenticated, service_role;

-- C. New draft defaults to the client's current name, not custom
set local role authenticated;
select tbt.as_user('00000000-0000-0000-0000-0000000b7aa1');
insert into tbt.ids select 'd1', public.create_invoice_draft((select a_c from tbt.c), current_date - 30, current_date);
create temp view d1 as select * from public.invoices where id = (select id from tbt.ids where k = 'd1');
select tbt.ok((select bill_to_name = 'TBT TRADERS' and not bill_to_name_custom from d1), 'new draft defaults to client name');
create temp table tot as select subtotal, charges_total, taxable_value, cgst, sgst, igst, total, gst_rate, tax_mode, kind, client_id
  from public.invoices where id = (select id from tbt.ids where k = 'd1');

-- D. Edit on a draft: trimmed, spaces collapsed, uppercased, custom
select tbt.save((select id from tbt.ids where k = 'd1'), '{"bill_to_name": "  Jai   Balaji  traders "}');
select tbt.ok((select bill_to_name = 'JAI BALAJI TRADERS' and bill_to_name_custom from public.invoices where id = (select id from tbt.ids where k = 'd1')),
              'draft name saved (trimmed, uppercased, custom)');
select tbt.ok((select (subtotal, charges_total, taxable_value, cgst, sgst, igst, total, gst_rate, tax_mode, kind, client_id)
                    = (select subtotal, charges_total, taxable_value, cgst, sgst, igst, total, gst_rate, tax_mode, kind, client_id from tot)
               from public.invoices where id = (select id from tbt.ids where k = 'd1')), 'totals, GST, type and client unchanged by rename');
select tbt.ok((select name = 'TBT TRADERS' from public.clients where id = (select a_c from tbt.c)), 'client master name unchanged');
select tbt.ok((select count(*) = 2 from public.shipments where draft_invoice_id = (select id from tbt.ids where k = 'd1')
               and owner_id = '00000000-0000-0000-0000-0000000b7aa1'), 'shipments still reserved by same seller');

-- E. Blank / whitespace / null rejected; stored name untouched
select tbt.expect_fail($$select tbt.save((select id from tbt.ids where k = 'd1'), '{"bill_to_name": ""}')$$, 'empty name rejected', '{P0001}', '%cannot be blank%');
select tbt.expect_fail($$select tbt.save((select id from tbt.ids where k = 'd1'), '{"bill_to_name": "   \t  "}')$$, 'whitespace name rejected', '{P0001}', '%cannot be blank%');
select tbt.expect_fail($$select tbt.save((select id from tbt.ids where k = 'd1'), '{"bill_to_name": null}')$$, 'null name rejected', '{P0001}', '%cannot be blank%');
select tbt.expect_fail($$select tbt.save((select id from tbt.ids where k = 'd1'), jsonb_build_object('bill_to_name', repeat('A', 201)))$$, 'over-long name rejected', '{P0001}', '%too long%');
select tbt.ok((select bill_to_name = 'JAI BALAJI TRADERS' from public.invoices where id = (select id from tbt.ids where k = 'd1')), 'failed saves left name intact');

-- F. Custom name survives later saves without the key, edits that trigger recalc, and a client rename
select tbt.save((select id from tbt.ids where k = 'd1'), '{"notes": "second save", "gst_rate": 12}');
select public.save_invoice_draft((select id from tbt.ids where k = 'd1'), '{}',
  (select jsonb_agg(jsonb_build_object('shipment_id', shipment_id, 'weight', weight, 'rate', rate, 'amount', 150)) from public.invoice_lines where invoice_id = (select id from tbt.ids where k = 'd1')),
  '[{"code":"fuel","mode":"percent","base":"subtotal","value":10}]');
select tbt.ok((select bill_to_name = 'JAI BALAJI TRADERS' and bill_to_name_custom and subtotal = 300 and charges_total = 30 and gst_rate = 12
               from public.invoices where id = (select id from tbt.ids where k = 'd1')), 'custom name kept through recalculation and later saves');
update public.clients set name = 'TBT TRADERS NEW' where id = (select a_c from tbt.c);
select tbt.save((select id from tbt.ids where k = 'd1'), '{}');
select tbt.ok((select bill_to_name = 'JAI BALAJI TRADERS' from public.invoices where id = (select id from tbt.ids where k = 'd1')), 'custom name kept after client rename');

-- G. Typing the client's current name clears the custom flag (draft follows the client again)
select tbt.save((select id from tbt.ids where k = 'd1'), '{"bill_to_name": "tbt traders new"}');
select tbt.ok((select bill_to_name = 'TBT TRADERS NEW' and not bill_to_name_custom from public.invoices where id = (select id from tbt.ids where k = 'd1')), 'client name -> not custom');
update public.clients set name = 'TBT TRADERS' where id = (select a_c from tbt.c);
select tbt.save((select id from tbt.ids where k = 'd1'), '{}');
select tbt.ok((select bill_to_name = 'TBT TRADERS' from public.invoices where id = (select id from tbt.ids where k = 'd1')), 'non-custom draft follows client rename (existing rule)');
select tbt.save((select id from tbt.ids where k = 'd1'), '{"bill_to_name": "Jai Balaji Traders"}');

-- H. Tenant isolation: seller B cannot rename seller A's draft
select tbt.as_user('00000000-0000-0000-0000-0000000b7bb1');
select tbt.expect_fail($$select public.save_invoice_draft((select id from tbt.ids where k = 'd1'), '{"bill_to_name": "HACKED"}', '[]', '[]')$$,
                       'other seller cannot rename draft', '{P0001}', '%Draft not found%');
select tbt.ok((select count(*) = 0 from public.invoices where id = (select id from tbt.ids where k = 'd1')), 'other seller cannot even see the draft');
select tbt.as_user('00000000-0000-0000-0000-0000000b7aa1');
select tbt.ok((select bill_to_name = 'JAI BALAJI TRADERS' from public.invoices where id = (select id from tbt.ids where k = 'd1')), 'name intact after foreign attempt');

-- I. Direct table writes blocked (frontend must use the RPC)
select tbt.expect_fail($$update public.invoices set bill_to_name = 'DIRECT' where id = (select id from tbt.ids where k = 'd1')$$, 'direct update blocked', '{42501}');
select tbt.expect_fail($$update public.invoices set bill_to_name_custom = false where id = (select id from tbt.ids where k = 'd1')$$, 'direct flag update blocked', '{42501}');

-- J. Finalize: issued invoice carries the custom name and is frozen
select public.finalize_invoice((select id from tbt.ids where k = 'd1'));
select tbt.ok((select status = 'issued' and bill_to_name = 'JAI BALAJI TRADERS' and invoice_no is not null from public.invoices where id = (select id from tbt.ids where k = 'd1')),
              'issued invoice shows the edited name');
select tbt.expect_fail($$select tbt.save((select id from tbt.ids where k = 'd1'), '{"bill_to_name": "LATE CHANGE"}')$$, 'RPC rename of issued invoice blocked', '{P0001}', '%Draft not found%');
reset role;
select tbt.expect_fail($$update public.invoices set bill_to_name = 'X' where id = (select id from tbt.ids where k = 'd1')$$, 'owner rename of issued blocked', '{P0001,42501}');
select tbt.expect_fail($$update public.invoices set bill_to_name_custom = false where id = (select id from tbt.ids where k = 'd1')$$, 'owner flag change on issued blocked', '{P0001}');
set local role service_role;
select tbt.expect_fail($$update public.invoices set bill_to_name = 'X' where id = (select id from tbt.ids where k = 'd1')$$, 'service role rename of issued blocked', '{P0001,42501}');
reset role;
-- invoice_recalc refuses non-drafts, so it can never refresh an issued name
select tbt.expect_fail($$select public.invoice_recalc((select id from tbt.ids where k = 'd1'))$$, 'recalc on issued blocked', '{P0001}', '%already finalized%');

-- K. Cancel: name frozen; reissue inherits it as custom
set local role authenticated;
select tbt.as_user('00000000-0000-0000-0000-0000000b7aa1');
select public.cancel_invoice((select id from tbt.ids where k = 'd1'), 'name test');
select tbt.ok((select status = 'cancelled' and bill_to_name = 'JAI BALAJI TRADERS' from public.invoices where id = (select id from tbt.ids where k = 'd1')), 'cancelled keeps name');
reset role;
select tbt.expect_fail($$update public.invoices set bill_to_name = 'X' where id = (select id from tbt.ids where k = 'd1')$$, 'rename of cancelled blocked', '{P0001,42501}');
set local role authenticated;
select tbt.as_user('00000000-0000-0000-0000-0000000b7aa1');
insert into tbt.ids select 'r1', public.reissue_invoice((select id from tbt.ids where k = 'd1'));
select tbt.ok((select bill_to_name = 'JAI BALAJI TRADERS' and bill_to_name_custom and status = 'draft' and reissue_of = (select id from tbt.ids where k = 'd1')
                      and client_id = (select a_c from tbt.c)
               from public.invoices where id = (select id from tbt.ids where k = 'r1')), 'reissued draft inherits saved Bill To Name');
select tbt.save((select id from tbt.ids where k = 'r1'), '{"notes": "reissue save"}');
select tbt.ok((select bill_to_name = 'JAI BALAJI TRADERS' from public.invoices where id = (select id from tbt.ids where k = 'r1')), 'inherited name kept after save');
select tbt.save((select id from tbt.ids where k = 'r1'), '{"bill_to_name": "Jai Balaji Traders Pvt Ltd"}');
select tbt.ok((select bill_to_name = 'JAI BALAJI TRADERS PVT LTD' from public.invoices where id = (select id from tbt.ids where k = 'r1')), 'reissued draft name editable');
select tbt.ok((select bill_to_name = 'JAI BALAJI TRADERS' from public.invoices where id = (select id from tbt.ids where k = 'd1')), 'editing reissue leaves cancelled invoice name untouched');

-- L. Reissue of an invoice whose name was the client name (not custom) still inherits that saved name
select tbt.as_user('00000000-0000-0000-0000-0000000b7bb1');
insert into tbt.ids select 'b1', public.create_invoice_draft((select b_c from tbt.c), current_date - 30, current_date);
select public.finalize_invoice((select id from tbt.ids where k = 'b1'));
select public.cancel_invoice((select id from tbt.ids where k = 'b1'), 'test');
update public.clients set name = 'TBT B RENAMED' where id = (select b_c from tbt.c);
insert into tbt.ids select 'b2', public.reissue_invoice((select id from tbt.ids where k = 'b1'));
select tbt.ok((select bill_to_name = 'TBT B CLIENT' from public.invoices where id = (select id from tbt.ids where k = 'b2')), 'reissue keeps cancelled name even after client rename');
select tbt.ok((select bill_to_name = 'TBT B CLIENT' from public.invoices where id = (select id from tbt.ids where k = 'b1')), 'cancelled invoice keeps original name');

-- M. Discard still works on a renamed draft; no number used
select public.discard_invoice_draft((select id from tbt.ids where k = 'b2'));
select tbt.ok((select count(*) = 0 from public.invoices where id = (select id from tbt.ids where k = 'b2')), 'renamed draft discarded');

-- N. Existing data untouched
reset role;
select tbt.ok((select count(*) = 0 from (select * from tbt.inv_before except select * from public.invoices) d), 'existing invoices unchanged');
select tbt.ok((select count(*) = 0 from (select * from tbt.client_before except select * from public.clients) d), 'existing clients unchanged');

do $$ begin raise notice 'ALL BILL TO NAME TESTS PASSED'; end $$;
rollback;
