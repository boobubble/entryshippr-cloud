-- =====================================================================
-- EntrySetu schema v2 — for a NEW, EMPTY Supabase project only.
-- Run once in Supabase -> SQL Editor. Do NOT run on any existing/production DB.
-- =====================================================================
begin;

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------
create type public.app_role as enum ('admin', 'user');
create type public.plan_kind as enum ('standard', 'unlimited');
create type public.invoice_kind as enum ('gst', 'nongst');
create type public.invoice_status as enum ('issued', 'cancelled');
create type public.payment_status as enum ('created', 'paid', 'failed');

-- ---------------------------------------------------------------------
-- Profiles (one per auth user). Plan fields are server-only.
-- ---------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  business_name text not null default '' check (char_length(business_name) <= 200),
  phone text check (char_length(phone) <= 30),
  gstin text check (gstin is null or gstin = '' or gstin ~ '^[0-9]{2}[A-Z0-9]{13}$'),
  address text check (char_length(address) <= 1000),
  state text check (char_length(state) <= 60),
  trial_ends_at timestamptz not null default now() + interval '5 days',
  plan public.plan_kind,
  plan_expires_at timestamptz,
  joining_fee_paid boolean not null default false,
  created_at timestamptz not null default now()
);
grant select on public.profiles to authenticated;
grant update (business_name, phone, gstin, address, state) on public.profiles to authenticated;
grant all on public.profiles to service_role;
alter table public.profiles enable row level security;

-- ---------------------------------------------------------------------
-- Roles (separate table; no client writes)
-- ---------------------------------------------------------------------
create table public.user_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  role public.app_role not null,
  unique (user_id, role)
);
grant select on public.user_roles to authenticated;
grant all on public.user_roles to service_role;
alter table public.user_roles enable row level security;

-- ---------------------------------------------------------------------
-- Hardened SECURITY DEFINER helpers: empty search_path, fully-qualified
-- names, only check the CALLER (auth.uid()), never arbitrary users.
-- ---------------------------------------------------------------------
create function public.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.user_roles
                 where user_id = auth.uid() and role = 'admin'::public.app_role)
$$;

create function public.has_access()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p
                 where p.id = auth.uid()
                   and (p.trial_ends_at > now()
                        or (p.plan is not null and p.plan_expires_at > now())))
$$;

create function public.fy_label(d date)
returns text language sql immutable set search_path = '' as $$
  select case when extract(month from d) >= 4
    then extract(year from d)::int || '-' || lpad(((extract(year from d)::int + 1) % 100)::text, 2, '0')
    else (extract(year from d)::int - 1) || '-' || lpad((extract(year from d)::int % 100)::text, 2, '0') end
$$;

revoke all on function public.is_admin() from public, anon;
revoke all on function public.has_access() from public, anon;
grant execute on function public.is_admin() to authenticated, service_role;
grant execute on function public.has_access() to authenticated, service_role;
grant execute on function public.fy_label(date) to authenticated, service_role;

create policy "profiles: read own or admin" on public.profiles
  for select to authenticated using (id = auth.uid() or public.is_admin());
create policy "profiles: update own" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy "roles: read own" on public.user_roles
  for select to authenticated using (user_id = auth.uid());

-- New user -> profile
create function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, email, business_name)
  values (new.id, new.email, left(coalesce(new.raw_user_meta_data->>'business_name', ''), 200))
  on conflict (id) do nothing;
  return new;
end $$;
revoke all on function public.handle_new_user() from public, anon, authenticated;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- Clients
-- ---------------------------------------------------------------------
create table public.clients (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 200),
  phone text check (char_length(phone) <= 30),
  email text check (char_length(email) <= 200),
  gstin text check (gstin is null or gstin = '' or gstin ~ '^[0-9]{2}[A-Z0-9]{13}$'),
  address text check (char_length(address) <= 1000),
  state text check (char_length(state) <= 60),
  is_gst boolean not null default true,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (owner_id, id),             -- target for tenant-scoped composite FKs
  unique (owner_id, name)
);
create index clients_owner_active_idx on public.clients (owner_id) where active;
grant select, delete on public.clients to authenticated;
grant insert (name, phone, email, gstin, address, state, is_gst, active) on public.clients to authenticated;
grant update (name, phone, email, gstin, address, state, is_gst, active) on public.clients to authenticated;
grant all on public.clients to service_role;
alter table public.clients enable row level security;
create policy "clients: read own" on public.clients for select to authenticated
  using (owner_id = auth.uid());
