-- EntrySetu RLS / integrity tests. Run AFTER entrysetu_schema.sql, on the NEW project only,
-- in Supabase -> SQL Editor (runs as "postgres"). Everything is inside one transaction and
-- ROLLED BACK — no users, data or helper schema are kept.
-- Each "blocked" check must fail with the EXACT expected error code (and message, where the
-- block comes from our own rule). Any other error — e.g. a missing grant on a helper — is a FAIL,
-- so a permission problem can never be mistaken for a passing check.
begin;

-- ---------- Helpers (in a throwaway schema, usable by the authenticated role)
create schema rls_test;
grant usage on schema rls_test to authenticated;

create function rls_test.expect_fail(q text, label text, codes text[], msg_like text default null)
returns void language plpgsql as $$
declare v_state text; v_msg text;
begin
  begin
    execute q;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    if not (v_state = any(codes)) then
      raise exception 'FAIL: % — wrong error % (%), expected %', label, v_state, v_msg, codes;
    end if;
    if msg_like is not null and v_msg not ilike msg_like then
      raise exception 'FAIL: % — wrong message "%", expected like "%"', label, v_msg, msg_like;
    end if;
    raise notice 'PASS (blocked %) %: %', v_state, label, v_msg;
    return;
  end;
  raise exception 'FAIL: % was allowed', label;
end $$;

