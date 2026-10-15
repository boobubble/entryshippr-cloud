-- =====================================================================
-- EntrySetu V2 migration 1 of 3: Excel import weights + saved column mappings
-- Revision 3. FOR MANUAL REVIEW ONLY.
-- Run order (Supabase SQL Editor, NEW EntrySetu project only):
--   entrysetu_schema.sql
--   -> migration_2026_10_15_import_weights.sql        (this file)
--   -> migration_2026_10_15_rate_cards_zones.sql
--   -> migration_2026_10_15_permission_hardening.sql
--   -> migration_2026_10_15_security_tests.sql         (rolls back)
-- Idempotent: safe to re-run. Existing shipments/invoices are not rewritten.
--
-- Database-enforced rules:
--   * weight_f/g/h/t keep the original sheet values (3 decimals), > 0 or NULL.
--   * billing_weight is GENERATED = GREATEST(weight_f, weight_g, weight_h, weight_t)
--     (GREATEST ignores NULLs). It is stored exactly, in the shipment's own unit:
--     grams for DOX, kilograms for NON-DOX. Nobody can write it.
--   * weight_unit is GENERATED from shipment_type: DOX -> 'g', NON-DOX -> 'kg'.
--   * Typed shipments need >= 1 valid weight; untyped (manual / older V2 rows)
--     may not carry raw weights.
--   * The kg column `weight` (used by older kg rate cards and shown on invoices)
--     is derived by trigger and always ROUNDED UP, never down:
--       DOX     : ceil(billing grams) / 1000      e.g. 100.4 g -> 101 g -> 0.101 kg
--       NON-DOX : ceil(billing kg * 1000) / 1000
--     This is the same "billed weight" the slab matcher uses (see rate-card
--     migration and src/lib/rates.ts billedWeight()), so nothing is undercharged.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------
-- Replace plain columns left by an earlier draft with generated ones.
do $$
begin
  if exists (select 1 from pg_catalog.pg_attribute where attrelid = 'public.shipments'::regclass
             and attname = 'billing_weight' and not attisdropped and attgenerated = '') then
    alter table public.shipments drop column billing_weight;
  end if;
  if exists (select 1 from pg_catalog.pg_attribute where attrelid = 'public.shipments'::regclass
             and attname = 'weight_unit' and not attisdropped and attgenerated = '') then
    alter table public.shipments drop constraint if exists shipments_type_unit_chk;
    alter table public.shipments drop column weight_unit;
  end if;
end $$;

alter table public.shipments
  add column if not exists shipment_type text,
  add column if not exists weight_f numeric(12,3),
  add column if not exists weight_g numeric(12,3),
  add column if not exists weight_h numeric(12,3),
  add column if not exists weight_t numeric(12,3);

alter table public.shipments
  add column if not exists weight_unit text
    generated always as (case shipment_type when 'DOX' then 'g' when 'NON-DOX' then 'kg' end) stored,
  add column if not exists billing_weight numeric(12,3)
    generated always as (greatest(weight_f, weight_g, weight_h, weight_t)) stored;

-- ---------------------------------------------------------------------
-- 2. Constraints
-- ---------------------------------------------------------------------
alter table public.shipments drop constraint if exists shipments_type_chk;
alter table public.shipments add constraint shipments_type_chk
  check (shipment_type is null or shipment_type in ('DOX','NON-DOX'));

alter table public.shipments drop constraint if exists shipments_raw_weights_chk;
alter table public.shipments add constraint shipments_raw_weights_chk check (
      (weight_f is null or weight_f > 0) and (weight_g is null or weight_g > 0)
  and (weight_h is null or weight_h > 0) and (weight_t is null or weight_t > 0));

alter table public.shipments drop constraint if exists shipments_type_weights_chk;
alter table public.shipments add constraint shipments_type_weights_chk check (
  case when shipment_type is null
       then num_nonnulls(weight_f, weight_g, weight_h, weight_t) = 0
       else num_nonnulls(weight_f, weight_g, weight_h, weight_t) >= 1 end);