create policy "clients: insert own (active plan)" on public.clients for insert to authenticated
  with check (owner_id = auth.uid() and public.has_access());
create policy "clients: update own (active plan)" on public.clients for update to authenticated
  using (owner_id = auth.uid() and public.has_access())
  with check (owner_id = auth.uid() and public.has_access());
create policy "clients: delete own (active plan)" on public.clients for delete to authenticated
  using (owner_id = auth.uid() and public.has_access());

-- 50-active-client limit, serialised per tenant with an advisory lock
create function public.enforce_client_limit()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_unlimited boolean; v_count int;
begin
  if not new.active then return new; end if;
  if tg_op = 'UPDATE' and old.active then return new; end if;
  perform pg_advisory_xact_lock(hashtextextended('clients:' || new.owner_id::text, 0));
  select (p.plan = 'unlimited' and p.plan_expires_at > now()) into v_unlimited
    from public.profiles p where p.id = new.owner_id;
  if coalesce(v_unlimited, false) then return new; end if;
  select count(*) into v_count from public.clients
    where owner_id = new.owner_id and active and id <> new.id;
  if v_count >= 50 then
    raise exception 'Active client limit reached (50). Upgrade to Standard Unlimited.'
      using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke all on function public.enforce_client_limit() from public, anon, authenticated;
create trigger clients_limit before insert or update of active on public.clients
  for each row execute function public.enforce_client_limit();

-- ---------------------------------------------------------------------
-- Rate cards (client must belong to same tenant)
-- ---------------------------------------------------------------------
create table public.rate_cards (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  client_id uuid,
  service text not null default 'Standard' check (char_length(btrim(service)) between 1 and 60),
  min_weight numeric(10,3) not null default 0 check (min_weight >= 0),
  max_weight numeric(10,3) not null,
  rate numeric(12,2) not null check (rate >= 0),
  extra_per_kg numeric(12,2) not null default 0 check (extra_per_kg >= 0),
  created_at timestamptz not null default now(),
  check (max_weight >= min_weight),
  foreign key (owner_id, client_id) references public.clients (owner_id, id) on delete cascade
);
create index rate_cards_lookup_idx on public.rate_cards (owner_id, client_id, lower(service), min_weight);
grant select, delete on public.rate_cards to authenticated;
grant insert (client_id, service, min_weight, max_weight, rate, extra_per_kg) on public.rate_cards to authenticated;
grant update (client_id, service, min_weight, max_weight, rate, extra_per_kg) on public.rate_cards to authenticated;
grant all on public.rate_cards to service_role;
alter table public.rate_cards enable row level security;
create policy "rate_cards: read own" on public.rate_cards for select to authenticated
  using (owner_id = auth.uid());
create policy "rate_cards: insert own (active plan)" on public.rate_cards for insert to authenticated
  with check (owner_id = auth.uid() and public.has_access());
create policy "rate_cards: update own (active plan)" on public.rate_cards for update to authenticated
  using (owner_id = auth.uid() and public.has_access())
  with check (owner_id = auth.uid() and public.has_access());
create policy "rate_cards: delete own (active plan)" on public.rate_cards for delete to authenticated
  using (owner_id = auth.uid() and public.has_access());

-- ---------------------------------------------------------------------
-- Invoice numbering series: separate GST / Non-GST per financial year.
-- Users may set prefix and starting number; numbers can never go backwards.
-- ---------------------------------------------------------------------
create table public.invoice_series (
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  fy text not null check (fy ~ '^[0-9]{4}-[0-9]{2}$'),
  kind public.invoice_kind not null,
  prefix text not null check (prefix ~ '^[A-Za-z0-9/_-]{1,20}$'),
  next_number int not null default 1 check (next_number between 1 and 99999999),
  primary key (owner_id, fy, kind)
);
grant select on public.invoice_series to authenticated;
grant insert (fy, kind, prefix, next_number) on public.invoice_series to authenticated;
grant update (prefix, next_number) on public.invoice_series to authenticated;
grant all on public.invoice_series to service_role;
alter table public.invoice_series enable row level security;
create policy "series: read own" on public.invoice_series for select to authenticated
  using (owner_id = auth.uid());
create policy "series: insert own (active plan)" on public.invoice_series for insert to authenticated
  with check (owner_id = auth.uid() and public.has_access());
