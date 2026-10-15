-- =====================================================================
-- EntrySetu V2 migration: Excel import weights + saved column mappings
-- Revision 2 (reviewed). FOR MANUAL REVIEW — run once in the Supabase SQL
-- Editor of the NEW EntrySetu project, AFTER entrysetu_schema.sql and BEFORE
-- migration_2026_10_15_rate_cards_zones.sql. Safe to re-run.
--
-- Guarantees enforced by the database (not just the app):
--   * billing_weight is a GENERATED column = GREATEST(weight_f, weight_g,
--     weight_h, weight_t). Nobody can write it; NULL/empty weights are ignored
--     by GREATEST, and zero/negative weights are rejected by CHECKs.
--   * weight_unit is GENERATED from shipment_type: DOX -> 'g', NON-DOX -> 'kg'.
--   * A typed shipment must have at least one valid weight; an untyped
--     (manual / older) shipment may not carry the four raw weights.
--   * For typed shipments, the kg column `weight` used by rate cards and
--     invoices is set by trigger from billing_weight (DOX g / 1000), so g and
--     kg can never be mixed.
--
-- Grants: Supabase gives anon/authenticated table-wide privileges on new
-- public tables by default. This migration REVOKES table-wide INSERT/UPDATE on
-- shipments and import_mappings and re-grants only column-level rights. RLS
-- policies on shipments are not touched.
--
-- Existing shipments and invoices are not modified: all new columns are
-- nullable and no existing row is rewritten.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Shipments: raw weights, type, generated unit + billing weight
-- ---------------------------------------------------------------------

-- If an earlier draft of this migration created plain (non-generated)
-- billing_weight / weight_unit columns, replace them with generated ones.
do $$
begin
  if exists (select 1 from pg_attribute where attrelid = 'public.shipments'::regclass
             and attname = 'billing_weight' and not attisdropped and attgenerated = '') then
    alter table public.shipments drop column billing_weight;
  end if;
  if exists (select 1 from pg_attribute where attrelid = 'public.shipments'::regclass
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

-- Constraints (named, so re-runs are idempotent)
alter table public.shipments drop constraint if exists shipments_type_chk;
alter table public.shipments add constraint shipments_type_chk
  check (shipment_type is null or shipment_type in ('DOX','NON-DOX'));

alter table public.shipments drop constraint if exists shipments_raw_weights_chk;
alter table public.shipments add constraint shipments_raw_weights_chk check (
      (weight_f is null or weight_f > 0)
  and (weight_g is null or weight_g > 0)
  and (weight_h is null or weight_h > 0)
  and (weight_t is null or weight_t > 0));

-- typed => at least one valid weight; untyped => no raw weights
alter table public.shipments drop constraint if exists shipments_type_weights_chk;
alter table public.shipments add constraint shipments_type_weights_chk check (
  case when shipment_type is null
       then num_nonnulls(weight_f, weight_g, weight_h, weight_t) = 0
       else num_nonnulls(weight_f, weight_g, weight_h, weight_t) >= 1 end);

-- Derive the kg `weight` from the billing weight for typed shipments.
-- (Generated columns are not visible in BEFORE triggers, so recompute GREATEST.)
create or replace function public.shipments_sync_weight()
returns trigger language plpgsql security invoker set search_path = public, pg_temp as $$
declare v_bw numeric;
begin
  if new.shipment_type is not null then
    v_bw := greatest(new.weight_f, new.weight_g, new.weight_h, new.weight_t);
    new.weight := round(case new.shipment_type when 'DOX' then v_bw / 1000 else v_bw end, 3);
  end if;
  return new;
end $$;
revoke all on function public.shipments_sync_weight() from public, anon, authenticated;

drop trigger if exists shipments_sync_weight on public.shipments;
create trigger shipments_sync_weight
  before insert or update of shipment_type, weight_f, weight_g, weight_h, weight_t, weight
  on public.shipments for each row execute function public.shipments_sync_weight();

-- ---------------------------------------------------------------------
-- 2. Shipments grants: column-level only
-- ---------------------------------------------------------------------
revoke insert, update, truncate, references, trigger on public.shipments from public, anon, authenticated;
revoke all on public.shipments from anon;

-- Re-grant exactly the V2 writable columns plus the new raw-weight columns.
-- Not writable by users: id, owner_id, invoice_id, created_at,
-- weight_unit, billing_weight (generated).
grant insert (client_id, awb, ship_date, destination, service, weight, pieces, amount,
              shipment_type, weight_f, weight_g, weight_h, weight_t)
  on public.shipments to authenticated;
grant update (client_id, awb, ship_date, destination, service, weight, pieces, amount,
              shipment_type, weight_f, weight_g, weight_h, weight_t)
  on public.shipments to authenticated;
grant select, delete on public.shipments to authenticated;   -- unchanged from V2; RLS still applies
grant all on public.shipments to service_role;

-- ---------------------------------------------------------------------
-- 3. Saved column mappings (one row per name per seller)
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
drop policy if exists "import_mappings: own"              on public.import_mappings;
drop policy if exists "import_mappings: read own"         on public.import_mappings;
drop policy if exists "import_mappings: insert own"       on public.import_mappings;
drop policy if exists "import_mappings: update own"       on public.import_mappings;
drop policy if exists "import_mappings: delete own"       on public.import_mappings;
-- Reading is always allowed; writes follow the same active-plan rule as the rest of V2.
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

-- ---------------------------------------------------------------------
-- Optional checks after running (read-only):
--   select grantee, privilege_type from information_schema.role_table_grants
--    where table_name in ('shipments','import_mappings') order by 1,2;
--   -- authenticated should show only SELECT, DELETE at table level.
--   select grantee, column_name, privilege_type from information_schema.column_privileges
--    where table_name = 'shipments' and grantee = 'authenticated' order by 2,3;
-- ---------------------------------------------------------------------
