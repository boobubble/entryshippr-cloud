-- =====================================================================
-- EntrySetu city / zone tests. FOR MANUAL REVIEW. Run AFTER migration_2026_10_15_cities_zones.sql
-- in the NEW development project's SQL Editor. One transaction, ROLLED BACK.
-- Blocked actions must fail with the exact SQLSTATE; last notice "ALL CITY TESTS PASSED".
-- =====================================================================
begin;
create schema tc;
grant usage on schema tc to authenticated, service_role;
create function tc.expect_fail(q text, label text, codes text[], msg_like text default null)
returns void language plpgsql as $$
declare v_state text; v_msg text;
begin
  begin execute q;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    if not (v_state = any(codes)) then raise exception 'FAIL: % — wrong error % (%), expected %', label, v_state, v_msg, codes; end if;
    if msg_like is not null and v_msg not ilike msg_like then raise exception 'FAIL: % — message "%"', label, v_msg; end if;
    raise notice 'PASS (blocked %) %', v_state, label; return;
  end;
  raise exception 'FAIL: % was allowed', label;
end $$;
create function tc.ok(cond boolean, label text) returns void language plpgsql as $$
begin if cond is true then raise notice 'PASS %', label; else raise exception 'FAIL: % (got %)', label, cond; end if; end $$;
create function tc.as_user(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
end $$;
grant execute on all functions in schema tc to authenticated, service_role;
create table tc.v (k text primary key, id uuid);
grant select, insert on tc.v to authenticated;

-- ---------- Catalogue: grants and search_path
do $$ declare t text; begin
  foreach t in array array['cities','city_aliases','seller_city_zones','seller_city_aliases'] loop
    if has_table_privilege('anon', 'public.' || t, 'SELECT') then raise exception 'FAIL: anon reads %', t; end if;
    if has_table_privilege('authenticated', 'public.' || t, 'INSERT') or has_table_privilege('authenticated', 'public.' || t, 'UPDATE') then
      raise exception 'FAIL: table-wide write on %', t; end if;
  end loop;
  if has_table_privilege('authenticated', 'public.cities', 'DELETE') or has_column_privilege('authenticated', 'public.cities', 'name', 'INSERT')
     or has_table_privilege('authenticated', 'public.city_aliases', 'DELETE') then raise exception 'FAIL: users can write global cities'; end if;
  if has_column_privilege('authenticated', 'public.seller_city_zones', 'owner_id', 'INSERT')
     or has_column_privilege('authenticated', 'public.shipments', 'pricing_status', 'UPDATE')
     or has_column_privilege('authenticated', 'public.shipments', 'city_id', 'INSERT') then raise exception 'FAIL: protected column writable'; end if;
  if has_function_privilege('authenticated', 'public.sync_cities(jsonb)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.city_zone(uuid,text,boolean)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.reprice_review(uuid)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.ensure_city(text,text,uuid)', 'EXECUTE') then raise exception 'FAIL: internal function callable'; end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.prosecdef and not ('search_path=""' = any(coalesce(p.proconfig, '{}')))) then
    raise exception 'FAIL: SECURITY DEFINER without empty search_path'; end if;
  raise notice 'PASS grants and search_path';
end $$;

-- ---------- Registry sync (service_role)
set local role service_role;
select tc.ok(public.norm_city('  Navi-Mumbai, ') = 'navi mumbai', 'normalisation');
select public.sync_cities('[
  {"name":"Mumbai","state":"Maharashtra","aliases":["Bombay"]},
  {"name":"Pune","state":"Maharashtra","aliases":["Poona"]},
  {"name":"Aurangabad","state":"Maharashtra"},
  {"name":"Aurangabad","state":"Bihar"},
  {"name":"Bad","state":"Narnia"}]'::jsonb);
select tc.ok((select count(*) from public.cities where name_norm = 'aurangabad') = 2, 'same name, two states kept separately');
select tc.ok((select count(*) from public.cities where name_norm = 'bad') = 0, 'invalid state skipped');
select public.sync_cities('[{"name":"Mumbai","state":"Maharashtra","aliases":["Bombay"]}]'::jsonb);
select tc.ok((select count(*) from public.cities where name_norm = 'mumbai') = 1, 'sync is idempotent');
reset role;

