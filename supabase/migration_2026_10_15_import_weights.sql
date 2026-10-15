-- EntrySetu: Excel import weights + saved column mappings.
-- FOR REVIEW. Run once in your EntrySetu Supabase SQL Editor AFTER entrysetu_schema.sql. Safe to re-run.
-- Existing shipments/invoices are not modified (new columns are nullable; no data is rewritten).

begin;

alter table public.shipments
  add column if not exists shipment_type text check (shipment_type in ('DOX','NON-DOX')),
  add column if not exists weight_unit text check (weight_unit in ('g','kg')),
  add column if not exists weight_f numeric(12,3) check (weight_f > 0),
  add column if not exists weight_g numeric(12,3) check (weight_g > 0),
  add column if not exists weight_h numeric(12,3) check (weight_h > 0),
  add column if not exists weight_t numeric(12,3) check (weight_t > 0),
  add column if not exists billing_weight numeric(12,3) check (billing_weight > 0);

-- unit must match type (DOX = grams, NON-DOX = kilograms)
do $$ begin
  alter table public.shipments add constraint shipments_type_unit_chk check (
    (shipment_type is null and weight_unit is null)
    or (shipment_type = 'DOX' and weight_unit = 'g')
    or (shipment_type = 'NON-DOX' and weight_unit = 'kg'));
exception when duplicate_object then null; end $$;

grant insert (shipment_type, weight_unit, weight_f, weight_g, weight_h, weight_t, billing_weight) on public.shipments to authenticated;
grant update (shipment_type, weight_unit, weight_f, weight_g, weight_h, weight_t, billing_weight) on public.shipments to authenticated;

-- Saved column mappings, one row per name per tenant
create table if not exists public.import_mappings (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 60),
  mapping jsonb not null check (jsonb_typeof(mapping) = 'object'),
  updated_at timestamptz not null default now(),
  unique (owner_id, name)
);
grant select, delete on public.import_mappings to authenticated;
grant insert (name, mapping, updated_at) on public.import_mappings to authenticated;
grant update (name, mapping, updated_at) on public.import_mappings to authenticated;
grant all on public.import_mappings to service_role;
alter table public.import_mappings enable row level security;
drop policy if exists "import_mappings: own" on public.import_mappings;
create policy "import_mappings: own" on public.import_mappings for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

commit;
