-- =====================================================================
-- EntrySetu V2 — Phase 1: Client Rename + Excel Alias Mapping,
-- raw Excel client name, invoice bill-to snapshots.
-- DEVELOPMENT project zfvnqcyqxxipjaugkmvf ONLY.
-- FOR MANUAL REVIEW — run in the Supabase SQL Editor after all earlier
-- 2026-10-15 migrations. Re-runnable: creates only what is missing, never
-- drops tables or data. Safe Delete and Client Merge are NOT part of this
-- file; the existing client DELETE permission is left unchanged.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. Seller-specific client name mappings: raw Excel name -> client_id
-- ---------------------------------------------------------------------
create table if not exists public.client_name_mappings (
  owner_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  alias_norm text not null check (alias_norm <> '' and char_length(alias_norm) <= 200),
  raw_name   text not null check (char_length(btrim(raw_name)) between 1 and 200),
  client_id  uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- One mapping per normalised raw name per seller. A conflicting INSERT, or an
  -- UPDATE that renames onto an existing alias, fails with 23505 — never overwrites.
  primary key (owner_id, alias_norm),
  -- Tenant-scoped. ON DELETE CASCADE keeps the existing Delete button working
  -- and guarantees a mapping never points to a deleted client.
  foreign key (owner_id, client_id) references public.clients (owner_id, id) on delete cascade
);
create index if not exists client_name_mappings_client_idx on public.client_name_mappings (owner_id, client_id);

-- alias_norm is derived from raw_name (trim, collapse spaces, lowercase) —
-- same rule as nameKey() in src/lib/text.ts. owner_id can never change.
create or replace function public.client_name_mappings_normalise()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  new.raw_name   := pg_catalog.regexp_replace(pg_catalog.btrim(new.raw_name), '\s+', ' ', 'g');
  new.alias_norm := pg_catalog.lower(new.raw_name);
  if new.alias_norm is null or new.alias_norm = '' then
    raise exception 'Client name is required' using errcode = 'P0001';
  end if;
  if tg_op = 'UPDATE' then
    if new.owner_id is distinct from old.owner_id then
      raise exception 'Mapping owner cannot change' using errcode = '42501';
    end if;
    new.created_at := old.created_at;
    new.updated_at := pg_catalog.now();
  end if;
  return new;
end $$;
revoke all on function public.client_name_mappings_normalise() from public, anon, authenticated;
drop trigger if exists client_name_mappings_normalise on public.client_name_mappings;
create trigger client_name_mappings_normalise before insert or update on public.client_name_mappings
  for each row execute function public.client_name_mappings_normalise();

-- Minimum grants: owner_id / alias_norm / timestamps are never client-writable.
revoke all on public.client_name_mappings from public, anon, authenticated;
grant select, delete on public.client_name_mappings to authenticated;
grant insert (raw_name, client_id) on public.client_name_mappings to authenticated;
grant update (raw_name, client_id) on public.client_name_mappings to authenticated;
grant all on public.client_name_mappings to service_role;

alter table public.client_name_mappings enable row level security;
drop policy if exists "client_name_mappings: read own" on public.client_name_mappings;
create policy "client_name_mappings: read own" on public.client_name_mappings
  for select to authenticated using (owner_id = auth.uid());
drop policy if exists "client_name_mappings: insert own (active plan)" on public.client_name_mappings;
create policy "client_name_mappings: insert own (active plan)" on public.client_name_mappings
  for insert to authenticated with check (owner_id = auth.uid() and public.has_access());
drop policy if exists "client_name_mappings: update own (active plan)" on public.client_name_mappings;
create policy "client_name_mappings: update own (active plan)" on public.client_name_mappings
  for update to authenticated
  using (owner_id = auth.uid() and public.has_access())
  with check (owner_id = auth.uid() and public.has_access());
drop policy if exists "client_name_mappings: delete own (active plan)" on public.client_name_mappings;
create policy "client_name_mappings: delete own (active plan)" on public.client_name_mappings
  for delete to authenticated using (owner_id = auth.uid() and public.has_access());

-- ---------------------------------------------------------------------
-- 2. Original Excel client name on shipments — insert-only, existing rows untouched
-- ---------------------------------------------------------------------
alter table public.shipments add column if not exists source_client_name text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'shipments_source_client_name_len'
                 and conrelid = 'public.shipments'::regclass) then
    alter table public.shipments add constraint shipments_source_client_name_len
      check (source_client_name is null or char_length(source_client_name) <= 200);
  end if;
end $$;
grant insert (source_client_name) on public.shipments to authenticated;
revoke update (source_client_name) on public.shipments from authenticated;

-- ---------------------------------------------------------------------
-- 3. Invoice bill-to snapshots
--    Each invoice keeps the client's billing name, GSTIN, state and address
--    as they were when it was issued, so renaming or editing a client never
--    changes a finalized invoice. Numbers, amounts and GST are untouched.
-- ---------------------------------------------------------------------
alter table public.invoices add column if not exists bill_to_name    text;
alter table public.invoices add column if not exists bill_to_gstin   text;
alter table public.invoices add column if not exists bill_to_state   text;
alter table public.invoices add column if not exists bill_to_address text;

-- Fill on insert (create_invoice inserts invoices; it is not modified).
create or replace function public.invoices_snapshot_client()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  select c.name, nullif(c.gstin, ''), c.state, c.address
    into new.bill_to_name, new.bill_to_gstin, new.bill_to_state, new.bill_to_address
    from public.clients c where c.id = new.client_id and c.owner_id = new.owner_id;
  return new;
end $$;
revoke all on function public.invoices_snapshot_client() from public, anon, authenticated;
drop trigger if exists invoices_snapshot_client on public.invoices;
create trigger invoices_snapshot_client before insert on public.invoices
  for each row execute function public.invoices_snapshot_client();

-- Once set, a snapshot can never change (empty -> value is allowed once, for the backfill).
create or replace function public.invoices_snapshot_guard()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if old.status::text = 'draft' then return new; end if;   -- drafts (invoice editor) may refresh
  if (old.bill_to_name is not null and new.bill_to_name is distinct from old.bill_to_name)
     or (old.bill_to_name is not null and (new.bill_to_gstin is distinct from old.bill_to_gstin
         or new.bill_to_state is distinct from old.bill_to_state
         or new.bill_to_address is distinct from old.bill_to_address)) then
    raise exception 'Invoice billing details are frozen once issued' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function public.invoices_snapshot_guard() from public, anon, authenticated;
drop trigger if exists invoices_snapshot_guard on public.invoices;
create trigger invoices_snapshot_guard before update on public.invoices
  for each row execute function public.invoices_snapshot_guard();

-- Backfill existing invoices once with the client's CURRENT details (only rows
-- without a snapshot; re-running changes nothing). Run this migration BEFORE
-- renaming any client so old invoices freeze the original names.
update public.invoices i
   set bill_to_name = c.name, bill_to_gstin = nullif(c.gstin, ''), bill_to_state = c.state, bill_to_address = c.address
  from public.clients c
 where i.bill_to_name is null and c.id = i.client_id and c.owner_id = i.owner_id;

-- Sellers can still only SELECT invoices (existing grant); no write grant is added.

commit;
