-- =====================================================================
-- EntrySetu V1 — Final Invoice Editor tests. DEVELOPMENT ONLY (zfvnqcyqxxipjaugkmvf).
-- Run AFTER migration_2026_10_15_invoice_editor_part1.sql and
-- migration_2026_10_15_invoice_editor.sql. One transaction, ROLLED BACK at the end:
-- leaves no test data and consumes no real invoice numbers.
-- A blocked action must fail with the EXPECTED SQLSTATE (and message where it is
-- our own rule). Last notice: "ALL INVOICE EDITOR TESTS PASSED".
-- =====================================================================
begin;
create schema tie;
grant usage on schema tie to authenticated;
create function tie.expect_fail(q text, label text, codes text[], msg_like text default null)
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
create function tie.ok(cond boolean, label text) returns void language plpgsql as $$
begin if cond is true then raise notice 'PASS %', label; else raise exception 'FAIL: % (got %)', label, cond; end if; end $$;
create function tie.as_user(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
end $$;
grant execute on all functions in schema tie to authenticated;

-- Snapshots of existing data (must be unchanged at the end)
create table tie.inv_before as select id, status, invoice_no, subtotal, cgst, sgst, igst, total, bill_to_name from public.invoices;
create table tie.ship_before as select id, amount, weight, invoice_id from public.shipments;
create table tie.rc_before as select * from public.rate_cards;

-- A. Privileges
do $$ begin
  if has_table_privilege('anon', 'public.invoice_lines', 'SELECT') or has_table_privilege('anon', 'public.invoice_charges', 'SELECT') then
    raise exception 'FAIL: anon can read lines/charges'; end if;
  if has_table_privilege('authenticated', 'public.invoice_lines', 'INSERT') or has_table_privilege('authenticated', 'public.invoice_lines', 'UPDATE')
     or has_table_privilege('authenticated', 'public.invoice_lines', 'DELETE') or has_table_privilege('authenticated', 'public.invoice_charges', 'INSERT')
     or has_table_privilege('authenticated', 'public.invoice_charges', 'UPDATE') or has_table_privilege('authenticated', 'public.invoice_charges', 'DELETE') then
    raise exception 'FAIL: sellers can write lines/charges directly'; end if;
  if has_table_privilege('authenticated', 'public.invoices', 'INSERT') or has_table_privilege('authenticated', 'public.invoices', 'UPDATE')
     or has_table_privilege('authenticated', 'public.invoices', 'DELETE') then raise exception 'FAIL: sellers can write invoices'; end if;
  if has_column_privilege('authenticated', 'public.shipments', 'draft_invoice_id', 'UPDATE')
     or has_column_privilege('authenticated', 'public.shipments', 'draft_invoice_id', 'INSERT') then raise exception 'FAIL: draft link writable'; end if;
  if has_function_privilege('authenticated', 'public.invoice_recalc(uuid)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.invoice_add_lines(uuid, uuid[])', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.invoice_tax_mode(uuid, uuid, public.invoice_kind)', 'EXECUTE') then
    raise exception 'FAIL: internal helpers executable by sellers'; end if;
  if has_function_privilege('anon', 'public.finalize_invoice(uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.create_invoice_draft(uuid, date, date, uuid[], date, public.invoice_kind)', 'EXECUTE') then
    raise exception 'FAIL: anon can run invoice functions'; end if;
  if not has_function_privilege('authenticated', 'public.save_invoice_draft(uuid, jsonb, jsonb, jsonb)', 'EXECUTE') then
    raise exception 'FAIL: sellers cannot save drafts'; end if;
  if exists (select 1 from public.invoices where taxable_value <> subtotal + charges_total) then raise exception 'FAIL: backfill taxable_value'; end if;
  raise notice 'PASS privileges and backfill';
end $$;

-- B. Two sellers. A: GST-registered in Maharashtra. B: no GSTIN, Karnataka.
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
 ('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-0000000e0aa1','authenticated','authenticated','tie-a@test.local','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-0000000e0bb1','authenticated','authenticated','tie-b@test.local','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
update public.profiles set state = 'Maharashtra', gstin = '27ABCDE1234F1Z5' where id = '00000000-0000-0000-0000-0000000e0aa1';
update public.profiles set state = 'Karnataka', gstin = null where id = '00000000-0000-0000-0000-0000000e0bb1';

set local role authenticated;
select tie.as_user('00000000-0000-0000-0000-0000000e0aa1');
insert into public.clients (name, state, is_gst) values ('TIE IN', 'Maharashtra', true), ('TIE OUT', 'Karnataka', true);
insert into public.shipments (client_id, awb, ship_date, destination, weight)
select c.id, x.awb, current_date - 2, 'MUMBAI', 1 from public.clients c,
  (values ('TIE1'), ('TIE2'), ('TIE3')) x(awb) where c.name = 'TIE IN';
insert into public.shipments (client_id, awb, ship_date, destination, weight)
select id, 'TIE4', current_date - 2, 'BENGALURU', 1 from public.clients where name = 'TIE OUT';
update public.shipments set amount = 100 where awb = 'TIE1';
update public.shipments set amount = 200 where awb = 'TIE2';
update public.shipments set amount = 300 where awb = 'TIE3';
update public.shipments set amount = 400 where awb = 'TIE4';
select tie.as_user('00000000-0000-0000-0000-0000000e0bb1');
insert into public.clients (name, state, is_gst) values ('TIE B', 'Karnataka', false);
insert into public.shipments (client_id, awb, ship_date, destination, weight)
select id, 'TIEB1', current_date - 2, 'MYSURU', 1 from public.clients where name = 'TIE B';
update public.shipments set amount = 90 where awb = 'TIEB1';
reset role;
create table tie.c as select
  (select id from public.clients where name = 'TIE IN') a_in, (select id from public.clients where name = 'TIE OUT') a_out,
  (select id from public.clients where name = 'TIE B') b_c,
  (select id from public.shipments where awb = 'TIE1') s1, (select id from public.shipments where awb = 'TIE2') s2,
  (select id from public.shipments where awb = 'TIE3') s3, (select id from public.shipments where awb = 'TIE4') s4,
  (select id from public.shipments where awb = 'TIEB1') sb, public.fy_label(current_date) fy;
create table tie.ids (k text primary key, id uuid);
grant select on tie.c to authenticated;
grant select, insert, update on tie.ids to authenticated;

-- C. Create draft (no number used, shipments reserved, lines copied)
set local role authenticated;
select tie.as_user('00000000-0000-0000-0000-0000000e0aa1');
insert into tie.ids select 'd1', public.create_invoice_draft((select a_in from tie.c), current_date - 30, current_date);
select tie.ok((select status = 'draft' and invoice_no is null and seq is null and kind = 'gst' and tax_mode = 'intra'
               and subtotal = 600 and total = 708 from public.invoices where id = (select id from tie.ids where k = 'd1')), 'draft created, GST intra, totals by DB');
select tie.ok((select count(*) = 3 from public.invoice_lines where invoice_id = (select id from tie.ids where k = 'd1')), '3 lines copied');
select tie.ok((select count(*) = 3 from public.shipments where draft_invoice_id = (select id from tie.ids where k = 'd1')), 'shipments reserved');

-- D. Direct writes blocked; reserved shipments protected; no double reservation
select tie.expect_fail($$insert into public.invoice_lines (owner_id, invoice_id, position, ship_date, awb, weight, rate, amount, original_weight, original_amount)
  select '00000000-0000-0000-0000-0000000e0aa1', id, 9, current_date, 'X', 1, 1, 1, 1, 1 from tie.ids where k = 'd1'$$, 'direct line insert', '{42501}');
select tie.expect_fail($$update public.invoices set total = 1$$, 'direct invoice update', '{42501}');
select tie.expect_fail($$update public.shipments set draft_invoice_id = null where awb = 'TIE1'$$, 'direct draft link update', '{42501}');
select tie.expect_fail($$delete from public.shipments where awb = 'TIE1'$$, 'reserved shipment delete', '{P0001}', '%draft invoice%');
select tie.expect_fail($$update public.shipments set amount = 5 where awb = 'TIE1'$$, 'reserved shipment edit', '{P0001}', '%draft invoice%');
select tie.expect_fail($$select public.create_invoice_draft((select a_in from tie.c), current_date - 30, current_date)$$, 'second draft cannot take same shipments', '{P0001}', 'No unbilled%');
select tie.expect_fail($$select public.create_invoice((select a_in from tie.c), current_date - 30, current_date)$$, 'legacy create_invoice cannot take reserved shipments', '{P0001}', '%draft invoice%');

-- E. Tenant isolation
select tie.as_user('00000000-0000-0000-0000-0000000e0bb1');
select tie.ok((select count(*) = 0 from public.invoice_lines) and (select count(*) = 0 from public.invoices where owner_id = '00000000-0000-0000-0000-0000000e0aa1'), 'B cannot read A drafts/lines');
select tie.expect_fail($$select public.save_invoice_draft((select id from tie.ids where k = 'd1'), '{}', '[]', '[]')$$, 'B cannot save A draft', '{P0001}', 'Draft not found%');
select tie.expect_fail($$select public.finalize_invoice((select id from tie.ids where k = 'd1'))$$, 'B cannot finalize A draft', '{P0001}', 'Draft not found%');
select tie.expect_fail($$select public.discard_invoice_draft((select id from tie.ids where k = 'd1'))$$, 'B cannot discard A draft', '{P0001}', 'Draft not found%');
select tie.expect_fail($$select public.create_invoice_draft((select b_c from tie.c), current_date - 30, current_date, array[(select s4 from tie.c)])$$, 'B cannot reserve A shipment', '{P0001}', '%not available%');
select tie.expect_fail($$select public.create_invoice_draft((select a_in from tie.c), current_date - 30, current_date)$$, 'B cannot bill A client', '{P0001}', 'Client not found%');

-- F. Invoice type is the seller's choice (GSTIN-based locking NOT enforced yet)
-- Seller B has no GSTIN but may still create a GST draft; seller A has a GSTIN
-- but may still choose Non-GST. Non-GST never carries tax.
select tie.as_user('00000000-0000-0000-0000-0000000e0bb1');
insert into tie.ids select 'df', public.create_invoice_draft((select b_c from tie.c), current_date - 30, current_date, null, current_date, 'gst');
select tie.ok((select kind = 'gst' and tax_mode = 'intra' and cgst = 8.10 and sgst = 8.10 and total = 106.20 from public.invoices where id = (select id from tie.ids where k = 'df')), 'seller without GSTIN can create GST draft');
select public.discard_invoice_draft((select id from tie.ids where k = 'df'));
select tie.as_user('00000000-0000-0000-0000-0000000e0aa1');

-- G. Edit lines + charges; DB recalculates; shipments and rate cards untouched
-- Lines: TIE1 amount 100 -> 150 (weight 1 -> 1.5, declared 10000), TIE2 unchanged, TIE3 removed.
-- Charges: Fuel 10% of subtotal (35), Packing ₹50, FOV 0.5% of declared (50) => 135.
-- Taxable 485; CGST 9% 43.65 + SGST 43.65; round-off -0.30 => 572.00
select public.save_invoice_draft((select id from tie.ids where k = 'd1'),
  jsonb_build_object('gst_rate', 18, 'round_off', -0.30, 'notes', 'test'),
  jsonb_build_array(
    jsonb_build_object('shipment_id', (select s1 from tie.c), 'weight', 1.5, 'rate', 150, 'amount', 150, 'declared_value', 10000),
    jsonb_build_object('shipment_id', (select s2 from tie.c), 'weight', 1, 'rate', 200, 'amount', 200)),
  '[{"code":"fuel","mode":"percent","base":"subtotal","value":10},
    {"code":"packing","mode":"fixed","value":50},
    {"code":"fov","mode":"percent","base":"declared_value","value":0.5}]'::jsonb);
select tie.ok((select subtotal = 350 and charges_total = 135 and taxable_value = 485 and cgst = 43.65 and sgst = 43.65
               and igst = 0 and round_off = -0.30 and total = 572.00 from public.invoices where id = (select id from tie.ids where k = 'd1')), 'totals recalculated by DB');
select tie.ok((select string_agg(label || '=' || amount, ',' order by position) = 'Fuel Surcharge=35.00,Packing=50.00,FOV=50.00'
               from public.invoice_charges where invoice_id = (select id from tie.ids where k = 'd1')), 'charge amounts and default labels');
select tie.ok((select original_amount = 100 and amount = 150 and original_weight = 1 and weight = 1.5 from public.invoice_lines where awb = 'TIE1'), 'line keeps original values');
select tie.ok((select amount = 100 and weight = 1 from public.shipments where awb = 'TIE1'), 'original shipment unchanged');
select tie.ok((select draft_invoice_id is null from public.shipments where awb = 'TIE3'), 'removed line releases shipment');

-- H. Validation
select tie.expect_fail($$select public.save_invoice_draft((select id from tie.ids where k = 'd1'), '{}',
  jsonb_build_array(jsonb_build_object('shipment_id', (select s1 from tie.c), 'weight', 1, 'rate', 0, 'amount', 0)), '[]')$$, 'zero line amount', '{P0001}', '%more than%');
select tie.expect_fail($$select public.save_invoice_draft((select id from tie.ids where k = 'd1'), '{}',
  jsonb_build_array(jsonb_build_object('shipment_id', (select s1 from tie.c), 'weight', 1, 'rate', 1, 'amount', 1)),
  '[{"code":"fov","mode":"percent","base":"declared_value","value":1}]')$$, 'FOV on declared value without declared value', '{P0001}', '%declared value%');
select tie.expect_fail($$select public.save_invoice_draft((select id from tie.ids where k = 'd1'), '{}',
  jsonb_build_array(jsonb_build_object('shipment_id', (select s1 from tie.c), 'weight', 1, 'rate', 1, 'amount', 1, 'declared_value', 5)),
  '[{"code":"fuel","mode":"percent","base":"declared_value","value":1}]')$$, 'declared base only for FOV', '{P0001}', '%Only FOV%');
select tie.expect_fail($$select public.save_invoice_draft((select id from tie.ids where k = 'd1'), '{}',
  jsonb_build_array(jsonb_build_object('shipment_id', (select s1 from tie.c), 'weight', 1, 'rate', 1, 'amount', 1)),
  '[{"code":"fuel","mode":"percent","value":150}]')$$, 'percent over 100', '{23514}');
select tie.expect_fail($$select public.save_invoice_draft((select id from tie.ids where k = 'd1'), '{"gst_rate":7}',
  jsonb_build_array(jsonb_build_object('shipment_id', (select s1 from tie.c), 'weight', 1, 'rate', 1, 'amount', 1)), '[]')$$, 'invalid GST rate', '{23514,P0001}');
select tie.expect_fail($$select public.save_invoice_draft((select id from tie.ids where k = 'd1'), '{"round_off":2}',
  jsonb_build_array(jsonb_build_object('shipment_id', (select s1 from tie.c), 'weight', 1, 'rate', 1, 'amount', 1)), '[]')$$, 'round-off over ₹0.99', '{23514}');
select tie.expect_fail($$select public.save_invoice_draft((select id from tie.ids where k = 'd1'), '{}',
  jsonb_build_array(jsonb_build_object('shipment_id', (select s4 from tie.c), 'weight', 1, 'rate', 1, 'amount', 1)), '[]')$$, 'cannot add other client shipment', '{P0001}', '%not available%');
-- Switching a GST-registered seller's draft to Non-GST is allowed (locking not
-- enforced yet) and drops the tax; switching back restores it.
select public.save_invoice_draft((select id from tie.ids where k = 'd1'), '{"kind":"nongst"}',
  (select jsonb_agg(jsonb_build_object('shipment_id', shipment_id, 'weight', weight, 'rate', rate, 'amount', amount, 'declared_value', declared_value))
     from public.invoice_lines where invoice_id = (select id from tie.ids where k = 'd1')),
  (select jsonb_agg(jsonb_build_object('code', code, 'label', label, 'mode', mode, 'base', base, 'value', value))
     from public.invoice_charges where invoice_id = (select id from tie.ids where k = 'd1')));
select tie.ok((select kind = 'nongst' and tax_mode = 'none' and cgst = 0 and sgst = 0 and igst = 0 and total = 484.70
               from public.invoices where id = (select id from tie.ids where k = 'd1')), 'GSTIN seller can switch to Non-GST, tax removed');
select public.save_invoice_draft((select id from tie.ids where k = 'd1'), '{"kind":"gst"}',
  (select jsonb_agg(jsonb_build_object('shipment_id', shipment_id, 'weight', weight, 'rate', rate, 'amount', amount, 'declared_value', declared_value))
     from public.invoice_lines where invoice_id = (select id from tie.ids where k = 'd1')),
  (select jsonb_agg(jsonb_build_object('code', code, 'label', label, 'mode', mode, 'base', base, 'value', value))
     from public.invoice_charges where invoice_id = (select id from tie.ids where k = 'd1')));
select tie.ok((select kind = 'gst' and total = 572.00 from public.invoices where id = (select id from tie.ids where k = 'd1')), 'switch back to GST restores totals');
select tie.ok((select total = 572.00 from public.invoices where id = (select id from tie.ids where k = 'd1')), 'failed saves left draft unchanged');

-- I. Finalize with automatic number
select public.finalize_invoice((select id from tie.ids where k = 'd1'));
select tie.ok((select status = 'issued' and seq is not null and fy = (select fy from tie.c)
               and invoice_no = public.format_invoice_no(s.prefix, s.fy, i.seq, s.fy_format, s.separator, s.pad) and total = 572.00
               from public.invoices i join public.invoice_series s on s.owner_id = i.owner_id and s.fy = i.fy and s.kind = i.kind
               where i.id = (select id from tie.ids where k = 'd1')), 'auto number assigned, total kept');
select tie.ok((select count(*) = 2 from public.shipments where invoice_id = (select id from tie.ids where k = 'd1') and draft_invoice_id is null), 'shipments billed');

-- I2. Regression: draft -> finalize hands shipments from draft_invoice_id to
--     invoice_id atomically, and the hand-over cannot be forged.
select tie.ok((select count(*) = 0 from public.shipments where draft_invoice_id = (select id from tie.ids where k = 'd1')), 'no shipment left reserved after finalize');
select tie.ok((select bool_and(s.invoice_id = l.invoice_id) and count(*) = 2
                 from public.invoice_lines l join public.shipments s on s.id = l.shipment_id
                where l.invoice_id = (select id from tie.ids where k = 'd1')), 'every invoice line shipment linked to the issued invoice');
reset role;
-- fresh draft for forgery checks (TIE3 was released from d1 in step G)
set local role authenticated;
select tie.as_user('00000000-0000-0000-0000-0000000e0aa1');
insert into tie.ids select 'dg', public.create_invoice_draft((select a_in from tie.c), current_date - 30, current_date);
reset role;
-- trusted role, flag NOT armed: cannot bill a reserved shipment directly
select tie.expect_fail($$update public.shipments set invoice_id = draft_invoice_id, draft_invoice_id = null
   where draft_invoice_id = (select id from tie.ids where k = 'dg')$$, 'hand-over without finalize blocked', '{P0001}', '%only be billed by finalizing%');
-- flag armed but target invoice still a draft (not issued): blocked
select set_config('entrysetu.finalizing', (select id::text from tie.ids where k = 'dg'), true);
select tie.expect_fail($$update public.shipments set invoice_id = draft_invoice_id, draft_invoice_id = null
   where draft_invoice_id = (select id from tie.ids where k = 'dg')$$, 'hand-over to non-issued invoice blocked', '{P0001}', '%only be billed by finalizing%');
-- flag armed for a different invoice: blocked
select set_config('entrysetu.finalizing', (select id::text from tie.ids where k = 'd1'), true);
select tie.expect_fail($$update public.shipments set invoice_id = (select id from tie.ids where k = 'd1'), draft_invoice_id = null
   where draft_invoice_id = (select id from tie.ids where k = 'dg')$$, 'move reserved shipment to another issued invoice blocked', '{P0001}', '%draft invoice%');
select set_config('entrysetu.finalizing', '', true);
-- seller cannot forge it either
set local role authenticated;
select tie.as_user('00000000-0000-0000-0000-0000000e0aa1');
select tie.expect_fail($$update public.shipments set invoice_id = draft_invoice_id, draft_invoice_id = null
   where draft_invoice_id = (select id from tie.ids where k = 'dg')$$, 'seller direct hand-over blocked', '{42501,P0001}');
select tie.ok(coalesce(current_setting('entrysetu.finalizing', true), '') = '', 'finalize flag disarmed after finalize');
-- discard (not finalize) so no extra invoice number is consumed and later tests see TIE3 unbilled
select public.discard_invoice_draft((select id from tie.ids where k = 'dg'));
select tie.ok((select draft_invoice_id is null and invoice_id is null from public.shipments where awb = 'TIE3'), 'forgery attempts left TIE3 untouched and released');

-- J. Issued invoice immutable for every role
select tie.expect_fail($$select public.save_invoice_draft((select id from tie.ids where k = 'd1'), '{}', '[]', '[]')$$, 'cannot save issued invoice', '{P0001}', 'Draft not found%');
select tie.expect_fail($$select public.discard_invoice_draft((select id from tie.ids where k = 'd1'))$$, 'cannot discard issued invoice', '{P0001}');
reset role;
select tie.expect_fail($$update public.invoices set total = 1 where id = (select id from tie.ids where k = 'd1')$$, 'owner role cannot edit issued invoice', '{P0001}', '%immutable%');
select tie.expect_fail($$delete from public.invoices where id = (select id from tie.ids where k = 'd1')$$, 'owner role cannot delete issued invoice', '{P0001}');
select tie.expect_fail($$update public.invoice_lines set amount = 1 where awb = 'TIE1'$$, 'owner role cannot edit issued line', '{P0001}');
select tie.expect_fail($$delete from public.invoice_charges where invoice_id = (select id from tie.ids where k = 'd1')$$, 'owner role cannot delete issued charge', '{P0001}');

-- K. Manual numbering + inter-state IGST
set local role authenticated;
select tie.as_user('00000000-0000-0000-0000-0000000e0aa1');
insert into tie.ids select 'd2', public.create_invoice_draft((select a_out from tie.c), current_date - 30, current_date);
select tie.ok((select tax_mode = 'inter' and igst = 72 and cgst = 0 and total = 472 from public.invoices where id = (select id from tie.ids where k = 'd2')), 'inter-state uses IGST');
select tie.expect_fail($$select public.save_invoice_draft((select id from tie.ids where k = 'd2'), '{"numbering":"manual","requested_invoice_no":"bad no!"}',
  jsonb_build_array(jsonb_build_object('shipment_id', (select s4 from tie.c), 'weight', 1, 'rate', 400, 'amount', 400)), '[]')$$, 'invalid manual number format', '{23514}');
select tie.expect_fail($$select public.save_invoice_draft((select id from tie.ids where k = 'd2'),
  jsonb_build_object('numbering', 'manual', 'requested_invoice_no', (select invoice_no from public.invoices where id = (select id from tie.ids where k = 'd1'))),
  jsonb_build_array(jsonb_build_object('shipment_id', (select s4 from tie.c), 'weight', 1, 'rate', 400, 'amount', 400)), '[]')$$, 'manual number already used', '{P0001}', '%already used%');
select public.save_invoice_draft((select id from tie.ids where k = 'd2'),
  jsonb_build_object('numbering', 'manual', 'requested_invoice_no',
    (select public.format_invoice_no(prefix, fy, next_number + 5, fy_format, separator, pad) from public.invoice_series
      where owner_id = '00000000-0000-0000-0000-0000000e0aa1' and kind = 'gst')),
  jsonb_build_array(jsonb_build_object('shipment_id', (select s4 from tie.c), 'weight', 1, 'rate', 400, 'amount', 400)), '[]');
select tie.expect_fail($$select public.finalize_invoice((select id from tie.ids where k = 'd2'))$$, 'manual number inside auto series blocked', '{P0001}', '%automatic series%');
select public.save_invoice_draft((select id from tie.ids where k = 'd2'), '{"numbering":"manual","requested_invoice_no":"OLD-SOFT-0099"}',
  jsonb_build_array(jsonb_build_object('shipment_id', (select s4 from tie.c), 'weight', 1, 'rate', 400, 'amount', 400)), '[]');
select public.finalize_invoice((select id from tie.ids where k = 'd2'));
select tie.ok((select status = 'issued' and invoice_no = 'OLD-SOFT-0099' and seq is null and numbering = 'manual'
               from public.invoices where id = (select id from tie.ids where k = 'd2')), 'manual number issued');

-- L. Cancel keeps number; reissue = new draft, new number, old number never reused
select public.cancel_invoice((select id from tie.ids where k = 'd1'), 'test correction');
select tie.ok((select status = 'cancelled' and invoice_no is not null and total = 572.00 from public.invoices where id = (select id from tie.ids where k = 'd1')), 'cancelled invoice keeps number and amounts');
select tie.ok((select count(*) = 2 from public.invoice_lines where invoice_id = (select id from tie.ids where k = 'd1')), 'cancelled lines kept for audit');
insert into tie.ids select 'd3', public.reissue_invoice((select id from tie.ids where k = 'd1'));
select tie.ok((select status = 'draft' and reissue_of = (select id from tie.ids where k = 'd1') and total = 572.00
               from public.invoices where id = (select id from tie.ids where k = 'd3')), 'reissue copies edits and charges');
select tie.expect_fail($$select public.reissue_invoice((select id from tie.ids where k = 'd1'))$$, 'only one active reissue', '{P0001}', '%already has%');
select tie.expect_fail($$select public.save_invoice_draft((select id from tie.ids where k = 'd3'),
  jsonb_build_object('numbering', 'manual', 'requested_invoice_no', (select invoice_no from public.invoices where id = (select id from tie.ids where k = 'd1'))),
  (select jsonb_agg(jsonb_build_object('shipment_id', shipment_id, 'weight', weight, 'rate', rate, 'amount', amount, 'declared_value', declared_value))
     from public.invoice_lines where invoice_id = (select id from tie.ids where k = 'd3')),
  (select jsonb_agg(jsonb_build_object('code', code, 'label', label, 'mode', mode, 'base', base, 'value', value))
     from public.invoice_charges where invoice_id = (select id from tie.ids where k = 'd3')))$$, 'cancelled number cannot be reused', '{P0001}', '%already used%');
select public.finalize_invoice((select id from tie.ids where k = 'd3'));
select tie.ok((select i3.invoice_no <> i1.invoice_no and i3.seq > i1.seq from public.invoices i1, public.invoices i3
               where i1.id = (select id from tie.ids where k = 'd1') and i3.id = (select id from tie.ids where k = 'd3')), 'reissue gets a new, higher number');
select tie.expect_fail($$update public.invoices set status = 'issued' where id = (select id from tie.ids where k = 'd1')$$, 'seller cannot un-cancel', '{42501}');
reset role;
select tie.expect_fail($$update public.invoices set status = 'issued', cancelled_at = null where id = (select id from tie.ids where k = 'd1')$$, 'owner role cannot un-cancel', '{P0001}', '%immutable%');
set local role authenticated;
select tie.as_user('00000000-0000-0000-0000-0000000e0aa1');

-- M. Series format (prefix, FY format, separator, padding)
select public.set_invoice_series_format((select fy from tie.c), 'gst', 'YY-YY', '-', 3);
insert into tie.ids select 'd4', public.create_invoice_draft((select a_in from tie.c), current_date - 30, current_date);
select public.finalize_invoice((select id from tie.ids where k = 'd4'));
select tie.ok((select invoice_no = s.prefix || '-' || substr(s.fy, 3, 2) || '-' || right(s.fy, 2) || '-' || lpad(i.seq::text, 3, '0')
               from public.invoices i join public.invoice_series s on s.owner_id = i.owner_id and s.fy = i.fy and s.kind = i.kind
               where i.id = (select id from tie.ids where k = 'd4')), 'custom series format applied');
select tie.expect_fail($$select public.set_invoice_series_format((select fy from tie.c), 'gst', 'XX', '/', 4)$$, 'invalid FY format', '{P0001}');

-- Q. Existing create_invoice / cancel_invoice keep working with the new triggers,
--    and share one gap-free number sequence with finalize_invoice.
insert into public.shipments (client_id, awb, ship_date, destination, weight)
select (select a_in from tie.c), 'TIE5', current_date - 2, 'MUMBAI', 1;
update public.shipments set amount = 50 where awb = 'TIE5';
insert into tie.ids select 'L1', public.create_invoice((select a_in from tie.c), current_date - 30, current_date);
select tie.ok((select status = 'issued' and numbering = 'auto' and charges_total = 0 and taxable_value = 50 and tax_mode = 'intra'
               and gst_rate = 18 and cgst = 4.50 and sgst = 4.50 and total = 59 and round_off = 0 and finalized_at is not null
               and bill_to_name = 'TIE IN' and invoice_no = 'GST/' || fy || '/' || lpad(seq::text, 4, '0')
               from public.invoices where id = (select id from tie.ids where k = 'L1')), 'legacy create_invoice fills new columns + snapshot');
insert into public.shipments (client_id, awb, ship_date, destination, weight)
select (select a_in from tie.c), x, current_date - 2, 'MUMBAI', 1 from unnest(array['TIE6','TIE7','TIE8','TIE9','TIE10']) x;
update public.shipments set amount = 10 where awb in ('TIE6','TIE7','TIE8','TIE9','TIE10');
insert into tie.ids select 'd5', public.create_invoice_draft((select a_in from tie.c), current_date - 30, current_date,
  array[(select id from public.shipments where awb = 'TIE6')]);
select public.finalize_invoice((select id from tie.ids where k = 'd5'));
select tie.ok((select count(*) = 5 and count(distinct seq) = 5 and min(seq) = 1 and max(seq) = 5 and count(distinct invoice_no) = 5
               from public.invoices where owner_id = '00000000-0000-0000-0000-0000000e0aa1' and kind = 'gst' and seq is not null),
              'auto numbers 1..5 unique and gap-free across create_invoice + finalize_invoice (incl. cancelled)');
select tie.ok((select s.next_number = 6 from public.invoice_series s
               where s.owner_id = '00000000-0000-0000-0000-0000000e0aa1' and s.kind = 'gst' and s.fy = (select fy from tie.c)), 'series counter consistent');
-- Manual numbers that look like ANY automatic format (incl. create_invoice's fixed one) are blocked.
insert into tie.ids select 'd6', public.create_invoice_draft((select a_in from tie.c), current_date - 30, current_date,
  array[(select id from public.shipments where awb = 'TIE7')]);
select public.save_invoice_draft((select id from tie.ids where k = 'd6'),
  jsonb_build_object('numbering', 'manual', 'requested_invoice_no', 'GST/' || (select fy from tie.c) || '/0099'),
  jsonb_build_array(jsonb_build_object('shipment_id', (select id from public.shipments where awb = 'TIE7'), 'weight', 1, 'rate', 10, 'amount', 10)), '[]');
select tie.expect_fail($$select public.finalize_invoice((select id from tie.ids where k = 'd6'))$$, 'manual number in create_invoice format blocked', '{P0001}', '%automatic series%');
select public.save_invoice_draft((select id from tie.ids where k = 'd6'), '{"numbering":"manual","requested_invoice_no":"gst-26-27-050"}',
  jsonb_build_array(jsonb_build_object('shipment_id', (select id from public.shipments where awb = 'TIE7'), 'weight', 1, 'rate', 10, 'amount', 10)), '[]');
select tie.expect_fail($$select public.finalize_invoice((select id from tie.ids where k = 'd6'))$$, 'manual number with series prefix (any case) blocked', '{P0001}', '%automatic series%');
-- Same manual number on two drafts: only the first finalize wins.
select public.save_invoice_draft((select id from tie.ids where k = 'd6'), '{"numbering":"manual","requested_invoice_no":"RACE-001"}',
  jsonb_build_array(jsonb_build_object('shipment_id', (select id from public.shipments where awb = 'TIE7'), 'weight', 1, 'rate', 10, 'amount', 10)), '[]');
insert into tie.ids select 'd7', public.create_invoice_draft((select a_in from tie.c), current_date - 30, current_date,
  array[(select id from public.shipments where awb = 'TIE8')]);
select public.save_invoice_draft((select id from tie.ids where k = 'd7'), '{"numbering":"manual","requested_invoice_no":"RACE-001"}',
  jsonb_build_array(jsonb_build_object('shipment_id', (select id from public.shipments where awb = 'TIE8'), 'weight', 1, 'rate', 10, 'amount', 10)), '[]');
select public.finalize_invoice((select id from tie.ids where k = 'd6'));
select tie.expect_fail($$select public.finalize_invoice((select id from tie.ids where k = 'd7'))$$, 'duplicate manual number on 2nd draft', '{P0001}', '%already used%');
select tie.ok((select status = 'draft' and invoice_no is null from public.invoices where id = (select id from tie.ids where k = 'd7')), 'losing draft stays an unnumbered draft');
select public.discard_invoice_draft((select id from tie.ids where k = 'd7'));
-- cancel_invoice passes the immutability trigger and releases shipments.
select public.cancel_invoice((select id from tie.ids where k = 'L1'), 'legacy cancel test');
select tie.ok((select status = 'cancelled' and total = 59 and bill_to_name = 'TIE IN' from public.invoices where id = (select id from tie.ids where k = 'L1'))
              and (select invoice_id is null from public.shipments where awb = 'TIE5'), 'legacy cancel_invoice works, amounts + snapshot kept');

-- R. Client rename: open drafts refresh the bill-to name; issued/cancelled keep it.
insert into tie.ids select 'd8', public.create_invoice_draft((select a_in from tie.c), current_date - 30, current_date,
  array[(select id from public.shipments where awb = 'TIE9')]);
update public.clients set name = 'TIE IN RENAMED' where id = (select a_in from tie.c);
select public.save_invoice_draft((select id from tie.ids where k = 'd8'), '{}',
  jsonb_build_array(jsonb_build_object('shipment_id', (select id from public.shipments where awb = 'TIE9'), 'weight', 1, 'rate', 10, 'amount', 10)), '[]');
select tie.ok((select bill_to_name = 'TIE IN RENAMED' from public.invoices where id = (select id from tie.ids where k = 'd8')), 'draft picks up renamed client');
select tie.ok((select count(*) = 0 from public.invoices where client_id = (select a_in from tie.c) and status <> 'draft' and bill_to_name <> 'TIE IN'),
              'issued + cancelled invoices keep the original name');
select public.finalize_invoice((select id from tie.ids where k = 'd8'));
reset role;
select tie.expect_fail($$update public.invoices set bill_to_name = 'X' where id = (select id from tie.ids where k = 'd8')$$, 'issued snapshot frozen for owner role', '{P0001,42501}');
set local role authenticated;
select tie.as_user('00000000-0000-0000-0000-0000000e0aa1');


-- N. Discard releases shipments; B (no GSTIN) gets Non-GST with no tax
select tie.as_user('00000000-0000-0000-0000-0000000e0bb1');
insert into tie.ids select 'db', public.create_invoice_draft((select b_c from tie.c), current_date - 30, current_date);
select tie.ok((select kind = 'nongst' and cgst = 0 and igst = 0 and total = 90 from public.invoices where id = (select id from tie.ids where k = 'db')), 'Non-GST draft without tax');
select public.discard_invoice_draft((select id from tie.ids where k = 'db'));
select tie.ok((select count(*) = 0 from public.invoices where id = (select id from tie.ids where k = 'db'))
              and (select draft_invoice_id is null from public.shipments where awb = 'TIEB1'), 'discard deletes draft and releases shipment');

-- O. Expired plan cannot create or finalize
reset role;
update public.profiles set trial_ends_at = now() - interval '1 day', plan = null where id = '00000000-0000-0000-0000-0000000e0bb1';
set local role authenticated;
select tie.as_user('00000000-0000-0000-0000-0000000e0bb1');
select tie.expect_fail($$select public.create_invoice_draft((select b_c from tie.c), current_date - 30, current_date)$$, 'expired plan blocked', '{P0001}', '%expired%');

-- P. Existing data untouched
reset role;
select tie.ok((select count(*) = 0 from (select * from tie.inv_before except
               select id, status, invoice_no, subtotal, cgst, sgst, igst, total, bill_to_name from public.invoices) d), 'existing invoices unchanged');
select tie.ok((select count(*) = 0 from (select * from tie.ship_before except select id, amount, weight, invoice_id from public.shipments) d), 'existing shipments unchanged');
select tie.ok((select count(*) = 0 from (select * from tie.rc_before except select * from public.rate_cards) d)
              and (select count(*) = 0 from (select * from public.rate_cards except select * from tie.rc_before) d), 'rate cards unchanged');

do $$ begin raise notice 'ALL INVOICE EDITOR TESTS PASSED'; end $$;
rollback;
