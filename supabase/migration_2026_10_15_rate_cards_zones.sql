-- =====================================================================
-- EntrySetu V2 migration 2 of 3: client-wise DOX / NON-DOX rate cards,
-- zone-wise slab pricing, and SERVER-SIDE shipment pricing.
-- Revision 2. FOR MANUAL REVIEW ONLY. Run after migration_2026_10_15_import_weights.sql.
-- Idempotent. Existing rate_cards, shipments and invoices are not rewritten.
--
-- Zero or negative rates are rejected when saved, and a ₹0 price is never applied.
-- Pricing rules (identical in src/lib/rates.ts — keep both in sync):
--   billed weight  DOX: ceil(billing_weight grams)    NON-DOX: ceil(kg * 1000) / 1000
--   card choice    zone-wise slabs for (client, type, service); if none, the Default
--                  (client_id NULL) card; if neither exists, older kg rate_cards
--                  (client first, then default; above the top slab adds
--                  ceil(excess kg) * extra_per_kg).
--   zone           destination matched case-insensitively against zone destinations;
--                  a destination may belong to only one zone per seller.
--   slab           min_weight <= w <= max_weight, lowest min_weight first, so a shared
--                  boundary (0–0.5, 0.5–1) belongs to the LOWER slab. Saved slabs may
--                  touch but never overlap (next.min >= previous.max).
--   missing rate   the shipment is REJECTED ("No rate: ..."), never charged ₹0.
-- For typed (DOX / NON-DOX) shipments amount, rate_applied, rate_zone and rate_slab
-- are always set by the database; any amount sent by the browser is ignored.
-- Untyped (manual V2) shipments keep the V2 behaviour (amount entered by the user).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Zones
-- ---------------------------------------------------------------------
create table if not exists public.zones (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 60),
  destinations text[] not null default '{}' check (cardinality(destinations) <= 1000),
  sort_order int not null default 0 check (sort_order between 0 and 10000),
  created_at timestamptz not null default now(),
  unique (owner_id, name)
);
create index if not exists zones_owner_idx on public.zones (owner_id, sort_order);

-- normalise destinations and forbid one destination in two zones of the same seller
create or replace function public.zones_normalise()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_dup text;
begin
  new.destinations := coalesce((select array_agg(distinct d order by d)
                                  from (select btrim(x) d from unnest(new.destinations) x) s
                                 where d <> '' and char_length(d) <= 120), '{}');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('zones:' || new.owner_id::text, 0));
  select d into v_dup from unnest(new.destinations) d
   where exists (select 1 from public.zones z, unnest(z.destinations) zd
                  where z.owner_id = new.owner_id and z.id <> new.id and lower(zd) = lower(d))
   limit 1;
  if v_dup is not null then
    raise exception 'Destination "%" is already in another zone', v_dup using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke all on function public.zones_normalise() from public, anon, authenticated;
drop trigger if exists zones_normalise on public.zones;
create trigger zones_normalise before insert or update of destinations, owner_id on public.zones
  for each row execute function public.zones_normalise();

revoke all on public.zones from public, anon, authenticated;
grant select, delete on public.zones to authenticated;
grant insert (name, destinations, sort_order) on public.zones to authenticated;
grant update (name, destinations, sort_order) on public.zones to authenticated;
grant all on public.zones to service_role;
alter table public.zones enable row level security;
drop policy if exists "zones: read own" on public.zones;
drop policy if exists "zones: write own (active plan)" on public.zones;
drop policy if exists "zones: insert own (active plan)" on public.zones;
drop policy if exists "zones: update own (active plan)" on public.zones;
drop policy if exists "zones: delete own (active plan)" on public.zones;
create policy "zones: read own" on public.zones for select to authenticated using (owner_id = auth.uid());
create policy "zones: insert own (active plan)" on public.zones for insert to authenticated
  with check (owner_id = auth.uid() and public.has_access());
create policy "zones: update own (active plan)" on public.zones for update to authenticated
  using (owner_id = auth.uid() and public.has_access()) with check (owner_id = auth.uid() and public.has_access());
create policy "zones: delete own (active plan)" on public.zones for delete to authenticated
  using (owner_id = auth.uid() and public.has_access());

