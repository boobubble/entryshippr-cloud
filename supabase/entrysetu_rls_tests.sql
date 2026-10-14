-- EntrySetu RLS / integrity tests. Run AFTER entrysetu_schema.sql, on the NEW project only.
-- Everything happens inside one transaction and is ROLLED BACK — no data is kept.
-- Every check prints "PASS ..." as a notice; any failure aborts with "FAIL ...".
begin;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-00000000000a', 'tenant-a@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-00000000000b', 'tenant-b@test.local', 'authenticated', 'authenticated');

create function pg_temp.expect_fail(q text, label text) returns void language plpgsql as $$
begin
  begin execute q;
  exception when others then raise notice 'PASS (blocked) %: %', label, sqlerrm; return; end;
  raise exception 'FAIL: % was allowed', label;
end $$;
create function pg_temp.expect_ok(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond then raise notice 'PASS %', label; else raise exception 'FAIL: %', label; end if;
end $$;

-- ---------- Tenant A sets up data
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
insert into public.clients (name, state, is_gst) values ('A-Client', 'Gujarat', true);
insert into public.rate_cards (client_id, service, min_weight, max_weight, rate)
  select id, 'Standard', 0, 1, 50 from public.clients where name = 'A-Client';
insert into public.shipments (client_id, awb, weight, amount)
  select id, 'AWB-A-1', 0.5, 50 from public.clients where name = 'A-Client';
select pg_temp.expect_fail($$update public.profiles set plan = 'unlimited'$$, 'user cannot set own plan');
select pg_temp.expect_fail($$update public.profiles set trial_ends_at = now() + interval '1 year'$$, 'user cannot extend own trial');
select pg_temp.expect_fail($$insert into public.user_roles (user_id, role) values (auth.uid(), 'admin')$$, 'user cannot make self admin');
select pg_temp.expect_fail($$select public.activate_payment('x', 'y', 100)$$, 'user cannot call activate_payment');
select pg_temp.expect_fail($$select public.admin_set_access(auth.uid(), 'grant_plan')$$, 'user cannot call admin_set_access');
select pg_temp.expect_fail($$insert into public.shipments (client_id, awb, invoice_id) select id, 'X', gen_random_uuid() from public.clients limit 1$$, 'user cannot set invoice_id directly');

-- ---------- Tenant B cannot see or reference A's data
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}', true);
select pg_temp.expect_ok((select count(*) from public.clients) = 0, 'B sees no clients of A');
select pg_temp.expect_ok((select count(*) from public.shipments) = 0, 'B sees no shipments of A');
select pg_temp.expect_ok((select count(*) from public.profiles) = 1, 'B sees only own profile');
reset role;
create temp table a_client as select id from public.clients where name = 'A-Client';
grant select on a_client to authenticated;
set local role authenticated;
select pg_temp.expect_fail($$insert into public.shipments (client_id, awb) select id, 'AWB-B-X' from a_client$$, 'B cannot attach shipment to A''s client (composite FK)');
select pg_temp.expect_fail($$insert into public.rate_cards (client_id, max_weight, rate) select id, 1, 1 from a_client$$, 'B cannot attach rate card to A''s client');
select pg_temp.expect_fail($$select public.create_invoice((select id from a_client), current_date - 30, current_date)$$, 'B cannot invoice A''s client');
update public.clients set name = 'hacked';  -- RLS: affects 0 rows
reset role;
select pg_temp.expect_ok((select name from public.clients where id = (select id from a_client)) = 'A-Client', 'B could not modify A''s client');

-- ---------- Invoicing: separate series, frozen shipments, no edits
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
insert into public.invoice_series (fy, kind, prefix, next_number)
  values (public.fy_label(current_date), 'gst', 'AGST', 101);