create policy "series: update own (active plan)" on public.invoice_series for update to authenticated
  using (owner_id = auth.uid() and public.has_access())
  with check (owner_id = auth.uid() and public.has_access());

-- ---------------------------------------------------------------------
-- Invoices: issued atomically by create_invoice(); never edited/deleted
-- by users, only cancelled via cancel_invoice().
-- ---------------------------------------------------------------------
create table public.invoices (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  client_id uuid not null,
  kind public.invoice_kind not null,
  fy text not null,
  seq int not null check (seq > 0),
  invoice_no text not null,
  invoice_date date not null,
  period_from date not null,
  period_to date not null,
  status public.invoice_status not null default 'issued',
  cancelled_at timestamptz,
  cancel_reason text check (char_length(cancel_reason) <= 300),
  subtotal numeric(14,2) not null check (subtotal >= 0),
  cgst numeric(14,2) not null default 0 check (cgst >= 0),
  sgst numeric(14,2) not null default 0 check (sgst >= 0),
  igst numeric(14,2) not null default 0 check (igst >= 0),
  total numeric(14,2) not null check (total >= 0),
  created_at timestamptz not null default now(),
  check (period_to >= period_from),
  check (kind = 'gst' or (cgst = 0 and sgst = 0 and igst = 0)),
  unique (owner_id, id),
  unique (owner_id, kind, fy, seq),
  unique (owner_id, invoice_no),
  foreign key (owner_id, client_id) references public.clients (owner_id, id) on delete restrict
);
create index invoices_owner_date_idx on public.invoices (owner_id, invoice_date desc);
create index invoices_owner_client_idx on public.invoices (owner_id, client_id);
grant select on public.invoices to authenticated;
grant all on public.invoices to service_role;
alter table public.invoices enable row level security;
create policy "invoices: read own" on public.invoices for select to authenticated
  using (owner_id = auth.uid());

-- Starting number cannot go below numbers already used
create function public.guard_invoice_series()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_max int;
begin
  select coalesce(max(seq), 0) into v_max from public.invoices
    where owner_id = new.owner_id and fy = new.fy and kind = new.kind;
  if new.next_number <= v_max then
    raise exception 'Next number must be greater than % (already used)', v_max;
  end if;
  return new;
end $$;
revoke all on function public.guard_invoice_series() from public, anon, authenticated;
create trigger invoice_series_guard before insert or update on public.invoice_series
  for each row execute function public.guard_invoice_series();

-- ---------------------------------------------------------------------
-- Shipments (client & invoice must belong to same tenant)
-- ---------------------------------------------------------------------
create table public.shipments (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  client_id uuid not null,
  awb text not null check (char_length(btrim(awb)) between 1 and 40),
  ship_date date not null default current_date,
  destination text check (char_length(destination) <= 120),
  service text not null default 'Standard' check (char_length(service) <= 60),
  weight numeric(10,3) not null default 0 check (weight >= 0),
  pieces int not null default 1 check (pieces between 1 and 10000),
  amount numeric(12,2) not null default 0 check (amount >= 0),
  invoice_id uuid,
  created_at timestamptz not null default now(),
  unique (owner_id, awb),
  foreign key (owner_id, client_id) references public.clients (owner_id, id) on delete restrict,
  foreign key (owner_id, invoice_id) references public.invoices (owner_id, id) on delete restrict
);
create index shipments_owner_date_idx on public.shipments (owner_id, ship_date desc);
create index shipments_unbilled_idx on public.shipments (owner_id, client_id, ship_date) where invoice_id is null;
create index shipments_invoice_idx on public.shipments (owner_id, invoice_id) where invoice_id is not null;
grant select, delete on public.shipments to authenticated;
grant insert (client_id, awb, ship_date, destination, service, weight, pieces, amount) on public.shipments to authenticated;
grant update (client_id, awb, ship_date, destination, service, weight, pieces, amount) on public.shipments to authenticated;
grant all on public.shipments to service_role;
alter table public.shipments enable row level security;
create policy "shipments: read own" on public.shipments for select to authenticated
  using (owner_id = auth.uid());
create policy "shipments: insert own unbilled (active plan)" on public.shipments for insert to authenticated
  with check (owner_id = auth.uid() and invoice_id is null and public.has_access());