-- ---------------------------------------------------------------------
-- 2. Weight slabs (grams for DOX, kilograms for NON-DOX).
--    rates = {"<zone uuid>": 45.00, ...}. Written ONLY through save_rate_card / copy_rate_cards.
-- ---------------------------------------------------------------------
create table if not exists public.rate_slabs (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  client_id uuid,                                   -- NULL = Default (all clients)
  shipment_type text not null check (shipment_type in ('DOX','NON-DOX')),
  service text not null check (service in ('Standard','Fast')),
  min_weight numeric(12,3) not null check (min_weight >= 0),
  max_weight numeric(12,3) not null,
  rates jsonb not null default '{}' check (jsonb_typeof(rates) = 'object'),
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  check (max_weight > min_weight),
  foreign key (owner_id, client_id) references public.clients (owner_id, id) on delete cascade
);
create index if not exists rate_slabs_lookup_idx on public.rate_slabs (owner_id, client_id, shipment_type, service, min_weight);

revoke all on public.rate_slabs from public, anon, authenticated;
grant select on public.rate_slabs to authenticated;
grant all on public.rate_slabs to service_role;
alter table public.rate_slabs enable row level security;
drop policy if exists "rate_slabs: read own" on public.rate_slabs;
create policy "rate_slabs: read own" on public.rate_slabs for select to authenticated using (owner_id = auth.uid());

-- ---------------------------------------------------------------------
-- 3. Save one card (client + type + service) atomically
-- ---------------------------------------------------------------------
create or replace function public.save_rate_card(p_client uuid, p_type text, p_service text, p_slabs jsonb)
returns int language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_prev numeric; r record; v_n int := 0; k text;
begin
  if v_uid is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  if not public.has_access() then raise exception 'Your trial or plan has expired' using errcode = '42501'; end if;
  if p_type is null or p_type not in ('DOX','NON-DOX') or p_service is null or p_service not in ('Standard','Fast') then
    raise exception 'Invalid type or service' using errcode = 'P0001'; end if;
  if p_client is not null and not exists (select 1 from public.clients c where c.id = p_client and c.owner_id = v_uid) then
    raise exception 'Client not found' using errcode = '42501'; end if;
  if p_slabs is null or jsonb_typeof(p_slabs) <> 'array' or jsonb_array_length(p_slabs) > 200 then
    raise exception 'Invalid slabs' using errcode = 'P0001'; end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('rates:' || v_uid::text, 0));

  for r in select (e->>'min_weight')::numeric mn, (e->>'max_weight')::numeric mx, coalesce(e->'rates', '{}'::jsonb) rates
             from jsonb_array_elements(p_slabs) e
            order by (e->>'min_weight')::numeric loop
    if r.mn is null or r.mx is null or r.mn < 0 or r.mx <= r.mn or r.mx > 999999999 then
      raise exception 'Slab % – % is invalid', r.mn, r.mx using errcode = 'P0001'; end if;
    if v_prev is not null and r.mn < v_prev then
      raise exception 'Slab starting at % overlaps the previous slab', r.mn using errcode = 'P0001'; end if;
    if jsonb_typeof(r.rates) <> 'object' then raise exception 'Invalid rates' using errcode = 'P0001'; end if;
    for k in select jsonb_object_keys(r.rates) loop
      if k !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         or not exists (select 1 from public.zones z where z.id = k::uuid and z.owner_id = v_uid) then
        raise exception 'Unknown zone in rates' using errcode = 'P0001'; end if;
      if jsonb_typeof(r.rates->k) <> 'number' or (r.rates->>k)::numeric <= 0 or (r.rates->>k)::numeric > 9999999999 then
        raise exception 'Rates must be more than 0' using errcode = 'P0001'; end if;
    end loop;
    v_prev := r.mx;
  end loop;

  delete from public.rate_slabs s where s.owner_id = v_uid and s.client_id is not distinct from p_client
     and s.shipment_type = p_type and s.service = p_service;
  insert into public.rate_slabs (owner_id, client_id, shipment_type, service, min_weight, max_weight, rates, sort_order)
  select v_uid, p_client, p_type, p_service, (e->>'min_weight')::numeric, (e->>'max_weight')::numeric,
         coalesce(e->'rates', '{}'::jsonb), o::int
    from jsonb_array_elements(p_slabs) with ordinality as t(e, o);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ---------------------------------------------------------------------
