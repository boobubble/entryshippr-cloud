-- =====================================================================
-- EntrySetu V2 migration 4: GLOBAL cities + SELLER-SPECIFIC city -> zone mapping.
-- FOR MANUAL REVIEW ONLY — run in the NEW EntrySetu development project only, after:
--   entrysetu_schema.sql -> migration_2026_10_15_import_weights.sql
--   -> migration_2026_10_15_rate_cards_zones.sql -> migration_2026_10_15_permission_hardening.sql
--   -> THIS FILE -> migration_2026_10_15_security_tests.sql -> migration_2026_10_15_cities_tests.sql
-- Idempotent. Existing shipments, invoices and rate cards are not rewritten.
--
-- Model
--   cities               global, read-only for users. Unique per (normalised name, state).
--                        Same name in two states (e.g. Aurangabad MH / BR) = ambiguous.
--   city_aliases         global spelling variants (Bombay -> Mumbai). Written only by the
--                        reviewed registry sync (service_role).
--   seller_city_zones    seller's city -> zone assignment (tenant-isolated by RLS + FK).
--   seller_city_aliases  seller-confirmed meaning of a name (resolves ambiguity / typos).
--
-- Pricing chain (database is the source of truth; src/lib/rates.ts mirrors it):
--   city text -> resolve city (seller alias > unique global match > seller-mapped candidate)
--   -> seller zone -> client card, else Default card -> DOX/NON-DOX -> Standard/Fast
--   -> billed-weight slab -> zone rate -> amount.
--   If no zone-wise card exists for that client/type/service, the older kg rate_cards
--   (no zones) still apply, as before.
--   Any failure (unknown/ambiguous city, no zone, no card/slab/rate) stores the
--   shipment as pricing_status = 'needs_review' with amount 0 and a reason. It is
--   re-priced automatically when the seller assigns a zone, confirms a city or saves
--   rates, and it can never be invoiced while it needs review. Never ₹0 on an invoice,
--   never a default zone.
--
-- Migration from zones.destinations: every existing destination is registered as a
-- city (if new) and mapped to its zone for that seller. Names matching several global
-- cities are left unmapped for the seller to confirm. zones.destinations is kept as a
-- deprecated, read-compatible input (writing it also maps the cities).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Normalisation (mirrors normCity() in src/lib/cities.ts)
-- ---------------------------------------------------------------------
create or replace function public.norm_city(p text)
returns text language sql immutable parallel safe set search_path = '' as $$
  select nullif(btrim(regexp_replace(lower(coalesce(p, '')), '[^a-z0-9]+', ' ', 'g')), '')
$$;
create or replace function public.display_city(p text)
returns text language sql immutable parallel safe set search_path = '' as $$
  select initcap(btrim(regexp_replace(coalesce(p, ''), '\s+', ' ', 'g')))
$$;

