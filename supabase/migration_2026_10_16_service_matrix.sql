-- =====================================================================
-- EntrySetu V1 — Service matrix. DEVELOPMENT ONLY (zfvnqcyqxxipjaugkmvf). Never run on production.
-- Run AFTER every 2026_10_15 migration. Re-runnable.
--
--   DOX      : Standard, Fast
--   NON-DOX  : Surface, Air, Fast
--
-- Option A (legacy kept): existing NON-DOX 'Standard' shipments and rate slabs stay exactly as they
-- are and stay valid, but nothing NEW can be created as (or changed into) NON-DOX Standard.
-- Legacy NON-DOX Standard rate cards can still price legacy shipments and can be deleted (saved
-- empty), but cannot be re-saved with slabs or copied to another client.
--
-- Pricing is unchanged: shipment_rate() matches service exactly, so Air never uses Surface/Fast
-- rates and Surface never uses Standard rates; a missing card stays Needs Review at 0.
-- Not touched: shipment_rate, shipments_apply_rate, invoices, numbering, GST, locks, audit.
-- =====================================================================

-- 1. Allowed (type, service) pairs, plus the legacy pair for existing rows -----------------
create or replace function public.service_allowed(p_type text, p_service text)
returns boolean language sql immutable set search_path = '' as $$
  select (p_type = 'DOX' and p_service in ('Standard','Fast'))
      or (p_type = 'NON-DOX' and p_service in ('Surface','Air','Fast'));
$$;
revoke all on function public.service_allowed(text, text) from public, anon;
grant execute on function public.service_allowed(text, text) to authenticated, service_role;

alter table public.rate_slabs drop constraint if exists rate_slabs_service_check;
alter table public.rate_slabs drop constraint if exists rate_slabs_service_matrix_chk;
alter table public.rate_slabs add constraint rate_slabs_service_matrix_chk
  check (public.service_allowed(shipment_type, service) or (shipment_type = 'NON-DOX' and service = 'Standard'));

alter table public.shipments drop constraint if exists shipments_typed_service_chk;
alter table public.shipments add constraint shipments_typed_service_chk
  check (shipment_type is null or public.service_allowed(shipment_type, service)
         or (shipment_type = 'NON-DOX' and service = 'Standard'));

-- 2. Legacy pair: allowed only on rows that already have it --------------------------------
create or replace function entrysetu_private.block_new_legacy_service()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.shipment_type = 'NON-DOX' and new.service = 'Standard'
     and (tg_op = 'INSERT' or old.shipment_type is distinct from 'NON-DOX' or old.service is distinct from 'Standard') then
    raise exception 'NON-DOX shipments use Surface, Air or Fast' using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function entrysetu_private.block_new_legacy_service() from public, anon, authenticated;

drop trigger if exists shipments_aa_service_matrix on public.shipments;
create trigger shipments_aa_service_matrix before insert or update of shipment_type, service
  on public.shipments for each row execute function entrysetu_private.block_new_legacy_service();
drop trigger if exists rate_slabs_aa_service_matrix on public.rate_slabs;
create trigger rate_slabs_aa_service_matrix before insert or update of shipment_type, service
  on public.rate_slabs for each row execute function entrysetu_private.block_new_legacy_service();

-- 3. save_rate_card: same body as 2026_10_15, only the service check changes ---------------
create or replace function public.save_rate_card(p_client uuid, p_type text, p_service text, p_slabs jsonb)
returns int language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_prev numeric; r record; v_n int := 0; k text;
begin
  if v_uid is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  if not public.has_access() then raise exception 'Your trial or plan has expired' using errcode = '42501'; end if;
  if p_type is null or p_type not in ('DOX','NON-DOX') or p_service is null then
    raise exception 'Invalid type or service' using errcode = 'P0001'; end if;
  if p_slabs is null or jsonb_typeof(p_slabs) <> 'array' or jsonb_array_length(p_slabs) > 200 then
    raise exception 'Invalid slabs' using errcode = 'P0001'; end if;
  -- legacy NON-DOX Standard: may only be cleared (saved empty), never filled
  if not public.service_allowed(p_type, p_service)
     and not (p_type = 'NON-DOX' and p_service = 'Standard' and jsonb_array_length(p_slabs) = 0) then
    raise exception 'Invalid type or service' using errcode = 'P0001'; end if;
  if p_client is not null and not exists (select 1 from public.clients c where c.id = p_client and c.owner_id = v_uid) then
    raise exception 'Client not found' using errcode = '42501'; end if;

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

-- 4. copy_rate_cards: same body, legacy NON-DOX Standard slabs are not copied --------------
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
    from public.rate_slabs s where s.owner_id = v_uid and s.client_id is not distinct from p_from
     and public.service_allowed(s.shipment_type, s.service);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

revoke all on function public.save_rate_card(uuid, text, text, jsonb) from public, anon;
revoke all on function public.copy_rate_cards(uuid, uuid, boolean) from public, anon;
grant execute on function public.save_rate_card(uuid, text, text, jsonb) to authenticated, service_role;
grant execute on function public.copy_rate_cards(uuid, uuid, boolean) to authenticated, service_role;