-- 4. Copy all cards (both types, both services) between clients / Default
-- ---------------------------------------------------------------------
create or replace function public.copy_rate_cards(p_from uuid, p_to uuid, p_replace boolean)
returns int language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_n int;
begin
  if v_uid is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  if not public.has_access() then raise exception 'Your trial or plan has expired' using errcode = '42501'; end if;
  if p_from is not distinct from p_to then raise exception 'Choose a different client' using errcode = 'P0001'; end if;
  if (p_from is not null and not exists (select 1 from public.clients c where c.id = p_from and c.owner_id = v_uid))
     or (p_to is not null and not exists (select 1 from public.clients c where c.id = p_to and c.owner_id = v_uid)) then
    raise exception 'Client not found' using errcode = '42501'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('rates:' || v_uid::text, 0));
  if exists (select 1 from public.rate_slabs s where s.owner_id = v_uid and s.client_id is not distinct from p_to) then
    if not coalesce(p_replace, false) then raise exception 'TARGET_HAS_RATES' using errcode = 'P0001'; end if;
    delete from public.rate_slabs s where s.owner_id = v_uid and s.client_id is not distinct from p_to;
  end if;
  insert into public.rate_slabs (owner_id, client_id, shipment_type, service, min_weight, max_weight, rates, sort_order)
  select v_uid, p_to, s.shipment_type, s.service, s.min_weight, s.max_weight, s.rates, s.sort_order
    from public.rate_slabs s where s.owner_id = v_uid and s.client_id is not distinct from p_from;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

revoke all on function public.save_rate_card(uuid, text, text, jsonb) from public, anon;
revoke all on function public.copy_rate_cards(uuid, uuid, boolean) from public, anon;
grant execute on function public.save_rate_card(uuid, text, text, jsonb) to authenticated, service_role;
grant execute on function public.copy_rate_cards(uuid, uuid, boolean) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 5. Server-side rate lookup (internal; not callable by users)
-- ---------------------------------------------------------------------
create or replace function public.shipment_rate(p_owner uuid, p_client uuid, p_type text, p_service text,
                                                p_destination text, p_billing_weight numeric)
returns table (rate numeric, zone_name text, slab_label text, reason text)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_unit text := case p_type when 'DOX' then 'g' else 'kg' end;
  v_w numeric;
  v_dest text := btrim(coalesce(p_destination, ''));
  v_has boolean := false; v_cid uuid;
  v_zone public.zones; v_slab public.rate_slabs; v_card public.rate_cards; v_label text; v_rate numeric; v_kg numeric;
begin
  if p_billing_weight is null or p_billing_weight <= 0 then
    return query select null::numeric, null::text, null::text, 'No valid weight'; return; end if;
  v_w := case p_type when 'DOX' then ceil(p_billing_weight) else ceil(p_billing_weight * 1000) / 1000 end;

  -- zone-wise card: client first, then Default
  if exists (select 1 from public.rate_slabs s where s.owner_id = p_owner and s.client_id = p_client
               and s.shipment_type = p_type and s.service = p_service) then v_has := true; v_cid := p_client;
  elsif exists (select 1 from public.rate_slabs s where s.owner_id = p_owner and s.client_id is null
               and s.shipment_type = p_type and s.service = p_service) then v_has := true; v_cid := null;
  end if;

  if v_has then
    if v_dest = '' then return query select null::numeric, null::text, null::text, 'No destination to find zone'; return; end if;
    select z.* into v_zone from public.zones z
     where z.owner_id = p_owner and exists (select 1 from unnest(z.destinations) d where lower(d) = lower(v_dest))
     limit 1;
    if not found then return query select null::numeric, null::text, null::text, format('No zone for "%s"', v_dest); return; end if;
    select s.* into v_slab from public.rate_slabs s
     where s.owner_id = p_owner and s.client_id is not distinct from v_cid and s.shipment_type = p_type
       and s.service = p_service and v_w between s.min_weight and s.max_weight
     order by s.min_weight limit 1;
    if not found then return query select null::numeric, null::text, null::text, format('No slab covers %s %s', trim_scale(v_w), v_unit); return; end if;
    v_label := format('%s–%s %s', trim_scale(v_slab.min_weight), trim_scale(v_slab.max_weight), v_unit);
    if jsonb_typeof(v_slab.rates -> v_zone.id::text) is distinct from 'number' then
      return query select null::numeric, null::text, null::text, format('No %s rate for %s', v_zone.name, v_label); return; end if;
    v_rate := round((v_slab.rates ->> v_zone.id::text)::numeric, 2);
    if v_rate <= 0 then
      return query select null::numeric, null::text, null::text, format('%s rate for %s is ₹0', v_zone.name, v_label); return; end if;
    return query select round(v_rate, 2), v_zone.name, v_label, null::text; return;
  end if;

  -- older kg rate cards (V2), client first then Default
  v_kg := case p_type when 'DOX' then v_w / 1000 else v_w end;
  if exists (select 1 from public.rate_cards c where c.owner_id = p_owner and c.client_id = p_client and lower(c.service) = lower(p_service)) then
    v_cid := p_client; v_has := true;
  elsif exists (select 1 from public.rate_cards c where c.owner_id = p_owner and c.client_id is null and lower(c.service) = lower(p_service)) then
    v_cid := null; v_has := true;
  end if;
  if not v_has then return query select null::numeric, null::text, null::text, format('No %s %s rate card', p_type, p_service); return; end if;
  select c.* into v_card from public.rate_cards c
   where c.owner_id = p_owner and c.client_id is not distinct from v_cid and lower(c.service) = lower(p_service)
     and v_kg between c.min_weight and c.max_weight order by c.min_weight limit 1;
  if found then
    if round(v_card.rate, 2) <= 0 then return query select null::numeric, null::text, null::text, 'Older kg slab rate is ₹0'; return; end if;
    return query select round(v_card.rate, 2), null::text, 'older kg slab', null::text; return;
  end if;
  select c.* into v_card from public.rate_cards c
   where c.owner_id = p_owner and c.client_id is not distinct from v_cid and lower(c.service) = lower(p_service)
   order by c.max_weight desc limit 1;
  if v_kg > v_card.max_weight then
    if round(v_card.rate + ceil(v_kg - v_card.max_weight) * v_card.extra_per_kg, 2) <= 0 then
      return query select null::numeric, null::text, null::text, 'Older kg slab rate is ₹0'; return; end if;
    return query select round(v_card.rate + ceil(v_kg - v_card.max_weight) * v_card.extra_per_kg, 2), null::text, 'older kg slab', null::text; return;
  end if;
  return query select null::numeric, null::text, null::text, format('No slab covers %s kg', trim_scale(v_kg));