create policy "shipments: update own unbilled (active plan)" on public.shipments for update to authenticated
  using (owner_id = auth.uid() and invoice_id is null and public.has_access())
  with check (owner_id = auth.uid() and invoice_id is null and public.has_access());
create policy "shipments: delete own unbilled (active plan)" on public.shipments for delete to authenticated
  using (owner_id = auth.uid() and invoice_id is null and public.has_access());

-- Billed shipments are frozen for direct API users (defence in depth on top of RLS)
create function public.protect_billed_shipment()
returns trigger language plpgsql set search_path = '' as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return coalesce(new, old);   -- trusted functions / service role
  end if;
  if old.invoice_id is not null then
    raise exception 'This shipment is on invoice and cannot be changed. Cancel the invoice first.';
  end if;
  if tg_op = 'UPDATE' and new.invoice_id is distinct from old.invoice_id then
    raise exception 'Invoice link can only be set by invoicing';
  end if;
  return coalesce(new, old);
end $$;
create trigger shipments_protect before update or delete on public.shipments
  for each row execute function public.protect_billed_shipment();

-- ---------------------------------------------------------------------
-- Invoice issue / cancel (atomic, row-locked, numbering per series)
-- ---------------------------------------------------------------------
create function public.create_invoice(p_client_id uuid, p_from date, p_to date, p_invoice_date date default current_date)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_client public.clients;
  v_state text;
  v_kind public.invoice_kind;
  v_fy text;
  v_seq int;
  v_prefix text;
  v_count int;
  v_sub numeric(14,2);
  v_cgst numeric(14,2) := 0;
  v_igst numeric(14,2) := 0;
  v_id uuid;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not public.has_access() then raise exception 'Your trial or plan has expired. Renew to create invoices.'; end if;
  if p_from is null or p_to is null or p_from > p_to then raise exception 'Invalid billing period'; end if;
  if p_invoice_date is null then raise exception 'Invoice date required'; end if;

  select * into v_client from public.clients where id = p_client_id and owner_id = v_uid;
  if not found then raise exception 'Client not found'; end if;
  select state into v_state from public.profiles where id = v_uid;

  -- lock the shipments being billed
  perform 1 from public.shipments
   where owner_id = v_uid and client_id = p_client_id and invoice_id is null
     and ship_date between p_from and p_to
   for update;
  select count(*), coalesce(sum(amount), 0) into v_count, v_sub from public.shipments
   where owner_id = v_uid and client_id = p_client_id and invoice_id is null
     and ship_date between p_from and p_to;
  if v_count = 0 then raise exception 'No unbilled shipments for this client in the selected period'; end if;

  v_kind := case when v_client.is_gst then 'gst'::public.invoice_kind else 'nongst'::public.invoice_kind end;
  v_fy := public.fy_label(p_invoice_date);

  insert into public.invoice_series (owner_id, fy, kind, prefix, next_number)
  values (v_uid, v_fy, v_kind, case when v_kind = 'gst' then 'GST' else 'BOS' end, 1)
  on conflict (owner_id, fy, kind) do nothing;
  update public.invoice_series set next_number = next_number + 1
   where owner_id = v_uid and fy = v_fy and kind = v_kind
   returning next_number - 1, prefix into v_seq, v_prefix;   -- row lock serialises numbering

  if v_kind = 'gst' then
    if coalesce(nullif(lower(btrim(v_state)), ''), '#') = coalesce(nullif(lower(btrim(v_client.state)), ''), '#')
       or nullif(btrim(v_state), '') is null or nullif(btrim(v_client.state), '') is null then
      v_cgst := round(v_sub * 0.09, 2);
    else
      v_igst := round(v_sub * 0.18, 2);
    end if;
  end if;

  insert into public.invoices (owner_id, client_id, kind, fy, seq, invoice_no, invoice_date,
                               period_from, period_to, subtotal, cgst, sgst, igst, total)
  values (v_uid, p_client_id, v_kind, v_fy, v_seq,
          v_prefix || '/' || v_fy || '/' || lpad(v_seq::text, 4, '0'),
          p_invoice_date, p_from, p_to, v_sub, v_cgst, v_cgst, v_igst, v_sub + v_cgst * 2 + v_igst)
  returning id into v_id;

  update public.shipments set invoice_id = v_id
   where owner_id = v_uid and client_id = p_client_id and invoice_id is null
     and ship_date between p_from and p_to;
  return v_id;
end $$;

