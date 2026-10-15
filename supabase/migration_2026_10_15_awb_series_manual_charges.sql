-- =====================================================================
-- EntrySetu V1 — AWB numbering series + Manual charges override.
-- DEVELOPMENT ONLY (zfvnqcyqxxipjaugkmvf). Never run on production.
-- Run AFTER all invoice editor + Bill To Name migrations.
-- Re-runnable. Existing shipments, invoices and rate cards are not changed:
-- new columns default to Auto mode and no existing row is updated.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- A. AWB numbering series
-- One default series per seller (client_id null) + optional one per client.
-- Numbers are only SUGGESTED, never reserved: a failed save uses nothing,
-- and the existing unique (owner_id, awb) constraint stops concurrent duplicates.
-- ---------------------------------------------------------------------
create table if not exists public.awb_series (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  client_id uuid,
  prefix text not null default '',
  start_number bigint not null,
  digits int not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (owner_id, client_id) references public.clients (owner_id, id) on delete cascade,
  constraint awb_series_prefix_chk check (prefix ~ '^[A-Z0-9/-]{0,20}$'),
  constraint awb_series_digits_chk check (digits between 1 and 18),
  constraint awb_series_start_chk check (start_number >= 0 and char_length(start_number::text) <= digits),
  constraint awb_series_len_chk check (char_length(prefix) + digits <= 40)
);
create unique index if not exists awb_series_default_uq on public.awb_series (owner_id) where client_id is null;
create unique index if not exists awb_series_client_uq on public.awb_series (owner_id, client_id) where client_id is not null;

revoke all on public.awb_series from public, anon, authenticated;
grant select, delete on public.awb_series to authenticated;
grant insert (client_id, prefix, start_number, digits, active) on public.awb_series to authenticated;
grant update (prefix, start_number, digits, active) on public.awb_series to authenticated;
grant all on public.awb_series to service_role;
alter table public.awb_series enable row level security;
drop policy if exists "awb_series: read own" on public.awb_series;
drop policy if exists "awb_series: insert own" on public.awb_series;
drop policy if exists "awb_series: update own" on public.awb_series;
drop policy if exists "awb_series: delete own" on public.awb_series;
create policy "awb_series: read own" on public.awb_series for select to authenticated using (owner_id = auth.uid());
create policy "awb_series: insert own" on public.awb_series for insert to authenticated
  with check (owner_id = auth.uid() and public.has_access());
create policy "awb_series: update own" on public.awb_series for update to authenticated
  using (owner_id = auth.uid() and public.has_access()) with check (owner_id = auth.uid() and public.has_access());
create policy "awb_series: delete own" on public.awb_series for delete to authenticated
  using (owner_id = auth.uid() and public.has_access());

create or replace function public.awb_series_touch()
returns trigger language plpgsql set search_path = '' as $$
begin new.prefix := upper(btrim(new.prefix)); new.updated_at := now(); return new; end $$;
revoke all on function public.awb_series_touch() from public, anon, authenticated;
drop trigger if exists awb_series_touch on public.awb_series;
create trigger awb_series_touch before insert or update on public.awb_series
  for each row execute function public.awb_series_touch();