-- ---------------------------------------------------------------------
-- 2. Global tables
-- ---------------------------------------------------------------------
create table if not exists public.cities (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 80),
  name_norm text not null check (name_norm = public.norm_city(name) and name_norm ~ '[a-z]'),
  state text check (state is null or public.gst_state_code(state) is not null),
  source text not null default 'user' check (source in ('registry','migrated','user')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create unique index if not exists cities_norm_state_uidx on public.cities (name_norm, coalesce(lower(state), ''));
create index if not exists cities_norm_idx on public.cities (name_norm);

create table if not exists public.city_aliases (
  alias_norm text not null check (alias_norm = public.norm_city(alias_norm) and alias_norm ~ '[a-z]'),
  city_id uuid not null references public.cities(id) on delete cascade,
  primary key (alias_norm, city_id)
);

revoke all on public.cities from public, anon, authenticated;
revoke all on public.city_aliases from public, anon, authenticated;
grant select on public.cities, public.city_aliases to authenticated;
grant all on public.cities, public.city_aliases to service_role;
alter table public.cities enable row level security;
alter table public.city_aliases enable row level security;
drop policy if exists "cities: read" on public.cities;
drop policy if exists "city_aliases: read" on public.city_aliases;
create policy "cities: read" on public.cities for select to authenticated using (true);
create policy "city_aliases: read" on public.city_aliases for select to authenticated using (true);

-- ---------------------------------------------------------------------
-- 3. Seller tables
-- ---------------------------------------------------------------------
do $$ begin
  alter table public.zones add constraint zones_owner_id_uniq unique (owner_id, id);
exception when duplicate_table or duplicate_object then null; end $$;

create table if not exists public.seller_city_zones (
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  city_id uuid not null references public.cities(id) on delete cascade,
  zone_id uuid not null,
  updated_at timestamptz not null default now(),
  primary key (owner_id, city_id),
  foreign key (owner_id, zone_id) references public.zones (owner_id, id) on delete cascade
);
create index if not exists seller_city_zones_zone_idx on public.seller_city_zones (owner_id, zone_id);

create table if not exists public.seller_city_aliases (
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  alias_norm text not null check (alias_norm ~ '[a-z]' and char_length(alias_norm) <= 80),
  city_id uuid not null references public.cities(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (owner_id, alias_norm)
);

create or replace function public.seller_alias_normalise()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  new.alias_norm := public.norm_city(new.alias_norm);
  if new.alias_norm is null then raise exception 'Invalid city name' using errcode = 'P0001'; end if;
  return new;
end $$;
revoke all on function public.seller_alias_normalise() from public, anon, authenticated;
drop trigger if exists seller_alias_normalise on public.seller_city_aliases;
create trigger seller_alias_normalise before insert or update on public.seller_city_aliases
  for each row execute function public.seller_alias_normalise();

revoke all on public.seller_city_zones from public, anon, authenticated;
revoke all on public.seller_city_aliases from public, anon, authenticated;
grant select, delete on public.seller_city_zones, public.seller_city_aliases to authenticated;
grant insert (city_id, zone_id, updated_at) on public.seller_city_zones to authenticated;
grant update (zone_id, updated_at) on public.seller_city_zones to authenticated;
grant insert (alias_norm, city_id) on public.seller_city_aliases to authenticated;
grant update (city_id) on public.seller_city_aliases to authenticated;
grant all on public.seller_city_zones, public.seller_city_aliases to service_role;

alter table public.seller_city_zones enable row level security;
alter table public.seller_city_aliases enable row level security;
do $$ declare t text; begin
  foreach t in array array['seller_city_zones','seller_city_aliases'] loop
    execute format('drop policy if exists "%s: read own" on public.%I', t, t);
    execute format('drop policy if exists "%s: insert own" on public.%I', t, t);
    execute format('drop policy if exists "%s: update own" on public.%I', t, t);
    execute format('drop policy if exists "%s: delete own" on public.%I', t, t);
    execute format('create policy "%s: read own" on public.%I for select to authenticated using (owner_id = auth.uid())', t, t);
    execute format('create policy "%s: insert own" on public.%I for insert to authenticated with check (owner_id = auth.uid() and public.has_access())', t, t);
    execute format('create policy "%s: update own" on public.%I for update to authenticated using (owner_id = auth.uid() and public.has_access()) with check (owner_id = auth.uid() and public.has_access())', t, t);
    execute format('create policy "%s: delete own" on public.%I for delete to authenticated using (owner_id = auth.uid() and public.has_access())', t, t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 4. Resolution helpers (internal)
-- ---------------------------------------------------------------------
-- status: ok | unknown | ambiguous | empty | invalid
create or replace function public.city_resolve(p_owner uuid, p_text text)
returns table (status text, city_id uuid, candidates jsonb)
language plpgsql stable security definer set search_path = '' as $$
declare v_norm text := public.norm_city(p_text); v_id uuid; v_ids uuid[]; v_mapped uuid[];
begin
  if v_norm is null then return query select 'empty', null::uuid, null::jsonb; return; end if;
  if v_norm !~ '[a-z]' or char_length(v_norm) > 80 or char_length(v_norm) < 2 then
    return query select 'invalid', null::uuid, null::jsonb; return; end if;
  select a.city_id into v_id from public.seller_city_aliases a where a.owner_id = p_owner and a.alias_norm = v_norm;
  if v_id is not null then return query select 'ok', v_id, null::jsonb; return; end if;
  select array_agg(distinct x.id) into v_ids from (
    select c.id from public.cities c where c.name_norm = v_norm
    union select a.city_id from public.city_aliases a where a.alias_norm = v_norm) x;
  if v_ids is null then return query select 'unknown', null::uuid, null::jsonb; return; end if;
  if cardinality(v_ids) = 1 then return query select 'ok', v_ids[1], null::jsonb; return; end if;
  select array_agg(m.city_id) into v_mapped from public.seller_city_zones m where m.owner_id = p_owner and m.city_id = any(v_ids);
  if cardinality(v_mapped) = 1 then return query select 'ok', v_mapped[1], null::jsonb; return; end if;
  return query select 'ambiguous', null::uuid,
    (select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'state', c.state) order by c.state nulls first)
       from public.cities c where c.id = any(v_ids));
end $$;

-- Registers an unknown, valid city name (global, source 'user'); returns its id.
create or replace function public.ensure_city(p_text text, p_source text, p_by uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_norm text := public.norm_city(p_text); v_id uuid;
begin
  if v_norm is null or v_norm !~ '[a-z]' or char_length(v_norm) not between 2 and 80 then return null; end if;
  insert into public.cities (name, name_norm, source, created_by)
  values (public.display_city(p_text), v_norm, p_source, p_by)
  on conflict (name_norm, coalesce(lower(state), '')) do nothing
  returning id into v_id;
  if v_id is null then
    select c.id into v_id from public.cities c where c.name_norm = v_norm and c.state is null;
  end if;
  return v_id;
end $$;

-- city text -> (city_id, zone) for a seller, registering unknown cities.
create or replace function public.city_zone(p_owner uuid, p_text text, p_register boolean)
returns table (status text, city_id uuid, zone_id uuid, zone_name text, reason text, candidates jsonb)
language plpgsql security definer set search_path = '' as $$
declare r record; v_city uuid; v_zone public.zones; v_disp text := public.display_city(p_text);
begin
  select * into r from public.city_resolve(p_owner, p_text);
  if r.status = 'empty' then return query select 'invalid', null::uuid, null::uuid, null::text, 'No destination city', null::jsonb; return; end if;
  if r.status = 'invalid' then return query select 'invalid', null::uuid, null::uuid, null::text, format('"%s" is not a valid city name', v_disp), null::jsonb; return; end if;
  if r.status = 'ambiguous' then
    return query select 'ambiguous', null::uuid, null::uuid, null::text, format('City "%s" matches several cities — confirm which one', v_disp), r.candidates; return; end if;
  v_city := r.city_id;
  if r.status = 'unknown' then
    v_city := case when p_register then public.ensure_city(p_text, 'user', p_owner) end;
  end if;
  select z.* into v_zone from public.seller_city_zones m join public.zones z on z.id = m.zone_id and z.owner_id = m.owner_id
   where m.owner_id = p_owner and m.city_id = v_city;
  if not found then
    return query select 'unmapped', v_city, null::uuid, null::text, format('City "%s" has no zone', v_disp), null::jsonb; return; end if;
  return query select 'mapped', v_city, v_zone.id, v_zone.name, null::text, null::jsonb;
end $$;

revoke all on function public.city_resolve(uuid, text) from public, anon, authenticated;
revoke all on function public.ensure_city(text, text, uuid) from public, anon, authenticated;
revoke all on function public.city_zone(uuid, text, boolean) from public, anon, authenticated;
grant execute on function public.norm_city(text), public.display_city(text) to authenticated, service_role;
grant execute on function public.city_resolve(uuid, text), public.ensure_city(text, text, uuid), public.city_zone(uuid, text, boolean) to service_role;

-- ---------------------------------------------------------------------
-- 5. User RPC: resolve (and register, if plan active) a list of city names
-- ---------------------------------------------------------------------
create or replace function public.register_cities(p_names text[])
returns table (input text, status text, city_id uuid, city_name text, state text, zone_id uuid, zone_name text, reason text, candidates jsonb)
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_reg boolean; n text; r record;
begin
  if v_uid is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  if p_names is null or cardinality(p_names) > 2000 then raise exception 'Too many cities (max 2000)' using errcode = 'P0001'; end if;
  v_reg := public.has_access();
  for n in select distinct x from unnest(p_names) x where x is not null loop
    select * into r from public.city_zone(v_uid, n, v_reg);
    return query select n, r.status, r.city_id, c.name, c.state, r.zone_id, r.zone_name, r.reason, r.candidates
      from (select 1) d left join public.cities c on c.id = r.city_id;
  end loop;
end $$;
revoke all on function public.register_cities(text[]) from public, anon;
grant execute on function public.register_cities(text[]) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 6. Reviewed registry sync (service_role only; never touches seller tables)
--    p = [{"name":"Mumbai","state":"Maharashtra","aliases":["Bombay"]}, ...]
-- ---------------------------------------------------------------------
create or replace function public.sync_cities(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e jsonb; v_norm text; v_state text; v_id uuid; v_same int; a text; v_added int := 0; v_updated int := 0; v_alias int := 0;
begin
  if jsonb_typeof(p) <> 'array' or jsonb_array_length(p) > 20000 then raise exception 'Invalid registry'; end if;
  for e in select * from jsonb_array_elements(p) loop
    v_norm := public.norm_city(e->>'name');
    v_state := nullif(btrim(e->>'state'), '');
    if v_norm is null or v_norm !~ '[a-z]' or (v_state is not null and public.gst_state_code(v_state) is null) then continue; end if;
    select c.id into v_id from public.cities c where c.name_norm = v_norm and lower(coalesce(c.state, '')) = lower(coalesce(v_state, ''));
    if v_id is null and v_state is not null then
      -- adopt an existing state-less city only when the registry has exactly one state for this name
      select count(*) into v_same from jsonb_array_elements(p) x where public.norm_city(x->>'name') = v_norm;
      if v_same = 1 then
        update public.cities c set state = v_state, source = 'registry'
         where c.name_norm = v_norm and c.state is null returning c.id into v_id;
        if v_id is not null then v_updated := v_updated + 1; end if;
      end if;
    end if;
    if v_id is null then
      insert into public.cities (name, name_norm, state, source)
      values (public.display_city(e->>'name'), v_norm, v_state, 'registry') returning id into v_id;
      v_added := v_added + 1;
    end if;
    for a in select jsonb_array_elements_text(coalesce(e->'aliases', '[]'::jsonb)) loop
      if public.norm_city(a) ~ '[a-z]' and public.norm_city(a) <> v_norm then
        insert into public.city_aliases (alias_norm, city_id) values (public.norm_city(a), v_id) on conflict do nothing;
        if found then v_alias := v_alias + 1; end if;
      end if;
    end loop;
  end loop;
  return jsonb_build_object('added', v_added, 'updated', v_updated, 'aliases', v_alias);
end $$;
revoke all on function public.sync_cities(jsonb) from public, anon, authenticated;
grant execute on function public.sync_cities(jsonb) to service_role;

-- ---------------------------------------------------------------------
-- 7. Shipments: city + review status
-- ---------------------------------------------------------------------
alter table public.shipments
  add column if not exists city_id uuid references public.cities(id) on delete set null,
  add column if not exists pricing_status text not null default 'priced',
  add column if not exists review_reason text check (char_length(review_reason) <= 200);

alter table public.shipments drop constraint if exists shipments_pricing_status_chk;
alter table public.shipments add constraint shipments_pricing_status_chk check (pricing_status in ('priced','needs_review'));

alter table public.shipments drop constraint if exists shipments_typed_priced_chk;
alter table public.shipments add constraint shipments_typed_priced_chk check (
  case
    when shipment_type is null then pricing_status = 'priced'
    when pricing_status = 'priced' then rate_applied > 0 and amount = rate_applied and review_reason is null
    else amount = 0 and rate_applied is null and review_reason is not null and invoice_id is null
  end);
create index if not exists shipments_review_idx on public.shipments (owner_id) where pricing_status = 'needs_review';

-- ---------------------------------------------------------------------
-- 8. Rate lookup now goes through the seller's city -> zone mapping
-- ---------------------------------------------------------------------
drop function if exists public.shipment_rate(uuid, uuid, text, text, text, numeric);
create function public.shipment_rate(p_owner uuid, p_client uuid, p_type text, p_service text,
                                     p_destination text, p_billing_weight numeric)
returns table (rate numeric, zone_name text, slab_label text, reason text, city_id uuid)
language plpgsql security definer set search_path = '' as $$
declare
  v_unit text := case p_type when 'DOX' then 'g' else 'kg' end;
  v_w numeric; v_has boolean := false; v_cid uuid; cz record;
  v_slab public.rate_slabs; v_card public.rate_cards; v_label text; v_rate numeric; v_kg numeric;
begin
  select * into cz from public.city_zone(p_owner, p_destination, true);
  if p_billing_weight is null or p_billing_weight <= 0 then
    return query select null::numeric, null::text, null::text, 'No valid weight', cz.city_id; return; end if;
  v_w := case p_type when 'DOX' then ceil(p_billing_weight) else ceil(p_billing_weight * 1000) / 1000 end;

  if exists (select 1 from public.rate_slabs s where s.owner_id = p_owner and s.client_id = p_client
               and s.shipment_type = p_type and s.service = p_service) then v_has := true; v_cid := p_client;
  elsif exists (select 1 from public.rate_slabs s where s.owner_id = p_owner and s.client_id is null
               and s.shipment_type = p_type and s.service = p_service) then v_has := true; v_cid := null;
  end if;

  if v_has then
    if cz.zone_id is null then return query select null::numeric, null::text, null::text, cz.reason, cz.city_id; return; end if;
    select s.* into v_slab from public.rate_slabs s
     where s.owner_id = p_owner and s.client_id is not distinct from v_cid and s.shipment_type = p_type
       and s.service = p_service and v_w between s.min_weight and s.max_weight
     order by s.min_weight limit 1;
    if not found then return query select null::numeric, null::text, null::text, format('No slab covers %s %s', trim_scale(v_w), v_unit), cz.city_id; return; end if;
    v_label := format('%s–%s %s', trim_scale(v_slab.min_weight), trim_scale(v_slab.max_weight), v_unit);
    if jsonb_typeof(v_slab.rates -> cz.zone_id::text) is distinct from 'number' then
      return query select null::numeric, null::text, null::text, format('No %s rate for %s', cz.zone_name, v_label), cz.city_id; return; end if;
    v_rate := round((v_slab.rates ->> cz.zone_id::text)::numeric, 2);
    if v_rate <= 0 then return query select null::numeric, null::text, null::text, format('%s rate for %s is ₹0', cz.zone_name, v_label), cz.city_id; return; end if;
    return query select v_rate, cz.zone_name, v_label, null::text, cz.city_id; return;
  end if;

  -- older kg rate cards (no zones), client first then Default
  v_kg := case p_type when 'DOX' then v_w / 1000 else v_w end;
  if exists (select 1 from public.rate_cards c where c.owner_id = p_owner and c.client_id = p_client and lower(c.service) = lower(p_service)) then
    v_cid := p_client; v_has := true;
  elsif exists (select 1 from public.rate_cards c where c.owner_id = p_owner and c.client_id is null and lower(c.service) = lower(p_service)) then
    v_cid := null; v_has := true;
  end if;
  if not v_has then return query select null::numeric, null::text, null::text, format('No %s %s rate card', p_type, p_service), cz.city_id; return; end if;
  select c.* into v_card from public.rate_cards c
   where c.owner_id = p_owner and c.client_id is not distinct from v_cid and lower(c.service) = lower(p_service)
     and v_kg between c.min_weight and c.max_weight order by c.min_weight limit 1;
  if found then
    if round(v_card.rate, 2) <= 0 then return query select null::numeric, null::text, null::text, 'Older kg slab rate is ₹0', cz.city_id; return; end if;
    return query select round(v_card.rate, 2), null::text, 'older kg slab', null::text, cz.city_id; return;
  end if;
  select c.* into v_card from public.rate_cards c
   where c.owner_id = p_owner and c.client_id is not distinct from v_cid and lower(c.service) = lower(p_service)
   order by c.max_weight desc limit 1;
  if v_kg > v_card.max_weight then
    v_rate := round(v_card.rate + ceil(v_kg - v_card.max_weight) * v_card.extra_per_kg, 2);
    if v_rate <= 0 then return query select null::numeric, null::text, null::text, 'Older kg slab rate is ₹0', cz.city_id; return; end if;
    return query select v_rate, null::text, 'older kg slab', null::text, cz.city_id; return;
  end if;
  return query select null::numeric, null::text, null::text, format('No slab covers %s kg', trim_scale(v_kg)), cz.city_id;
end $$;
revoke all on function public.shipment_rate(uuid, uuid, text, text, text, numeric) from public, anon, authenticated;
grant execute on function public.shipment_rate(uuid, uuid, text, text, text, numeric) to service_role;

create or replace function public.shipments_apply_rate()
returns trigger language plpgsql security definer set search_path = '' as $$
declare r record; v_bw numeric;
begin
  if new.shipment_type is null then
    new.rate_zone := null; new.rate_slab := null; new.rate_applied := null;
    new.pricing_status := 'priced'; new.review_reason := null;
    return new;
  end if;
  v_bw := greatest(new.weight_f, new.weight_g, new.weight_h, new.weight_t);
  if v_bw is null then return new; end if;              -- shipments_type_weights_chk reports this
  select * into r from public.shipment_rate(new.owner_id, new.client_id, new.shipment_type,
                                            new.service, new.destination, v_bw);
  new.city_id := r.city_id;
  if r.rate is null then
    new.pricing_status := 'needs_review'; new.review_reason := left(r.reason, 200);
    new.amount := 0; new.rate_applied := null; new.rate_zone := null; new.rate_slab := null;
  else
    new.pricing_status := 'priced'; new.review_reason := null;
    new.amount := r.rate; new.rate_applied := r.rate; new.rate_zone := r.zone_name; new.rate_slab := r.slab_label;
  end if;
  return new;
end $$;
revoke all on function public.shipments_apply_rate() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 9. Automatic re-pricing of needs-review shipments
-- ---------------------------------------------------------------------
create or replace function public.reprice_review(p_owner uuid)
returns int language plpgsql security definer set search_path = '' as $$
declare v_n int;
begin
  update public.shipments set destination = destination      -- fires shipments_apply_rate
   where owner_id = p_owner and invoice_id is null and pricing_status = 'needs_review';
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public.reprice_review(uuid) from public, anon, authenticated;
grant execute on function public.reprice_review(uuid) to service_role;

create or replace function public.reprice_after_change()
returns trigger language plpgsql security definer set search_path = '' as $$
declare o uuid;
begin
  for o in select distinct owner_id from changed where owner_id is not null loop
    perform public.reprice_review(o);
  end loop;
  return null;
end $$;
revoke all on function public.reprice_after_change() from public, anon, authenticated;

do $$ declare t text; begin
  foreach t in array array['seller_city_zones','seller_city_aliases','rate_slabs','rate_cards'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_reprice_ins', t);
    execute format('drop trigger if exists %I on public.%I', t || '_reprice_upd', t);
    execute format('create trigger %I after insert on public.%I referencing new table as changed for each statement execute function public.reprice_after_change()', t || '_reprice_ins', t);
    execute format('create trigger %I after update on public.%I referencing new table as changed for each statement execute function public.reprice_after_change()', t || '_reprice_upd', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 10. Invoices refuse periods with shipments needing review
-- ---------------------------------------------------------------------
create or replace function public.create_invoice(p_client_id uuid, p_from date, p_to date, p_invoice_date date default current_date)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_client public.clients; v_state text; v_kind public.invoice_kind; v_fy text;
  v_seq int; v_prefix text; v_count int; v_review int; v_sub numeric(14,2);
  v_cgst numeric(14,2) := 0; v_igst numeric(14,2) := 0; v_id uuid;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not public.has_access() then raise exception 'Your trial or plan has expired. Renew to create invoices.'; end if;
  if p_from is null or p_to is null or p_from > p_to then raise exception 'Invalid billing period'; end if;
  if p_invoice_date is null then raise exception 'Invoice date required'; end if;

  select * into v_client from public.clients where id = p_client_id and owner_id = v_uid;
  if not found then raise exception 'Client not found'; end if;
  select state into v_state from public.profiles where id = v_uid;

  perform 1 from public.shipments
   where owner_id = v_uid and client_id = p_client_id and invoice_id is null and ship_date between p_from and p_to
   for update;
  select count(*) filter (where pricing_status = 'needs_review') into v_review from public.shipments
   where owner_id = v_uid and client_id = p_client_id and invoice_id is null and ship_date between p_from and p_to;
  if v_review > 0 then
    raise exception '% shipment(s) in this period need review (city, zone or rate missing). Fix them before invoicing.', v_review;
  end if;
  select count(*), coalesce(sum(amount), 0) into v_count, v_sub from public.shipments
   where owner_id = v_uid and client_id = p_client_id and invoice_id is null and ship_date between p_from and p_to;
  if v_count = 0 then raise exception 'No unbilled shipments for this client in the selected period'; end if;

  v_kind := case when v_client.is_gst then 'gst'::public.invoice_kind else 'nongst'::public.invoice_kind end;
  v_fy := public.fy_label(p_invoice_date);
  if v_kind = 'gst' then
    if public.gst_state_code(v_state) is null then raise exception 'Set a valid business state in Settings before issuing GST invoices'; end if;
    if public.gst_state_code(v_client.state) is null then raise exception 'Set a valid state for client % before issuing a GST invoice', v_client.name; end if;
    if public.gst_state_code(v_state) = public.gst_state_code(v_client.state) then v_cgst := round(v_sub * 0.09, 2);
    else v_igst := round(v_sub * 0.18, 2); end if;
  end if;

  if not exists (select 1 from public.invoice_series where owner_id = v_uid and fy = v_fy and kind = v_kind) then
    insert into public.invoice_series (owner_id, fy, kind, prefix, next_number)
    values (v_uid, v_fy, v_kind, case when v_kind = 'gst' then 'GST' else 'BOS' end, 1)
    on conflict (owner_id, fy, kind) do nothing;
  end if;
  update public.invoice_series set next_number = next_number + 1
   where owner_id = v_uid and fy = v_fy and kind = v_kind
   returning next_number - 1, prefix into v_seq, v_prefix;
  if v_seq is null then raise exception 'Invoice series unavailable'; end if;

  insert into public.invoices (owner_id, client_id, kind, fy, seq, invoice_no, invoice_date,
                               period_from, period_to, subtotal, cgst, sgst, igst, total)
  values (v_uid, p_client_id, v_kind, v_fy, v_seq, v_prefix || '/' || v_fy || '/' || lpad(v_seq::text, 4, '0'),
          p_invoice_date, p_from, p_to, v_sub, v_cgst, v_cgst, v_igst, v_sub + v_cgst * 2 + v_igst)
  returning id into v_id;
  update public.shipments set invoice_id = v_id
   where owner_id = v_uid and client_id = p_client_id and invoice_id is null and ship_date between p_from and p_to;
  return v_id;
end $$;
revoke all on function public.create_invoice(uuid, date, date, date) from public, anon;
grant execute on function public.create_invoice(uuid, date, date, date) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 11. Deprecated zones.destinations -> mapping (compatibility + data migration)
-- ---------------------------------------------------------------------
create or replace function public.zones_map_destinations()
returns trigger language plpgsql security definer set search_path = '' as $$
declare d text; r record; v_city uuid;
begin
  foreach d in array new.destinations loop
    select * into r from public.city_resolve(new.owner_id, d);
    v_city := case r.status when 'ok' then r.city_id
                            when 'unknown' then public.ensure_city(d, 'migrated', new.owner_id) end;
    if v_city is not null then        -- ambiguous names are left for the seller to confirm
      insert into public.seller_city_zones (owner_id, city_id, zone_id) values (new.owner_id, v_city, new.id)
      on conflict (owner_id, city_id) do update set zone_id = excluded.zone_id, updated_at = now();
    end if;
  end loop;
  return null;
end $$;
revoke all on function public.zones_map_destinations() from public, anon, authenticated;
drop trigger if exists zones_map_destinations on public.zones;
create trigger zones_map_destinations after insert or update of destinations on public.zones
  for each row execute function public.zones_map_destinations();

-- one-time migration of existing destinations (fires the trigger above)
update public.zones set destinations = destinations where cardinality(destinations) > 0;

-- re-price anything already stored for review
do $$ declare o uuid; begin
  for o in select distinct owner_id from public.shipments where pricing_status = 'needs_review' loop
    perform public.reprice_review(o);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 12. Hardening for new functions
-- ---------------------------------------------------------------------
alter default privileges in schema public revoke all on tables from public, anon, authenticated;
alter default privileges in schema public revoke all on functions from public, anon, authenticated;

commit;

-- Optional daily sync (review first; requires pg_cron + pg_net and the CITY_SYNC_SECRET
-- you set in the app). Replace <APP_URL> and <SECRET>; do NOT run until approved.
-- select cron.schedule('entrysetu-city-sync', '30 20 * * *',  -- 02:00 IST
--   $$select net.http_post(url := '<APP_URL>/api/public/city-sync',
--       headers := jsonb_build_object('x-sync-secret', '<SECRET>'))$$);