select public.create_invoice((select id from a_client), current_date - 30, current_date);
select pg_temp.expect_ok((select seq from public.invoices limit 1) = 101, 'GST series starts at configured number 101');
select pg_temp.expect_ok((select cgst from public.invoices limit 1) = 4.50, 'CGST computed (same state / missing state)');
select pg_temp.expect_fail($$update public.shipments set amount = 1 where awb = 'AWB-A-1'$$, 'billed shipment cannot be edited') ;
reset role;
select pg_temp.expect_ok((select amount from public.shipments where awb = 'AWB-A-1') = 50, 'billed shipment amount unchanged');
set local role authenticated;
delete from public.shipments where awb = 'AWB-A-1';  -- RLS: 0 rows
select pg_temp.expect_ok((select count(*) from public.shipments where awb = 'AWB-A-1') = 1, 'billed shipment cannot be deleted');
select pg_temp.expect_fail($$update public.invoices set total = 0$$, 'issued invoice cannot be edited');
select pg_temp.expect_fail($$delete from public.invoices$$, 'invoice cannot be deleted');
select pg_temp.expect_fail($$update public.invoice_series set next_number = 50 where kind = 'gst'$$, 'series cannot go backwards');
insert into public.clients (name, is_gst) values ('A-NonGST', false);
insert into public.shipments (client_id, awb, amount) select id, 'AWB-A-2', 40 from public.clients where name = 'A-NonGST';
select public.create_invoice((select id from public.clients where name = 'A-NonGST'), current_date - 30, current_date);
select pg_temp.expect_ok((select seq from public.invoices where kind = 'nongst') = 1, 'Non-GST series is independent (starts at 1)');
select public.cancel_invoice((select id from public.invoices where kind = 'gst'), 'test');
select pg_temp.expect_ok((select invoice_id is null from public.shipments where awb = 'AWB-A-1'), 'cancel releases shipments');

-- ---------- 50 active client limit
insert into public.clients (name) select 'Bulk ' || g from generate_series(1, 48) g;  -- now 50 active
select pg_temp.expect_fail($$insert into public.clients (name) values ('Client 51')$$, '51st active client blocked');
update public.clients set active = false where name = 'Bulk 1';
insert into public.clients (name) values ('Client 51 after deactivation');
select pg_temp.expect_fail($$update public.clients set active = true where name = 'Bulk 1'$$, 'reactivating over limit blocked');

-- ---------- Expired access = read-only (insert, update, delete)
reset role;
update public.profiles set trial_ends_at = now() - interval '1 day' where id = '00000000-0000-0000-0000-00000000000a';
set local role authenticated;
select pg_temp.expect_ok((select count(*) from public.clients) > 0, 'expired user can still read');
select pg_temp.expect_fail($$insert into public.clients (name) values ('after expiry')$$, 'expired: insert blocked');
update public.clients set phone = '1' where name = 'Bulk 2';
delete from public.rate_cards;
delete from public.shipments where awb = 'AWB-A-1';
reset role;
select pg_temp.expect_ok((select phone is null from public.clients where name = 'Bulk 2'), 'expired: update blocked');
select pg_temp.expect_ok((select count(*) from public.rate_cards) = 1, 'expired: delete blocked (rate card)');
select pg_temp.expect_ok((select count(*) from public.shipments where awb = 'AWB-A-1') = 1, 'expired: delete blocked (shipment)');
set local role authenticated;
select pg_temp.expect_fail($$select public.create_invoice((select id from a_client), current_date - 30, current_date)$$, 'expired: invoicing blocked');

-- ---------- Payment activation is idempotent
reset role;
insert into public.payments (owner_id, plan, amount_paise, includes_joining_fee, razorpay_order_id)
  values ('00000000-0000-0000-0000-00000000000a', 'standard', 420000, true, 'order_test_1');
select pg_temp.expect_fail($$select public.activate_payment('order_test_1', 'pay_1', 100)$$, 'amount mismatch rejected');
select pg_temp.expect_ok(public.activate_payment('order_test_1', 'pay_1', 420000), 'first activation applies');
select pg_temp.expect_ok(not public.activate_payment('order_test_1', 'pay_1', 420000), 'second activation is a no-op');
select pg_temp.expect_ok((select plan = 'standard' and joining_fee_paid and plan_expires_at > now() + interval '360 days'
                          from public.profiles where id = '00000000-0000-0000-0000-00000000000a'), 'plan activated for 1 year once');
select pg_temp.expect_ok(public.record_webhook_event('evt_1', 'payment.captured'), 'webhook event recorded');
select pg_temp.expect_ok(not public.record_webhook_event('evt_1', 'payment.captured'), 'duplicate webhook ignored');

rollback;