create function rls_test.expect_ok(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond is true then raise notice 'PASS %', label; else raise exception 'FAIL: % (got %)', label, cond; end if;
end $$;

create function rls_test.as_user(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
end $$;

grant execute on all functions in schema rls_test to authenticated;

-- ---------- Test users (all columns a fresh Supabase auth.users needs)
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-00000000000a', 'authenticated', 'authenticated',
   'tenant-a@test.local', '', now(), '{"provider":"email","providers":["email"]}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-00000000000b', 'authenticated', 'authenticated',
   'tenant-b@test.local', '', now(), '{"provider":"email","providers":["email"]}', '{}', now(), now());
select rls_test.expect_ok((select count(*) from public.profiles
  where id in ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000b')) = 2,
  'signup trigger created both profiles');

-- ---------- Tenant A sets up data
set local role authenticated;
select rls_test.as_user('00000000-0000-0000-0000-00000000000a');
select rls_test.expect_ok(auth.uid() = '00000000-0000-0000-0000-00000000000a', 'acting as tenant A');
insert into public.clients (name, state, is_gst) values ('A-Client', 'Gujarat', true);
insert into public.rate_cards (client_id, service, min_weight, max_weight, rate)
  select id, 'Standard', 0, 1, 50 from public.clients where name = 'A-Client';
insert into public.shipments (client_id, awb, weight, amount)
  select id, 'AWB-A-1', 0.5, 50 from public.clients where name = 'A-Client';
select rls_test.expect_ok((select count(*) from public.shipments) = 1, 'A sees own shipment');

select rls_test.expect_fail($$update public.profiles set plan = 'unlimited'$$, 'user cannot set own plan', '{42501}');
select rls_test.expect_fail($$update public.profiles set trial_ends_at = now() + interval '1 year'$$, 'user cannot extend own trial', '{42501}');
select rls_test.expect_fail($$insert into public.user_roles (user_id, role) values (auth.uid(), 'admin')$$, 'user cannot make self admin', '{42501}');
select rls_test.expect_fail($$select public.activate_payment('x', 'y', 100)$$, 'user cannot call activate_payment', '{42501}');
select rls_test.expect_fail($$select public.record_webhook_event('x', 'y')$$, 'user cannot call record_webhook_event', '{42501}');
select rls_test.expect_fail($$select public.admin_set_access(auth.uid(), 'grant_plan')$$, 'user cannot call admin_set_access', '{42501}');
select rls_test.expect_fail($$insert into public.shipments (client_id, awb, invoice_id) select id, 'X', gen_random_uuid() from public.clients limit 1$$,
  'user cannot set invoice_id directly', '{42501}');
select rls_test.expect_fail($$insert into public.payments (owner_id, plan, amount_paise, razorpay_order_id) values (auth.uid(), 'standard', 1, 'o')$$,
  'user cannot create payment rows', '{42501}');

-- ---------- State validation
select rls_test.expect_fail($$insert into public.clients (name, state) values ('Bad state', 'Gujrat')$$, 'invalid client state rejected', '{23514}');
select rls_test.expect_fail($$update public.profiles set state = 'Atlantis'$$, 'invalid business state rejected', '{23514}');
select rls_test.expect_fail($$insert into public.clients (name, state, gstin) values ('Bad GSTIN', 'Gujarat', '27ABCDE1234F1Z5')$$,
  'GSTIN state code must match state', '{23514}');

-- ---------- Tenant B cannot see or reference A's data
select rls_test.as_user('00000000-0000-0000-0000-00000000000b');
select rls_test.expect_ok((select count(*) from public.clients) = 0, 'B sees no clients of A');
select rls_test.expect_ok((select count(*) from public.shipments) = 0, 'B sees no shipments of A');
select rls_test.expect_ok((select count(*) from public.rate_cards) = 0, 'B sees no rate cards of A');
select rls_test.expect_ok((select count(*) from public.profiles) = 1, 'B sees only own profile');
reset role;
create table rls_test.a_client as select id from public.clients where name = 'A-Client';
grant select on rls_test.a_client to authenticated;
set local role authenticated;
select rls_test.expect_fail($$insert into public.shipments (client_id, awb) select id, 'AWB-B-X' from rls_test.a_client$$,
  'B cannot attach shipment to A''s client', '{23503,42501}');
select rls_test.expect_fail($$insert into public.rate_cards (client_id, max_weight, rate) select id, 1, 1 from rls_test.a_client$$,
  'B cannot attach rate card to A''s client', '{23503,42501}');
select rls_test.expect_fail($$select public.create_invoice((select id from rls_test.a_client), current_date - 30, current_date)$$,
  'B cannot invoice A''s client', '{P0001}', 'Client not found');
update public.clients set name = 'hacked';  -- RLS: affects 0 rows
delete from public.shipments;               -- RLS: affects 0 rows
reset role;
select rls_test.expect_ok((select name from public.clients where id = (select id from rls_test.a_client)) = 'A-Client', 'B could not modify A''s client');
select rls_test.expect_ok((select count(*) from public.shipments where awb = 'AWB-A-1') = 1, 'B could not delete A''s shipment');

-- ---------- Invoicing: valid states required, separate series, numbers never go back
set local role authenticated;
select rls_test.as_user('00000000-0000-0000-0000-00000000000a');
select rls_test.expect_fail($$select public.create_invoice((select id from rls_test.a_client), current_date - 30, current_date)$$,
  'GST invoice blocked without business state', '{P0001}', '%valid business state%');
select rls_test.expect_ok((select count(*) from public.invoice_series) = 0, 'failed invoice reserved no number');
update public.profiles set state = 'Gujarat';
insert into public.clients (name, is_gst) values ('A-NoState', true);
insert into public.shipments (client_id, awb, amount) select id, 'AWB-NS', 10 from public.clients where name = 'A-NoState';
select rls_test.expect_fail($$select public.create_invoice((select id from public.clients where name = 'A-NoState'), current_date - 30, current_date)$$,
  'GST invoice blocked without client state', '{P0001}', '%valid state for client%');
delete from public.shipments where awb = 'AWB-NS';
delete from public.clients where name = 'A-NoState';

insert into public.invoice_series (fy, kind, prefix, next_number)
  values (public.fy_label(current_date), 'gst', 'AGST', 101);
select public.create_invoice((select id from rls_test.a_client), current_date - 30, current_date);
select rls_test.expect_ok((select seq from public.invoices where kind = 'gst') = 101, 'GST series starts at configured number 101');
select rls_test.expect_ok((select cgst = 4.50 and sgst = 4.50 and igst = 0 from public.invoices where kind = 'gst'), 'same state -> CGST + SGST');
select rls_test.expect_fail($$update public.invoice_series set next_number = 50 where kind = 'gst'$$,
  'series cannot go below used numbers', '{P0001}', '%backwards%');
update public.invoice_series set next_number = 200 where kind = 'gst';
select rls_test.expect_fail($$update public.invoice_series set next_number = 150 where kind = 'gst'$$,
  'series cannot go back over reserved-unused numbers', '{P0001}', '%backwards%');
select rls_test.expect_fail($$delete from public.invoice_series$$, 'series cannot be deleted', '{42501}');

select rls_test.expect_fail($$update public.shipments set amount = 1 where awb = 'AWB-A-1'$$, 'billed shipment cannot be edited',
  '{P0001}', '%on invoice%');
do $$ begin  -- RLS filters it (0 rows) or the guard trigger refuses; any other error fails the run
  delete from public.shipments where awb = 'AWB-A-1';
exception when raise_exception then null;
end $$;
reset role;
select rls_test.expect_ok((select amount from public.shipments where awb = 'AWB-A-1') = 50, 'billed shipment amount unchanged');
select rls_test.expect_ok((select count(*) from public.shipments where awb = 'AWB-A-1') = 1, 'billed shipment not deleted');
set local role authenticated;
select rls_test.expect_fail($$update public.invoices set total = 0$$, 'issued invoice cannot be edited', '{42501}');
select rls_test.expect_fail($$delete from public.invoices$$, 'invoice cannot be deleted', '{42501}');

insert into public.clients (name, state, is_gst) values ('A-Maha', 'Maharashtra', true);
insert into public.shipments (client_id, awb, amount) select id, 'AWB-A-3', 100 from public.clients where name = 'A-Maha';
select public.create_invoice((select id from public.clients where name = 'A-Maha'), current_date - 30, current_date);
select rls_test.expect_ok((select seq = 200 and igst = 18.00 and cgst = 0 from public.invoices where invoice_no like 'AGST/%/0200'),
  'different state -> IGST, numbering continues from 200');

insert into public.clients (name, is_gst) values ('A-NonGST', false);
insert into public.shipments (client_id, awb, amount) select id, 'AWB-A-2', 40 from public.clients where name = 'A-NonGST';
select public.create_invoice((select id from public.clients where name = 'A-NonGST'), current_date - 30, current_date);
select rls_test.expect_ok((select seq = 1 and total = 40 from public.invoices where kind = 'nongst'), 'Non-GST series is independent, no state needed');

select public.cancel_invoice((select id from public.invoices where seq = 101 and kind = 'gst'), 'test');
select rls_test.expect_ok((select invoice_id is null from public.shipments where awb = 'AWB-A-1'), 'cancel releases shipments');
select rls_test.expect_ok((select next_number = 201 from public.invoice_series where kind = 'gst'), 'cancel does not rewind numbering');

-- ---------- 50 active client limit (A has 3 clients now)
insert into public.clients (name) select 'Bulk ' || g from generate_series(1, 47) g;  -- now 50 active
select rls_test.expect_fail($$insert into public.clients (name) values ('Client 51')$$, '51st active client blocked', '{P0001}', '%limit reached%');
update public.clients set active = false where name = 'Bulk 1';
insert into public.clients (name) values ('Client 51 after deactivation');
select rls_test.expect_fail($$update public.clients set active = true where name = 'Bulk 1'$$, 'reactivating over limit blocked', '{P0001}', '%limit reached%');

-- ---------- Expired access = read-only (insert, update, delete)
reset role;
update public.profiles set trial_ends_at = now() - interval '1 day' where id = '00000000-0000-0000-0000-00000000000a';
set local role authenticated;
select rls_test.expect_ok((select count(*) from public.clients) > 0, 'expired user can still read');
select rls_test.expect_fail($$insert into public.clients (name) values ('after expiry')$$, 'expired: insert blocked', '{42501}');
update public.clients set phone = '1' where name = 'Bulk 2';  -- RLS: 0 rows
delete from public.rate_cards;                                -- RLS: 0 rows
delete from public.shipments where awb = 'AWB-A-1';           -- RLS: 0 rows
reset role;
select rls_test.expect_ok((select phone is null from public.clients where name = 'Bulk 2'), 'expired: update blocked');
select rls_test.expect_ok((select count(*) from public.rate_cards) = 1, 'expired: delete blocked (rate card)');
select rls_test.expect_ok((select count(*) from public.shipments where awb = 'AWB-A-1') = 1, 'expired: delete blocked (shipment)');
set local role authenticated;
select rls_test.expect_fail($$select public.create_invoice((select id from rls_test.a_client), current_date - 30, current_date)$$,
  'expired: invoicing blocked', '{P0001}', '%expired%');
update public.invoice_series set prefix = 'X' where kind = 'gst';
reset role;
select rls_test.expect_ok((select prefix = 'AGST' from public.invoice_series where owner_id = '00000000-0000-0000-0000-00000000000a' and kind = 'gst'),
  'expired: series edit blocked');

-- ---------- Payment activation (service role path) is idempotent and amount-checked
insert into public.payments (owner_id, plan, amount_paise, includes_joining_fee, razorpay_order_id)
  values ('00000000-0000-0000-0000-00000000000a', 'standard', 420000, true, 'order_test_1');
select rls_test.expect_fail($$select public.activate_payment('order_test_1', 'pay_1', 100)$$, 'amount mismatch rejected', '{P0001}', 'Amount mismatch%');
select rls_test.expect_fail($$select public.activate_payment('order_nope', 'pay_1', 420000)$$, 'unknown order rejected', '{P0001}', 'Unknown order%');
select rls_test.expect_ok(public.activate_payment('order_test_1', 'pay_1', 420000), 'first activation applies');
select rls_test.expect_ok(not public.activate_payment('order_test_1', 'pay_1', 420000), 'second activation is a no-op');
select rls_test.expect_ok((select plan = 'standard' and joining_fee_paid and plan_expires_at > now() + interval '360 days'
                          from public.profiles where id = '00000000-0000-0000-0000-00000000000a'), 'plan activated for 1 year once');
select rls_test.expect_ok(public.record_webhook_event('evt_1', 'payment.captured'), 'webhook event recorded');
select rls_test.expect_ok(not public.record_webhook_event('evt_1', 'payment.captured'), 'duplicate webhook ignored');

do $$ begin raise notice 'ALL TESTS PASSED (rolling back)'; end $$;
rollback;
