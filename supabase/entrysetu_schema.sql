-- EntrySetu schema. Run once in Supabase -> SQL Editor.
create extension if not exists pgcrypto;

do $$ begin create type public.app_role as enum ('admin','user'); exception when duplicate_object then null; end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  business_name text,
  phone text,
  gstin text,
  address text,
  state text,
  invoice_prefix text default 'INV',
  trial_ends_at timestamptz not null default now() + interval '5 days',
  plan text check (plan in ('standard','unlimited')),
  plan_expires_at timestamptz,
  joining_fee_paid boolean not null default false,
  created_at timestamptz not null default now()
);
grant select on public.profiles to authenticated;
grant update (business_name, phone, gstin, address, state, invoice_prefix) on public.profiles to authenticated;
grant all on public.profiles to service_role;
alter table public.profiles enable row level security;

create table if not exists public.user_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade not null,
  role public.app_role not null,
  unique (user_id, role)
);
grant select on public.user_roles to authenticated;
grant all on public.user_roles to service_role;
alter table public.user_roles enable row level security;

create or replace function public.has_role(_user_id uuid, _role public.app_role)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = _user_id and role = _role)
$$;

create or replace function public.has_access(_uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles p where p.id = _uid
    and (p.trial_ends_at > now() or coalesce(p.plan_expires_at, '-infinity') > now()))
$$;

drop policy if exists "own profile" on public.profiles;
create policy "own profile" on public.profiles for select to authenticated using (id = auth.uid() or public.has_role(auth.uid(),'admin'));
drop policy if exists "update own profile" on public.profiles;
create policy "update own profile" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
drop policy if exists "own roles" on public.user_roles;
create policy "own roles" on public.user_roles for select to authenticated using (user_id = auth.uid());

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, business_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'business_name', ''))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- Clients
create table if not exists public.clients (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null,
  phone text, email text, gstin text, address text, state text,
  is_gst boolean not null default true,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (owner_id, name)
);
grant select, insert, update, delete on public.clients to authenticated;
grant all on public.clients to service_role;
alter table public.clients enable row level security;
drop policy if exists "clients read" on public.clients;
create policy "clients read" on public.clients for select to authenticated using (owner_id = auth.uid());
drop policy if exists "clients write" on public.clients;
create policy "clients write" on public.clients for insert to authenticated with check (owner_id = auth.uid() and public.has_access(auth.uid()));
drop policy if exists "clients update" on public.clients;
create policy "clients update" on public.clients for update to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid() and public.has_access(auth.uid()));
drop policy if exists "clients delete" on public.clients;
create policy "clients delete" on public.clients for delete to authenticated using (owner_id = auth.uid());

create or replace function public.enforce_client_limit() returns trigger
language plpgsql security definer set search_path = public as $$
declare p public.profiles; cnt int;
begin
  if not new.active then return new; end if;
  select * into p from public.profiles where id = new.owner_id;
  if p.plan = 'unlimited' and p.plan_expires_at > now() then return new; end if;
  select count(*) into cnt from public.clients where owner_id = new.owner_id and active and id <> new.id;
  if cnt >= 50 then
    raise exception 'Active client limit reached (50). Upgrade to Standard Unlimited.';
  end if;
  return new;
end $$;
drop trigger if exists clients_limit on public.clients;
create trigger clients_limit before insert or update of active on public.clients for each row execute function public.enforce_client_limit();

-- Rate cards
create table if not exists public.rate_cards (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  client_id uuid references public.clients(id) on delete cascade,
  service text not null default 'Standard',
  min_weight numeric not null default 0,
  max_weight numeric not null,
  rate numeric not null,
  extra_per_kg numeric not null default 0,
  created_at timestamptz not null default now()
);
grant select, insert, update, delete on public.rate_cards to authenticated;
grant all on public.rate_cards to service_role;
alter table public.rate_cards enable row level security;
drop policy if exists "rc all" on public.rate_cards;
create policy "rc all" on public.rate_cards for all to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid() and public.has_access(auth.uid()));

-- Invoices
create table if not exists public.invoices (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete restrict,
  invoice_no text not null,
  invoice_date date not null default current_date,
  period_from date, period_to date,
  is_gst boolean not null,
  subtotal numeric not null default 0,
  cgst numeric not null default 0, sgst numeric not null default 0, igst numeric not null default 0,
  total numeric not null default 0,
  created_at timestamptz not null default now(),
  unique (owner_id, invoice_no)
);
grant select, insert, update, delete on public.invoices to authenticated;
grant all on public.invoices to service_role;
alter table public.invoices enable row level security;
drop policy if exists "inv all" on public.invoices;
create policy "inv all" on public.invoices for all to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid() and public.has_access(auth.uid()));

-- Shipments
create table if not exists public.shipments (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  awb text not null,
  ship_date date not null default current_date,
  destination text,
  service text not null default 'Standard',
  weight numeric not null default 0,
  pieces int not null default 1,
  amount numeric not null default 0,
  invoice_id uuid references public.invoices(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (owner_id, awb)
);
grant select, insert, update, delete on public.shipments to authenticated;
grant all on public.shipments to service_role;
alter table public.shipments enable row level security;
drop policy if exists "sh all" on public.shipments;
create policy "sh all" on public.shipments for all to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid() and public.has_access(auth.uid()));

-- Payments (written only by server)
create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  plan text not null,
  amount numeric not null,
  includes_joining_fee boolean not null default false,
  razorpay_order_id text unique,
  razorpay_payment_id text,
  status text not null default 'created',
  created_at timestamptz not null default now()
);
grant select on public.payments to authenticated;
grant all on public.payments to service_role;
alter table public.payments enable row level security;
drop policy if exists "pay read" on public.payments;
create policy "pay read" on public.payments for select to authenticated using (owner_id = auth.uid() or public.has_role(auth.uid(),'admin'));

-- Make yourself super admin (replace the email, then run):
-- insert into public.user_roles (user_id, role) select id, 'admin' from auth.users where email = 'you@example.com' on conflict do nothing;
