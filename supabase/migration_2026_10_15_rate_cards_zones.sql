-- EntrySetu: client-wise DOX / NON-DOX rate cards with zone-wise slab pricing.
-- FOR REVIEW. Run once in the Supabase SQL Editor AFTER entrysetu_schema.sql and
-- migration_2026_10_15_import_weights.sql. Safe to re-run. Does not change existing
-- rate_cards rows, shipments or invoices (old kg slabs keep working as a fallback).

begin;

-- 1. Zones (destinations -> zone), per seller
create table if not exists public.zones (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 60),
  destinations text[] not null default '{}',
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  unique (owner_id, name)
);
create index if not exists zones_owner_idx on public.zones (owner_id, sort_order);
grant select, delete on public.zones to authenticated;
grant insert (name, destinations, sort_order) on public.zones to authenticated;
grant update (name, destinations, sort_order) on public.zones to authenticated;
grant all on public.zones to service_role;
alter table public.zones enable row level security;
drop policy if exists "zones: read own" on public.zones;
drop policy if exists "zones: write own (active plan)" on public.zones;
create policy "zones: read own" on public.zones for select to authenticated using (owner_id = auth.uid());
create policy "zones: write own (active plan)" on public.zones for all to authenticated
  using (owner_id = auth.uid() and public.has_access())
  with check (owner_id = auth.uid() and public.has_access());

-- 2. Weight slabs. Weights are grams for DOX, kilograms for NON-DOX.
--    rates = {"<zone uuid>": 45.00, ...}; a zone with no entry has no rate (flagged at billing).
create table if not exists public.rate_slabs (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  client_id uuid,                                   -- null = default for all clients
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
grant select on public.rate_slabs to authenticated;
grant all on public.rate_slabs to service_role;
alter table public.rate_slabs enable row level security;
drop policy if exists "rate_slabs: read own" on public.rate_slabs;
create policy "rate_slabs: read own" on public.rate_slabs for select to authenticated using (owner_id = auth.uid());
-- Writes only through the functions below (validated, all-or-nothing).

-- 3. Save one card (client + type + service) atomically, with validation
create or replace function public.save_rate_card(p_client uuid, p_type text, p_service text, p_slabs jsonb)
returns int language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_prev numeric; r record; v_n int := 0; k text;
begin
  if v_uid is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  if not public.has_access() then raise exception 'Your trial or plan has expired' using errcode = '42501'; end if;
  if p_type not in ('DOX','NON-DOX') or p_service not in ('Standard','Fast') then raise exception 'Invalid type or service'; end if;
  if p_client is not null and not exists (select 1 from clients where id = p_client and owner_id = v_uid) then
    raise exception 'Client not found' using errcode = '42501'; end if;
  if jsonb_typeof(p_slabs) <> 'array' or jsonb_array_length(p_slabs) > 200 then raise exception 'Invalid slabs'; end if;

  for r in select (e->>'min_weight')::numeric mn, (e->>'max_weight')::numeric mx, coalesce(e->'rates','{}'::jsonb) rates
           from jsonb_array_elements(p_slabs) e order by (e->>'min_weight')::numeric loop
    if r.mn is null or r.mx is null or r.mn < 0 or r.mx <= r.mn then raise exception 'Slab % – % is invalid', r.mn, r.mx; end if;
    if v_prev is not null and r.mn < v_prev then raise exception 'Slab starting at % overlaps the previous slab', r.mn; end if;
    for k in select jsonb_object_keys(r.rates) loop
      if not exists (select 1 from zones where id = k::uuid and owner_id = v_uid) then raise exception 'Unknown zone in rates'; end if;
      if jsonb_typeof(r.rates->k) <> 'number' or (r.rates->>k)::numeric < 0 then raise exception 'Rates must be 0 or more'; end if;
    end loop;
    v_prev := r.mx;
  end loop;

  delete from rate_slabs where owner_id = v_uid and client_id is not distinct from p_client
    and shipment_type = p_type and service = p_service;
  insert into rate_slabs (owner_id, client_id, shipment_type, service, min_weight, max_weight, rates, sort_order)
  select v_uid, p_client, p_type, p_service, (e->>'min_weight')::numeric, (e->>'max_weight')::numeric,
         coalesce(e->'rates','{}'::jsonb), o::int
  from jsonb_array_elements(p_slabs) with ordinality as t(e, o);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- 4. Copy all cards (both types, both services) from one client to another
create or replace function public.copy_rate_cards(p_from uuid, p_to uuid, p_replace boolean)
returns int language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_n int;
begin
  if v_uid is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  if not public.has_access() then raise exception 'Your trial or plan has expired' using errcode = '42501'; end if;
  if p_from is not distinct from p_to then raise exception 'Choose a different client'; end if;
  if (p_from is not null and not exists (select 1 from clients where id = p_from and owner_id = v_uid))
     or (p_to is not null and not exists (select 1 from clients where id = p_to and owner_id = v_uid)) then
    raise exception 'Client not found' using errcode = '42501'; end if;
  if exists (select 1 from rate_slabs where owner_id = v_uid and client_id is not distinct from p_to) then
    if not p_replace then raise exception 'TARGET_HAS_RATES'; end if;
    delete from rate_slabs where owner_id = v_uid and client_id is not distinct from p_to;
  end if;
  insert into rate_slabs (owner_id, client_id, shipment_type, service, min_weight, max_weight, rates, sort_order)
  select v_uid, p_to, shipment_type, service, min_weight, max_weight, rates, sort_order
  from rate_slabs where owner_id = v_uid and client_id is not distinct from p_from;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

revoke all on function public.save_rate_card(uuid, text, text, jsonb) from public, anon;
revoke all on function public.copy_rate_cards(uuid, uuid, boolean) from public, anon;
grant execute on function public.save_rate_card(uuid, text, text, jsonb) to authenticated;
grant execute on function public.copy_rate_cards(uuid, uuid, boolean) to authenticated;

-- 5. Record how each new shipment was priced (shown on invoices). Existing rows stay null.
alter table public.shipments
  add column if not exists rate_zone text check (char_length(rate_zone) <= 60),
  add column if not exists rate_slab text check (char_length(rate_slab) <= 60),
  add column if not exists rate_applied numeric(12,2) check (rate_applied >= 0);
grant insert (rate_zone, rate_slab, rate_applied) on public.shipments to authenticated;
grant update (rate_zone, rate_slab, rate_applied) on public.shipments to authenticated;

commit;