create function public.cancel_invoice(p_invoice_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not public.has_access() then raise exception 'Your trial or plan has expired.'; end if;
  update public.invoices
     set status = 'cancelled', cancelled_at = now(), cancel_reason = left(p_reason, 300)
   where id = p_invoice_id and owner_id = v_uid and status = 'issued';
  if not found then raise exception 'Invoice not found or already cancelled'; end if;
  update public.shipments set invoice_id = null
   where owner_id = v_uid and invoice_id = p_invoice_id;
end $$;

revoke all on function public.create_invoice(uuid, date, date, date) from public, anon;
revoke all on function public.cancel_invoice(uuid, text) from public, anon;
grant execute on function public.create_invoice(uuid, date, date, date) to authenticated;
grant execute on function public.cancel_invoice(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- Payments & webhook idempotency (server/service role only)
-- ---------------------------------------------------------------------
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  plan public.plan_kind not null,
  amount_paise bigint not null check (amount_paise > 0),
  includes_joining_fee boolean not null default false,
  razorpay_order_id text not null unique,
  razorpay_payment_id text unique,
  status public.payment_status not null default 'created',
  paid_at timestamptz,
  created_at timestamptz not null default now()
);
create index payments_owner_idx on public.payments (owner_id, created_at desc);
grant select on public.payments to authenticated;
grant all on public.payments to service_role;
alter table public.payments enable row level security;
create policy "payments: read own or admin" on public.payments for select to authenticated
  using (owner_id = auth.uid() or public.is_admin());

create table public.webhook_events (
  event_id text primary key,
  event_type text not null,
  received_at timestamptz not null default now()
);
grant all on public.webhook_events to service_role;
alter table public.webhook_events enable row level security;   -- no policies: service role only

-- Idempotent activation: only flips 'created' -> 'paid' once, amount must match.
create function public.activate_payment(p_order_id text, p_payment_id text, p_amount_paise bigint)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_pay public.payments;
begin
  select * into v_pay from public.payments where razorpay_order_id = p_order_id for update;
  if not found then raise exception 'Unknown order %', p_order_id; end if;
  if v_pay.status = 'paid' then return false; end if;          -- already processed
  if v_pay.amount_paise <> p_amount_paise then raise exception 'Amount mismatch for order %', p_order_id; end if;

  update public.payments set status = 'paid', razorpay_payment_id = p_payment_id, paid_at = now()
   where id = v_pay.id;
  update public.profiles
     set plan = v_pay.plan,
         plan_expires_at = greatest(coalesce(plan_expires_at, now()), now()) + interval '1 year',
         joining_fee_paid = joining_fee_paid or v_pay.includes_joining_fee
   where id = v_pay.owner_id;
  return true;
end $$;

create function public.record_webhook_event(p_event_id text, p_event_type text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  insert into public.webhook_events (event_id, event_type) values (p_event_id, p_event_type)
  on conflict (event_id) do nothing;
  return found;
end $$;

create function public.admin_set_access(p_user_id uuid, p_action text, p_plan public.plan_kind default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_action = 'extend_trial' then
    update public.profiles set trial_ends_at = greatest(trial_ends_at, now()) + interval '5 days' where id = p_user_id;
  elsif p_action = 'grant_plan' then
    update public.profiles set plan = coalesce(p_plan, 'standard'),
      plan_expires_at = greatest(coalesce(plan_expires_at, now()), now()) + interval '1 year' where id = p_user_id;
  elsif p_action = 'revoke' then
    update public.profiles set plan = null, plan_expires_at = null, trial_ends_at = now() where id = p_user_id;
  else
    raise exception 'Unknown action';
  end if;
end $$;

revoke all on function public.activate_payment(text, text, bigint) from public, anon, authenticated;
revoke all on function public.record_webhook_event(text, text) from public, anon, authenticated;
revoke all on function public.admin_set_access(uuid, text, public.plan_kind) from public, anon, authenticated;
grant execute on function public.activate_payment(text, text, bigint) to service_role;
grant execute on function public.record_webhook_event(text, text) to service_role;
grant execute on function public.admin_set_access(uuid, text, public.plan_kind) to service_role;

-- Stop new functions being executable by everyone by default
alter default privileges in schema public revoke execute on functions from public, anon;

commit;

-- After signing up in the app, make yourself super admin (replace the email):
-- insert into public.user_roles (user_id, role)
--   select id, 'admin' from auth.users where email = 'you@example.com' on conflict do nothing;
