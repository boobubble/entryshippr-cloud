-- =====================================================================
-- EntrySetu V2 — Phase 1: Client Name Mapping (Excel aliases / renamed
-- clients), raw Excel client name, Safe Client Delete.
-- DEVELOPMENT project zfvnqcyqxxipjaugkmvf ONLY.
-- FOR MANUAL REVIEW — run in the Supabase SQL Editor after all earlier
-- 2026-10-15 migrations. Re-runnable: creates only what is missing, never
-- drops tables or data. Client Merge is NOT part of this file.
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
  -- Tenant-scoped; a mapped client can never be deleted, so mappings never dangle.
  foreign key (owner_id, client_id) references public.clients (owner_id, id) on delete restrict
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
-- 3. Safe client delete
--    Direct DELETE revoked; delete_client():
--      * uses auth.uid() — no owner parameter, nothing to spoof
--      * requires an active plan
--      * locks the client row FOR UPDATE: concurrent inserts of shipments,
--        invoices, mappings or rate cards take KEY SHARE on it and wait, so the
--        counts cannot go stale; FK RESTRICT remains the final safety net
--      * refuses with shipments, invoices or mappings (deactivate instead)
--      * deletes rate cards only when the caller confirms their exact count
--    Deactivate keeps using the existing UPDATE of clients.active.
-- ---------------------------------------------------------------------
revoke delete on public.clients from authenticated;

drop function if exists public.client_usage(uuid);
create function public.client_usage(p_client_id uuid)
returns table (shipments bigint, billed_shipments bigint, invoices bigint, rate_cards bigint, mappings bigint)
language sql stable security invoker set search_path = '' as $$
  select
    (select pg_catalog.count(*) from public.shipments s where s.client_id = p_client_id and s.owner_id = auth.uid()),
    (select pg_catalog.count(*) from public.shipments s where s.client_id = p_client_id and s.owner_id = auth.uid() and s.invoice_id is not null),
    (select pg_catalog.count(*) from public.invoices i where i.client_id = p_client_id and i.owner_id = auth.uid()),
    (select pg_catalog.count(*) from public.rate_slabs r where r.client_id = p_client_id and r.owner_id = auth.uid())
      + (select pg_catalog.count(*) from public.rate_cards r where r.client_id = p_client_id and r.owner_id = auth.uid()),
    (select pg_catalog.count(*) from public.client_name_mappings m where m.client_id = p_client_id and m.owner_id = auth.uid())
$$;
revoke all on function public.client_usage(uuid) from public, anon;
grant execute on function public.client_usage(uuid) to authenticated, service_role;

drop function if exists public.delete_client(uuid, integer);
create function public.delete_client(p_client_id uuid, p_confirm_rate_cards integer default 0)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_ship bigint; v_inv bigint; v_map bigint; v_rc bigint;
begin
  if v_uid is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  if not public.has_access() then
    raise exception 'Your plan has expired — renew to make changes' using errcode = '42501';
  end if;

  perform 1 from public.clients c where c.id = p_client_id and c.owner_id = v_uid for update;
  if not found then raise exception 'Client not found' using errcode = 'P0002'; end if;

  select pg_catalog.count(*) into v_ship from public.shipments s where s.owner_id = v_uid and s.client_id = p_client_id;
  select pg_catalog.count(*) into v_inv  from public.invoices  i where i.owner_id = v_uid and i.client_id = p_client_id;
  select pg_catalog.count(*) into v_map  from public.client_name_mappings m where m.owner_id = v_uid and m.client_id = p_client_id;
  if v_ship > 0 or v_inv > 0 then
    raise exception 'Client has % shipment(s) and % invoice(s) — deactivate it instead', v_ship, v_inv using errcode = 'P0001';
  end if;
  if v_map > 0 then
    raise exception 'Client is used by % name mapping(s) — remove or re-point them first', v_map using errcode = 'P0001';
  end if;

  select (select pg_catalog.count(*) from public.rate_slabs r where r.owner_id = v_uid and r.client_id = p_client_id)
       + (select pg_catalog.count(*) from public.rate_cards r where r.owner_id = v_uid and r.client_id = p_client_id)
    into v_rc;
  if v_rc > 0 and v_rc is distinct from p_confirm_rate_cards::bigint then
    raise exception 'Client has % rate card row(s) — confirm deleting exactly % to continue', v_rc, v_rc using errcode = 'P0001';
  end if;

  delete from public.rate_slabs r where r.owner_id = v_uid and r.client_id = p_client_id;
  delete from public.rate_cards r where r.owner_id = v_uid and r.client_id = p_client_id;
  delete from public.clients c where c.id = p_client_id and c.owner_id = v_uid;
end $$;
revoke all on function public.delete_client(uuid, integer) from public, anon;
grant execute on function public.delete_client(uuid, integer) to authenticated;

commit;