-- ---------- Users
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000d1', 'authenticated', 'authenticated', 'tc-a@test.local', '', now(), '{"provider":"email","providers":["email"]}', '{}', now(), now()),
       ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000d2', 'authenticated', 'authenticated', 'tc-b@test.local', '', now(), '{"provider":"email","providers":["email"]}', '{}', now(), now());

set local role authenticated;
select tc.as_user('00000000-0000-0000-0000-0000000000d1');
select tc.expect_fail($$insert into public.cities (name, name_norm) values ('Spam', 'spam')$$, 'users cannot insert global cities', '{42501}');
select tc.expect_fail($$update public.cities set name = 'X'$$, 'users cannot edit global cities', '{42501}');
select tc.expect_fail($$select public.sync_cities('[]')$$, 'users cannot run sync', '{42501}');
insert into public.clients (name) values ('DA');
insert into public.zones (name) values ('West'), ('North');
insert into tc.v select 'client', id from public.clients where name = 'DA';
insert into tc.v select 'west', id from public.zones where name = 'West';
insert into tc.v select 'north', id from public.zones where name = 'North';
select public.save_rate_card(null, 'DOX', 'Standard', jsonb_build_array(jsonb_build_object('min_weight', 0, 'max_weight', 500,
  'rates', jsonb_build_object((select id from tc.v where k = 'west'), 40, (select id from tc.v where k = 'north'), 55))));

-- resolve / register
select tc.ok((select status = 'unmapped' and city_name = 'Mumbai' from public.register_cities('{bombay}')), 'alias Bombay -> Mumbai, unmapped');
select tc.ok((select status = 'ambiguous' and jsonb_array_length(candidates) = 2 from public.register_cities('{Aurangabad}')), 'ambiguous name needs confirmation');
select tc.ok((select status = 'unmapped' and city_id is not null from public.register_cities('{" new  town "}')), 'new city auto-registered');
select tc.ok((select source = 'user' and name = 'New Town' from public.cities where name_norm = 'new town'), 'registered city normalised, marked user');
select tc.ok((select status = 'invalid' from public.register_cities('{"123"}')), 'numeric-only city rejected');

-- Needs review, then fixed by assigning a zone
insert into public.shipments (client_id, awb, destination, shipment_type, weight_f) select id, 'C1', 'Bombay', 'DOX', 100 from tc.v where k = 'client';
select tc.ok((select pricing_status = 'needs_review' and amount = 0 and city_id is not null and review_reason like '%has no zone%' from public.shipments where awb = 'C1'),
  'unmapped city -> needs review, no default zone');
select tc.expect_fail($$select public.create_invoice((select id from tc.v where k = 'client'), current_date - 1, current_date)$$,
  'needs-review shipment cannot be invoiced', '{P0001}', '%need review%');
insert into public.seller_city_zones (city_id, zone_id) select c.id, z.id from public.cities c, tc.v z where c.name_norm = 'mumbai' and z.k = 'west';
select tc.ok((select pricing_status = 'priced' and amount = 40 and rate_zone = 'West' from public.shipments where awb = 'C1'), 'assigning zone re-prices automatically');
update public.seller_city_zones set zone_id = (select id from tc.v where k = 'north');
insert into public.shipments (client_id, awb, destination, shipment_type, weight_f) select id, 'C2', 'mumbai', 'DOX', 100 from tc.v where k = 'client';
select tc.ok((select amount = 55 and rate_zone = 'North' from public.shipments where awb = 'C2'), 'manual entry uses same city->zone->rate chain');