end $$;
revoke all on function public.shipment_rate(uuid, uuid, text, text, text, numeric) from public, anon, authenticated;
grant execute on function public.shipment_rate(uuid, uuid, text, text, text, numeric) to service_role;

-- ---------------------------------------------------------------------
-- 6. Shipments: pricing columns + trigger (amount never trusted from the browser)
-- ---------------------------------------------------------------------
alter table public.shipments
  add column if not exists rate_zone text check (char_length(rate_zone) <= 60),
  add column if not exists rate_slab text check (char_length(rate_slab) <= 60),
  add column if not exists rate_applied numeric(12,2) check (rate_applied >= 0);

alter table public.shipments drop constraint if exists shipments_typed_service_chk;
alter table public.shipments add constraint shipments_typed_service_chk
  check (shipment_type is null or service in ('Standard','Fast'));

alter table public.shipments drop constraint if exists shipments_typed_priced_chk;
alter table public.shipments add constraint shipments_typed_priced_chk
  check (shipment_type is null or (rate_applied > 0 and amount = rate_applied));

create or replace function public.shipments_apply_rate()
returns trigger language plpgsql security definer set search_path = '' as $$
declare r record; v_bw numeric;
begin
  if new.shipment_type is null then
    -- manual / V2 shipments: user-entered amount, no pricing details
    new.rate_zone := null; new.rate_slab := null; new.rate_applied := null;
    return new;
  end if;
  v_bw := greatest(new.weight_f, new.weight_g, new.weight_h, new.weight_t);
  if v_bw is null then return new; end if;          -- shipments_type_weights_chk reports this
  select * into r from public.shipment_rate(new.owner_id, new.client_id, new.shipment_type,
                                            new.service, new.destination, v_bw);
  if r.rate is null then
    raise exception 'No rate: %', r.reason using errcode = 'P0001';
  end if;
  new.amount := r.rate; new.rate_applied := r.rate; new.rate_zone := r.zone_name; new.rate_slab := r.slab_label;
  return new;
end $$;
revoke all on function public.shipments_apply_rate() from public, anon, authenticated;

drop trigger if exists shipments_apply_rate on public.shipments;
create trigger shipments_apply_rate
  before insert or update of client_id, shipment_type, service, destination,
                             weight_f, weight_g, weight_h, weight_t, amount, rate_zone, rate_slab, rate_applied
  on public.shipments for each row execute function public.shipments_apply_rate();

-- Pricing columns are database-only: re-assert column grants without them.
revoke all on public.shipments from public, anon, authenticated;
grant select, delete on public.shipments to authenticated;
grant insert (client_id, awb, ship_date, destination, service, weight, pieces, amount,
              shipment_type, weight_f, weight_g, weight_h, weight_t) on public.shipments to authenticated;
grant update (client_id, awb, ship_date, destination, service, weight, pieces, amount,
              shipment_type, weight_f, weight_g, weight_h, weight_t) on public.shipments to authenticated;
grant all on public.shipments to service_role;

commit;