-- Next unused AWB for a client (client series first, then the seller's default).
-- Runs as the caller, so RLS limits it to the caller's own series and shipments.
-- Rule: highest existing AWB in this exact format (prefix + exactly `digits` digits,
-- at or above start) + 1, else start. Never returns an AWB that already exists;
-- numbers below the highest are never reused.
create or replace function public.next_awb(p_client_id uuid default null)
returns table (awb text, series_id uuid, scope text)
language plpgsql stable security invoker set search_path = '' as $$
declare s public.awb_series; v_n numeric; v_max numeric; v_try text; v_pat text;
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  select * into s from public.awb_series a
   where a.owner_id = auth.uid() and a.active
     and (a.client_id = p_client_id or a.client_id is null)
   order by (a.client_id is null) limit 1;
  if not found then return; end if;            -- no series configured: no suggestion
  v_pat := '^' || s.prefix || '[0-9]{' || s.digits || '}$';
  select max(substr(sh.awb, char_length(s.prefix) + 1)::numeric) into v_max
    from public.shipments sh
   where sh.owner_id = auth.uid() and sh.awb ~ v_pat
     and substr(sh.awb, char_length(s.prefix) + 1)::numeric >= s.start_number;
  v_n := coalesce(v_max + 1, s.start_number);
  loop
    if char_length(v_n::text) > s.digits then
      raise exception 'AWB series % is used up (% digits). Change the series.', s.prefix, s.digits using errcode = 'P0001';
    end if;
    v_try := s.prefix || lpad(v_n::text, s.digits, '0');
    exit when not exists (select 1 from public.shipments x where x.owner_id = auth.uid() and x.awb = v_try);
    v_n := v_n + 1;
  end loop;
  return query select v_try, s.id, case when s.client_id is null then 'default' else 'client' end;
end $$;
revoke all on function public.next_awb(uuid) from public, anon, authenticated;
grant execute on function public.next_awb(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- B. Manual charges override
-- ---------------------------------------------------------------------
alter table public.shipments add column if not exists charge_mode text not null default 'auto';
alter table public.shipments add column if not exists manual_amount numeric(12,2);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'shipments_charge_mode_chk') then
    alter table public.shipments add constraint shipments_charge_mode_chk check (
      charge_mode in ('auto', 'manual')
      and (manual_amount is null or (manual_amount > 0 and manual_amount <= 10000000))
      and (charge_mode = 'auto' or manual_amount is not null));
  end if;
end $$;
grant insert (charge_mode, manual_amount) on public.shipments to authenticated;
grant update (charge_mode, manual_amount) on public.shipments to authenticated;

-- Who may use Manual mode. No staff accounts exist yet, so only the account owner.
-- Add staff here later (e.g. a seller_staff table with a can_manual_charge flag).
create schema if not exists entrysetu_private;
revoke all on schema entrysetu_private from public, anon, authenticated;
create or replace function entrysetu_private.can_manual_charge(p_owner uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and auth.uid() = p_owner
$$;
revoke all on function entrysetu_private.can_manual_charge(uuid) from public, anon, authenticated, service_role;

-- Pricing: Manual mode keeps the entered amount; Auto mode is unchanged.
create or replace function public.shipments_apply_rate()
returns trigger language plpgsql security definer set search_path = '' as $$
declare r record; v_bw numeric;
begin
  if new.charge_mode = 'manual' then
    new.amount := new.manual_amount;
    new.rate_zone := null; new.rate_slab := null; new.rate_applied := null;
    new.pricing_status := 'priced'; new.review_reason := null;
    return new;
  end if;
  new.manual_amount := null;                       -- back to Auto: drop the old manual value
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
drop trigger if exists shipments_apply_rate on public.shipments;
create trigger shipments_apply_rate
  before insert or update of client_id, shipment_type, service, destination, weight_f, weight_g, weight_h, weight_t,
                             amount, rate_zone, rate_slab, rate_applied, charge_mode, manual_amount
  on public.shipments for each row execute function public.shipments_apply_rate();

-- Guard: only the owner may set or change Manual mode; never on invoiced or draft-reserved shipments.
create or replace function public.shipments_charge_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.charge_mode = 'manual' and not entrysetu_private.can_manual_charge(new.owner_id) then
      raise exception 'Only the account owner can enter manual charges' using errcode = '42501';
    end if;
    return new;
  end if;
  if new.charge_mode is distinct from old.charge_mode or new.manual_amount is distinct from old.manual_amount then
    if old.invoice_id is not null or old.draft_invoice_id is not null then
      raise exception 'Charges for shipment % are locked by an invoice or draft invoice', old.awb using errcode = 'P0001';
    end if;
    if not entrysetu_private.can_manual_charge(old.owner_id) then
      raise exception 'Only the account owner can change manual charges' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
revoke all on function public.shipments_charge_guard() from public, anon, authenticated, service_role;
drop trigger if exists shipments_charge_guard on public.shipments;
create trigger shipments_charge_guard before insert or update of charge_mode, manual_amount on public.shipments
  for each row execute function public.shipments_charge_guard();

-- Repricing never touches Manual shipments (same body as the invoice editor version + one filter).
create or replace function public.reprice_review(p_owner uuid)
returns int language plpgsql security definer set search_path = '' as $$
declare v_n int;
begin
  update public.shipments set destination = destination      -- fires shipments_apply_rate
   where owner_id = p_owner and invoice_id is null and draft_invoice_id is null
     and pricing_status = 'needs_review' and charge_mode = 'auto';
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public.reprice_review(uuid) from public, anon, authenticated;
grant execute on function public.reprice_review(uuid) to service_role;

-- Immutable audit history. No foreign keys, so deleting a shipment keeps its history.
create table if not exists public.shipment_charge_audit (
  id bigint generated always as identity primary key,
  owner_id uuid not null,
  shipment_id uuid not null,
  awb text not null,
  action text not null check (action in ('insert', 'update', 'delete')),
  old_mode text, new_mode text,
  old_amount numeric(12,2), new_amount numeric(12,2),
  actor uuid, actor_role text not null default current_user,
  created_at timestamptz not null default now()
);
create index if not exists shipment_charge_audit_owner_idx on public.shipment_charge_audit (owner_id, shipment_id, created_at);
revoke all on public.shipment_charge_audit from public, anon, authenticated, service_role;
grant select on public.shipment_charge_audit to authenticated;
grant select on public.shipment_charge_audit to service_role;   -- read only, even for service role
alter table public.shipment_charge_audit enable row level security;
drop policy if exists "charge_audit: read own" on public.shipment_charge_audit;
create policy "charge_audit: read own" on public.shipment_charge_audit for select to authenticated using (owner_id = auth.uid());

create or replace function public.shipment_charge_audit_block()
returns trigger language plpgsql set search_path = '' as $$
begin raise exception 'Charge audit history cannot be changed or deleted' using errcode = 'P0001'; end $$;
revoke all on function public.shipment_charge_audit_block() from public, anon, authenticated, service_role;
drop trigger if exists shipment_charge_audit_block on public.shipment_charge_audit;
create trigger shipment_charge_audit_block before update or delete on public.shipment_charge_audit
  for each row execute function public.shipment_charge_audit_block();
drop trigger if exists shipment_charge_audit_block_trunc on public.shipment_charge_audit;
create trigger shipment_charge_audit_block_trunc before truncate on public.shipment_charge_audit
  for each statement execute function public.shipment_charge_audit_block();

-- Logs every Manual entry, every switch Auto<->Manual, every manual amount change,
-- and deletion of a Manual shipment. Amounts are the final stored amounts.
create or replace function public.shipments_charge_audit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' and new.charge_mode = 'manual' then
    insert into public.shipment_charge_audit (owner_id, shipment_id, awb, action, new_mode, new_amount, actor)
    values (new.owner_id, new.id, new.awb, 'insert', 'manual', new.amount, auth.uid());
  elsif tg_op = 'UPDATE' and (new.charge_mode is distinct from old.charge_mode
        or (new.charge_mode = 'manual' and new.manual_amount is distinct from old.manual_amount)) then
    insert into public.shipment_charge_audit (owner_id, shipment_id, awb, action, old_mode, new_mode, old_amount, new_amount, actor)
    values (new.owner_id, new.id, new.awb, 'update', old.charge_mode, new.charge_mode, old.amount, new.amount, auth.uid());
  elsif tg_op = 'DELETE' and old.charge_mode = 'manual' then
    insert into public.shipment_charge_audit (owner_id, shipment_id, awb, action, old_mode, old_amount, actor)
    values (old.owner_id, old.id, old.awb, 'delete', 'manual', old.amount, auth.uid());
  end if;
  return null;
end $$;
revoke all on function public.shipments_charge_audit() from public, anon, authenticated, service_role;
drop trigger if exists shipments_charge_audit on public.shipments;
create trigger shipments_charge_audit after insert or update or delete on public.shipments
  for each row execute function public.shipments_charge_audit();

notify pgrst, 'reload schema';
commit;