-- Ambiguity: confirm, then price
insert into public.shipments (client_id, awb, destination, shipment_type, weight_f) select id, 'C3', 'Aurangabad', 'DOX', 100 from tc.v where k = 'client';
select tc.ok((select pricing_status = 'needs_review' and review_reason like '%several cities%' and city_id is null from public.shipments where awb = 'C3'), 'ambiguous city never guessed');
insert into public.seller_city_aliases (alias_norm, city_id) select ' AURANGABAD ', id from public.cities where name_norm = 'aurangabad' and state = 'Maharashtra';
insert into public.seller_city_zones (city_id, zone_id) select c.id, z.id from public.cities c, tc.v z where c.name_norm = 'aurangabad' and c.state = 'Maharashtra' and z.k = 'west';
select tc.ok((select pricing_status = 'priced' and amount = 40 from public.shipments where awb = 'C3'), 'confirmed city + zone re-prices');
select tc.ok((select alias_norm = 'aurangabad' from public.seller_city_aliases limit 1), 'seller alias normalised');

-- zone FK: cannot map to another seller's zone (checked below), cannot map twice
select tc.expect_fail($$insert into public.seller_city_zones (city_id, zone_id) select c.id, z.id from public.cities c, tc.v z where c.name_norm = 'mumbai' and z.k = 'west'$$,
  'one zone per city per seller', '{23505}');

-- ---------- Tenant isolation
select tc.as_user('00000000-0000-0000-0000-0000000000d2');
select tc.ok((select count(*) from public.seller_city_zones) = 0 and (select count(*) from public.seller_city_aliases) = 0, 'B sees none of A''s mappings');
select tc.ok((select count(*) from public.cities where name_norm = 'mumbai') = 1, 'B sees global cities');
select tc.ok((select status = 'unmapped' from public.register_cities('{Mumbai}')), 'A''s mapping does not leak to B');
select tc.ok((select status = 'ambiguous' from public.register_cities('{Aurangabad}')), 'A''s confirmation does not leak to B');
select tc.expect_fail($$insert into public.seller_city_zones (city_id, zone_id) select c.id, z.id from public.cities c, tc.v z where c.name_norm = 'pune' and z.k = 'west'$$,
  'B cannot map to A''s zone', '{23503,42501}');
update public.seller_city_zones set zone_id = zone_id;   -- RLS: 0 rows
delete from public.seller_city_zones;                    -- RLS: 0 rows
delete from public.seller_city_aliases;                  -- RLS: 0 rows
reset role;
select tc.ok((select count(*) from public.seller_city_zones where owner_id = '00000000-0000-0000-0000-0000000000d1') = 2
          and (select count(*) from public.seller_city_aliases where owner_id = '00000000-0000-0000-0000-0000000000d1') = 1, 'B could not change A''s mappings');

-- ---------- Sync never overwrites seller assignments
set local role service_role;
select public.sync_cities('[{"name":"Mumbai","state":"Maharashtra","aliases":["Bombay","Mumbai City"]}]'::jsonb);
reset role;
select tc.ok((select count(*) from public.seller_city_zones where owner_id = '00000000-0000-0000-0000-0000000000d1') = 2, 'sync left seller mappings intact');

-- ---------- Expired plan: read-only mappings
update public.profiles set trial_ends_at = now() - interval '1 day' where id = '00000000-0000-0000-0000-0000000000d1';
set local role authenticated;
select tc.as_user('00000000-0000-0000-0000-0000000000d1');
select tc.expect_fail($$insert into public.seller_city_zones (city_id, zone_id) select c.id, z.id from public.cities c, tc.v z where c.name_norm = 'pune' and z.k = 'west'$$,
  'expired: cannot assign zones', '{42501}');
select tc.ok((select status = 'unknown' or status = 'unmapped' or status = 'invalid' from public.register_cities('{Brandnewville}')) and
             (select count(*) = 0 from public.cities where name_norm = 'brandnewville'), 'expired: resolve only, nothing registered');
reset role;

-- ---------- Migration of zones.destinations
set local role authenticated;
select tc.as_user('00000000-0000-0000-0000-0000000000d2');
insert into public.zones (name, destinations) values ('Legacy', '{Poona, Aurangabad, Oldtown}');
select tc.ok((select count(*) from public.seller_city_zones) = 2, 'legacy destinations mapped (Pune via alias, Oldtown registered); ambiguous Aurangabad skipped');
reset role;

do $$ begin raise notice 'ALL CITY TESTS PASSED'; end $$;
rollback;