-- Typed shipments: kg weight must equal the rounded-up billed weight (belt and braces
-- on top of the trigger below; also guards service_role writes).
alter table public.shipments drop constraint if exists shipments_kg_weight_chk;
alter table public.shipments add constraint shipments_kg_weight_chk check (
  shipment_type is null
  or weight = case shipment_type
                when 'DOX' then ceil(greatest(weight_f, weight_g, weight_h, weight_t)) / 1000
                else ceil(greatest(weight_f, weight_g, weight_h, weight_t) * 1000) / 1000 end);

-- ---------------------------------------------------------------------
-- 3. Trigger: derive kg weight (never rounds down)
-- Generated columns are not visible in BEFORE triggers, so GREATEST is recomputed.
-- ---------------------------------------------------------------------
create or replace function public.shipments_sync_weight()
returns trigger language plpgsql security invoker set search_path = '' as $$
declare v_bw numeric;
begin
  if new.shipment_type is not null then
    v_bw := greatest(new.weight_f, new.weight_g, new.weight_h, new.weight_t);
    if v_bw is not null then
      new.weight := case new.shipment_type when 'DOX' then ceil(v_bw) / 1000
                                           else ceil(v_bw * 1000) / 1000 end;
    end if;
  end if;
  return new;
end $$;
revoke all on function public.shipments_sync_weight() from public, anon, authenticated;

drop trigger if exists shipments_sync_weight on public.shipments;
create trigger shipments_sync_weight
  before insert or update of shipment_type, weight_f, weight_g, weight_h, weight_t, weight
  on public.shipments for each row execute function public.shipments_sync_weight();

-- ---------------------------------------------------------------------
-- 4. Shipments grants: no table-wide INSERT/UPDATE for clients
-- Not writable by users: id, owner_id, invoice_id, created_at, weight_unit,
-- billing_weight (generated) and — after migration 2 — rate_zone/rate_slab/rate_applied.
-- ---------------------------------------------------------------------
revoke all on public.shipments from public, anon, authenticated;
grant select, delete on public.shipments to authenticated;     -- RLS limits to own, unbilled, active plan
grant insert (client_id, awb, ship_date, destination, service, weight, pieces, amount,
              shipment_type, weight_f, weight_g, weight_h, weight_t) on public.shipments to authenticated;
grant update (client_id, awb, ship_date, destination, service, weight, pieces, amount,
              shipment_type, weight_f, weight_g, weight_h, weight_t) on public.shipments to authenticated;
grant all on public.shipments to service_role;

-- ---------------------------------------------------------------------
-- 5. Saved column mappings
-- ---------------------------------------------------------------------
create table if not exists public.import_mappings (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 60),
  mapping jsonb not null check (jsonb_typeof(mapping) = 'object' and pg_column_size(mapping) <= 8192),
  updated_at timestamptz not null default now(),
  unique (owner_id, name)
);
revoke all on public.import_mappings from public, anon, authenticated;
grant select, delete on public.import_mappings to authenticated;
grant insert (name, mapping, updated_at) on public.import_mappings to authenticated;
grant update (name, mapping, updated_at) on public.import_mappings to authenticated;
grant all on public.import_mappings to service_role;

alter table public.import_mappings enable row level security;
drop policy if exists "import_mappings: own"        on public.import_mappings;
drop policy if exists "import_mappings: read own"   on public.import_mappings;
drop policy if exists "import_mappings: insert own" on public.import_mappings;
drop policy if exists "import_mappings: update own" on public.import_mappings;
drop policy if exists "import_mappings: delete own" on public.import_mappings;
create policy "import_mappings: read own" on public.import_mappings for select to authenticated
  using (owner_id = auth.uid());
create policy "import_mappings: insert own" on public.import_mappings for insert to authenticated
  with check (owner_id = auth.uid() and public.has_access());
create policy "import_mappings: update own" on public.import_mappings for update to authenticated
  using (owner_id = auth.uid() and public.has_access())
  with check (owner_id = auth.uid() and public.has_access());
create policy "import_mappings: delete own" on public.import_mappings for delete to authenticated
  using (owner_id = auth.uid() and public.has_access());

commit;
