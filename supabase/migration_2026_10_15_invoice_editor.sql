-- =====================================================================
-- EntrySetu V1 — Final Invoice Editor, PART 2 of 2. DEVELOPMENT ONLY
-- (zfvnqcyqxxipjaugkmvf). Never run on production. Run AFTER part 1.
--
-- Adds an editable DRAFT step before an invoice is issued:
--   create_invoice_draft  -> save_invoice_draft (repeat) -> finalize_invoice
--   discard_invoice_draft  |  cancel_invoice (existing) -> reissue_invoice
--
-- Rules enforced here (not in the browser):
--   * Every total is recalculated by the database on each save and again on
--     finalize. Client-sent totals are never trusted or stored.
--   * Line edits live in invoice_lines (a copy). shipments and rate cards are
--     never changed by the editor.
--   * % charges use the LINE SUBTOTAL as base; FOV may instead use the total
--     DECLARED VALUE, only when declared values exist.
--   * Taxable value = line subtotal + charges. GST: CGST+SGST (rate/2 each)
--     when seller and client states match, otherwise IGST. Allowed GST rates:
--     5, 12, 18, 28. Tax mode comes from the states and cannot be chosen.
--   * Invoice type (GST / Non-GST) is the seller's choice per invoice. GSTIN-
--     based locking is NOT enforced yet (pending GST compliance review). A
--     Non-GST invoice always carries no tax; a GST invoice needs valid seller
--     and client states so the tax mode (CGST+SGST vs IGST) can be derived.
--   * Numbers are assigned only at finalize. Auto numbers come from the
--     per-FY, per-type series and never go backwards or reuse a number.
--     Manual numbers must be unique for the seller (including cancelled
--     invoices) and must not look like a number of the automatic series.
--   * Issued invoices, their lines and charges are immutable for every role.
--     Only issued -> cancelled is allowed (existing cancel_invoice). Cancelled
--     numbers stay in place for audit; corrections go through reissue_invoice.
--
-- Existing invoices: amounts, numbers, status and snapshots are unchanged.
-- They get charges_total = 0, taxable_value = subtotal, round_off = 0 and a
-- tax mode/rate inferred from their stored tax amounts. create_invoice and
-- cancel_invoice are NOT modified.
-- Additive and re-runnable (create-if-missing / create or replace).
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. invoices: draft support, charges, taxable value, tax mode, round-off
-- ---------------------------------------------------------------------
alter table public.invoices alter column fy drop not null;
alter table public.invoices alter column seq drop not null;
alter table public.invoices alter column invoice_no drop not null;

alter table public.invoices add column if not exists charges_total numeric(14,2) not null default 0 check (charges_total >= 0);
alter table public.invoices add column if not exists taxable_value numeric(14,2) check (taxable_value >= 0);
alter table public.invoices add column if not exists gst_rate numeric(5,2) not null default 0;
alter table public.invoices add column if not exists tax_mode text not null default 'none';
alter table public.invoices add column if not exists round_off numeric(6,2) not null default 0;
alter table public.invoices add column if not exists numbering text not null default 'auto';
alter table public.invoices add column if not exists requested_invoice_no text;
alter table public.invoices add column if not exists notes text;
alter table public.invoices add column if not exists reissue_of uuid;
alter table public.invoices add column if not exists finalized_at timestamptz;
alter table public.invoices add column if not exists updated_at timestamptz not null default now();

-- Bill-to snapshot (same definitions as migration_2026_10_15_client_mapping.sql).
-- Repeated here so this migration works whether or not that one has been run;
-- every statement is create-if-missing / create-or-replace with identical bodies.
alter table public.invoices add column if not exists bill_to_name    text;
alter table public.invoices add column if not exists bill_to_gstin   text;
alter table public.invoices add column if not exists bill_to_state   text;
alter table public.invoices add column if not exists bill_to_address text;
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
-- Freeze existing invoices with the client's CURRENT details (only rows without
-- a snapshot). Run BEFORE renaming any client so old invoices keep original names.
update public.invoices i
   set bill_to_name = c.name, bill_to_gstin = nullif(c.gstin, ''), bill_to_state = c.state, bill_to_address = c.address
  from public.clients c
 where i.bill_to_name is null and c.id = i.client_id and c.owner_id = i.owner_id;

-- One-time backfill of existing invoices (runs before the immutability trigger exists).
update public.invoices
   set taxable_value = subtotal,
       gst_rate = case when kind = 'gst' then 18 else 0 end,
       tax_mode = case when kind = 'gst' and igst > 0 then 'inter'
                       when kind = 'gst' then 'intra' else 'none' end,
       finalized_at = coalesce(finalized_at, created_at)
 where taxable_value is null;
alter table public.invoices alter column taxable_value set not null;

alter table public.invoices drop constraint if exists invoices_tax_mode_chk;
alter table public.invoices add constraint invoices_tax_mode_chk check (tax_mode in ('none', 'intra', 'inter'));
alter table public.invoices drop constraint if exists invoices_numbering_chk;
alter table public.invoices add constraint invoices_numbering_chk check (numbering in ('auto', 'manual'));
alter table public.invoices drop constraint if exists invoices_round_off_chk;
alter table public.invoices add constraint invoices_round_off_chk check (round_off between -0.99 and 0.99);
alter table public.invoices drop constraint if exists invoices_notes_chk;
alter table public.invoices add constraint invoices_notes_chk check (notes is null or char_length(notes) <= 500);
alter table public.invoices drop constraint if exists invoices_requested_no_chk;
alter table public.invoices add constraint invoices_requested_no_chk
  check (requested_invoice_no is null or requested_invoice_no ~ '^[A-Za-z0-9][A-Za-z0-9/_-]{0,39}$');
alter table public.invoices drop constraint if exists invoices_number_when_issued_chk;
alter table public.invoices add constraint invoices_number_when_issued_chk
  check (status = 'draft' or (fy is not null and invoice_no is not null and (numbering = 'manual' or seq is not null)));
alter table public.invoices drop constraint if exists invoices_draft_unnumbered_chk;
alter table public.invoices add constraint invoices_draft_unnumbered_chk
  check (status <> 'draft' or (seq is null and invoice_no is null));
-- NOT VALID: checked for every new/changed row; historic rows are left exactly as issued.
alter table public.invoices drop constraint if exists invoices_totals_chk;
alter table public.invoices add constraint invoices_totals_chk
  check (taxable_value = subtotal + charges_total
         and total = taxable_value + cgst + sgst + igst + round_off) not valid;
alter table public.invoices drop constraint if exists invoices_tax_rule_chk;
alter table public.invoices add constraint invoices_tax_rule_chk check (
  (kind = 'nongst' and tax_mode = 'none' and gst_rate = 0)
  or (kind = 'gst' and tax_mode = 'intra' and gst_rate in (5, 12, 18, 28) and igst = 0 and cgst = sgst)
  or (kind = 'gst' and tax_mode = 'inter' and gst_rate in (5, 12, 18, 28) and cgst = 0 and sgst = 0)
) not valid;
alter table public.invoices drop constraint if exists invoices_reissue_fk;
alter table public.invoices add constraint invoices_reissue_fk
  foreign key (owner_id, reissue_of) references public.invoices (owner_id, id) on delete restrict;
create unique index if not exists invoices_one_active_reissue
  on public.invoices (owner_id, reissue_of) where reissue_of is not null and status <> 'cancelled';
create index if not exists invoices_owner_drafts_idx on public.invoices (owner_id) where status = 'draft';

-- Rows inserted by the existing create_invoice() get consistent new columns.
create or replace function public.invoices_fill_new_columns()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.taxable_value is null then new.taxable_value := new.subtotal + coalesce(new.charges_total, 0); end if;
  if new.kind = 'gst' and new.tax_mode = 'none' then
    new.tax_mode := case when new.igst > 0 then 'inter' else 'intra' end;
    if new.gst_rate = 0 then new.gst_rate := 18; end if;
  end if;
  if new.status <> 'draft' and new.finalized_at is null then new.finalized_at := now(); end if;
  return new;
end $$;
drop trigger if exists invoices_fill_new_columns on public.invoices;
create trigger invoices_fill_new_columns before insert on public.invoices
  for each row execute function public.invoices_fill_new_columns();

-- Bill-to snapshot may refresh while the invoice is still a draft; frozen afterwards.
create or replace function public.invoices_snapshot_guard()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if old.status = 'draft' then return new; end if;
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

-- Issued / cancelled invoices are immutable for EVERY role (service role included).
-- Allowed: draft edits, draft -> issued, draft delete, issued -> cancelled (status,
-- cancelled_at, cancel_reason only), and filling an EMPTY bill-to snapshot once
-- (so the client-mapping backfill still works if it is run after this migration).
create or replace function public.invoices_immutable()
returns trigger language plpgsql set search_path = '' as $$
declare v public.invoices; o public.invoices;
begin
  if tg_op = 'DELETE' then
    if old.status <> 'draft' then
      raise exception 'Issued invoices cannot be deleted. Cancel and reissue instead.' using errcode = 'P0001';
    end if;
    return old;
  end if;
  if old.status = 'draft' then
    if new.status = 'cancelled' then raise exception 'A draft cannot be cancelled; discard it instead.' using errcode = 'P0001'; end if;
    new.updated_at := now();
    return new;
  end if;
  o := old;
  if old.bill_to_name is null then
    o.bill_to_name := new.bill_to_name; o.bill_to_gstin := new.bill_to_gstin;
    o.bill_to_state := new.bill_to_state; o.bill_to_address := new.bill_to_address;
  end if;
  if old.status = 'issued' and new.status = 'cancelled' then
    v := new;
    v.status := old.status; v.cancelled_at := old.cancelled_at; v.cancel_reason := old.cancel_reason;
    if v is distinct from o then
      raise exception 'Issued invoices are immutable. Only cancellation is allowed.' using errcode = 'P0001';
    end if;
    return new;
  end if;
  if new is distinct from o then
    raise exception 'Issued invoices are immutable. Cancel and reissue to correct them.' using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists invoices_immutable on public.invoices;
create trigger invoices_immutable before update or delete on public.invoices
  for each row execute function public.invoices_immutable();

-- ---------------------------------------------------------------------
-- 2. Series number format (prefix + FY format + separator + padding)
-- ---------------------------------------------------------------------
alter table public.invoice_series add column if not exists fy_format text not null default 'YYYY-YY';
alter table public.invoice_series add column if not exists separator text not null default '/';
alter table public.invoice_series add column if not exists pad smallint not null default 4;
alter table public.invoice_series drop constraint if exists invoice_series_format_chk;
alter table public.invoice_series add constraint invoice_series_format_chk
  check (fy_format in ('YYYY-YY', 'YY-YY', 'YYYYYY', 'YYYY') and separator in ('/', '-') and pad between 1 and 8);

-- fy is always stored as 'YYYY-YY' (e.g. 2026-27); only the printed number changes.
create or replace function public.format_invoice_no(p_prefix text, p_fy text, p_seq int,
                                                    p_fy_format text default 'YYYY-YY',
                                                    p_separator text default '/', p_pad int default 4)
returns text language sql immutable set search_path = '' as $$
  select p_prefix || p_separator ||
         case p_fy_format
           when 'YY-YY'  then substr(p_fy, 3, 2) || '-' || right(p_fy, 2)
           when 'YYYYYY' then left(p_fy, 4) || right(p_fy, 2)
           when 'YYYY'   then left(p_fy, 4)
           else p_fy end
         || p_separator ||
         case when length(p_seq::text) >= p_pad then p_seq::text else lpad(p_seq::text, p_pad, '0') end
$$;

create or replace function public.set_invoice_series_format(p_fy text, p_kind public.invoice_kind,
                                                            p_fy_format text, p_separator text, p_pad int)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not public.has_access() then raise exception 'Your trial or plan has expired.'; end if;
  if p_fy is null or p_fy !~ '^[0-9]{4}-[0-9]{2}$' then raise exception 'Invalid financial year'; end if;
  if p_fy_format not in ('YYYY-YY', 'YY-YY', 'YYYYYY', 'YYYY') then raise exception 'Invalid financial-year format'; end if;
  if p_separator not in ('/', '-') then raise exception 'Separator must be / or -'; end if;
  if p_pad is null or p_pad not between 1 and 8 then raise exception 'Number length must be 1 to 8 digits'; end if;
  if not exists (select 1 from public.invoice_series where owner_id = v_uid and fy = p_fy and kind = p_kind) then
    insert into public.invoice_series (owner_id, fy, kind, prefix, next_number)
    values (v_uid, p_fy, p_kind, case when p_kind = 'gst' then 'GST' else 'BOS' end,
            coalesce((select max(seq) from public.invoices where owner_id = v_uid and fy = p_fy and kind = p_kind), 0) + 1)
    on conflict (owner_id, fy, kind) do nothing;
  end if;
  update public.invoice_series set fy_format = p_fy_format, separator = p_separator, pad = p_pad
   where owner_id = v_uid and fy = p_fy and kind = p_kind;
end $$;

-- ---------------------------------------------------------------------
-- 3. Shipments reserved by a draft (so two drafts never take one shipment)
-- ---------------------------------------------------------------------
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'shipments_owner_id_id_key') then
    alter table public.shipments add constraint shipments_owner_id_id_key unique (owner_id, id);
  end if;
end $$;
alter table public.shipments add column if not exists draft_invoice_id uuid;
alter table public.shipments drop constraint if exists shipments_draft_invoice_fk;
alter table public.shipments add constraint shipments_draft_invoice_fk
  foreign key (owner_id, draft_invoice_id) references public.invoices (owner_id, id) on delete set null (draft_invoice_id);
alter table public.shipments drop constraint if exists shipments_draft_or_billed_chk;
alter table public.shipments add constraint shipments_draft_or_billed_chk check (draft_invoice_id is null or invoice_id is null);
create index if not exists shipments_draft_idx on public.shipments (owner_id, draft_invoice_id) where draft_invoice_id is not null;
-- No INSERT/UPDATE grant on draft_invoice_id: only the functions below set it.

create or replace function public.shipments_draft_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and old.invoice_id is null and new.invoice_id is not null and new.draft_invoice_id is not null then
    raise exception 'Shipment % is on a draft invoice. Finalize or discard that draft first.', old.awb using errcode = 'P0001';
  end if;
  if current_user in ('authenticated', 'anon') and old.draft_invoice_id is not null then
    raise exception 'Shipment % is on a draft invoice. Remove it from the draft or discard the draft first.', old.awb
      using errcode = 'P0001';
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists shipments_draft_guard on public.shipments;
create trigger shipments_draft_guard before update or delete on public.shipments
  for each row execute function public.shipments_draft_guard();

-- ---------------------------------------------------------------------
-- 4. invoice_lines: editable copy of each shipment on the invoice
-- ---------------------------------------------------------------------
create table if not exists public.invoice_lines (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  invoice_id uuid not null,
  shipment_id uuid,
  position int not null check (position between 1 and 100000),
  ship_date date not null,
  awb text not null check (char_length(awb) between 1 and 40),
  receiver_name text check (char_length(receiver_name) <= 160),
  destination text check (char_length(destination) <= 120),
  service text check (char_length(service) <= 60),
  shipment_type text check (char_length(shipment_type) <= 20),
  pieces int check (pieces between 1 and 10000),
  weight numeric(10,3) not null check (weight >= 0 and weight <= 9999999),
  rate numeric(12,2) not null check (rate >= 0 and rate <= 9999999999),
  amount numeric(12,2) not null check (amount > 0 and amount <= 9999999999),
  declared_value numeric(14,2) check (declared_value >= 0),
  original_weight numeric(10,3) not null,
  original_rate numeric(12,2),
  original_amount numeric(12,2) not null,
  rate_zone text,
  rate_slab text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (invoice_id, shipment_id),
  foreign key (owner_id, invoice_id) references public.invoices (owner_id, id) on delete cascade,
  foreign key (owner_id, shipment_id) references public.shipments (owner_id, id) on delete set null (shipment_id)
);
create index if not exists invoice_lines_invoice_idx on public.invoice_lines (owner_id, invoice_id, position);
grant select on public.invoice_lines to authenticated;
grant all on public.invoice_lines to service_role;
alter table public.invoice_lines enable row level security;
drop policy if exists "invoice_lines: read own" on public.invoice_lines;
create policy "invoice_lines: read own" on public.invoice_lines for select to authenticated
  using (owner_id = auth.uid());

-- ---------------------------------------------------------------------
-- 5. invoice_charges: optional charges (fixed ₹ or % of a defined base)
-- ---------------------------------------------------------------------
create table if not exists public.invoice_charges (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  invoice_id uuid not null,
  position int not null check (position between 1 and 50),
  code text not null check (code in ('fuel', 'fov', 'packing', 'pickup', 'handling', 'delivery', 'extra', 'custom')),
  label text not null check (char_length(btrim(label)) between 1 and 60),
  mode text not null check (mode in ('fixed', 'percent')),
  base text not null check (base in ('none', 'subtotal', 'declared_value')),
  value numeric(14,4) not null check (value >= 0),
  amount numeric(14,2) not null check (amount >= 0),
  created_at timestamptz not null default now(),
  check ((mode = 'fixed' and base = 'none' and value <= 9999999999)
      or (mode = 'percent' and base in ('subtotal', 'declared_value') and value <= 100)),
  check (base <> 'declared_value' or code = 'fov'),
  foreign key (owner_id, invoice_id) references public.invoices (owner_id, id) on delete cascade
);
create index if not exists invoice_charges_invoice_idx on public.invoice_charges (owner_id, invoice_id, position);
grant select on public.invoice_charges to authenticated;
grant all on public.invoice_charges to service_role;
alter table public.invoice_charges enable row level security;
drop policy if exists "invoice_charges: read own" on public.invoice_charges;
create policy "invoice_charges: read own" on public.invoice_charges for select to authenticated
  using (owner_id = auth.uid());

-- Lines and charges can only change while their invoice is a draft (every role).
create or replace function public.invoice_children_guard()
returns trigger language plpgsql set search_path = '' as $$
declare v_status public.invoice_status;
begin
  select status into v_status from public.invoices where id = coalesce(new.invoice_id, old.invoice_id);
  if not found then
    if tg_op = 'DELETE' then return old; end if;   -- cascade from a discarded draft
    raise exception 'Invoice not found';
  end if;
  if v_status <> 'draft' then
    raise exception 'Lines and charges of an issued invoice cannot be changed.' using errcode = 'P0001';
  end if;
  if tg_op = 'UPDATE' and new.invoice_id <> old.invoice_id then raise exception 'Line cannot move to another invoice'; end if;
  return coalesce(new, old);
end $$;
drop trigger if exists invoice_lines_guard on public.invoice_lines;
create trigger invoice_lines_guard before insert or update or delete on public.invoice_lines
  for each row execute function public.invoice_children_guard();
drop trigger if exists invoice_charges_guard on public.invoice_charges;
create trigger invoice_charges_guard before insert or update or delete on public.invoice_charges
  for each row execute function public.invoice_children_guard();

-- ---------------------------------------------------------------------
-- 6. Internal helpers (service role only; called by the functions below)
-- ---------------------------------------------------------------------
-- Returns the tax mode for an invoice. GSTIN-based type locking is NOT
-- enforced yet (pending GST compliance review): the seller chooses GST or
-- Non-GST per invoice. Non-GST never carries tax; GST needs valid states so
-- the mode (CGST+SGST vs IGST) can be derived.
create or replace function public.invoice_tax_mode(p_uid uuid, p_client_id uuid, p_kind public.invoice_kind)
returns text language plpgsql stable security definer set search_path = '' as $$
declare v_state text; v_client public.clients;
begin
  select state into v_state from public.profiles where id = p_uid;
  select * into v_client from public.clients where id = p_client_id and owner_id = p_uid;
  if not found then raise exception 'Client not found'; end if;
  if p_kind = 'nongst' then return 'none'; end if;
  if public.gst_state_code(v_state) is null then
    raise exception 'Set a valid business state in Settings before issuing GST invoices' using errcode = 'P0001';
  end if;
  if public.gst_state_code(v_client.state) is null then
    raise exception 'Set a valid state for client % before issuing a GST invoice', v_client.name using errcode = 'P0001';
  end if;
  return case when public.gst_state_code(v_state) = public.gst_state_code(v_client.state) then 'intra' else 'inter' end;
end $$;

-- Recalculates every amount of a draft from its lines and charges. Never trusts the browser.
create or replace function public.invoice_recalc(p_invoice_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v public.invoices; v_mode text; v_sub numeric(14,2); v_declared numeric(16,2); v_lines int;
  v_charges numeric(14,2); v_taxable numeric(14,2); v_cgst numeric(14,2) := 0; v_igst numeric(14,2) := 0;
  v_total numeric(14,2);
begin
  select * into v from public.invoices where id = p_invoice_id for update;
  if not found or v.status <> 'draft' then raise exception 'Draft not found or already finalized'; end if;

  v_mode := public.invoice_tax_mode(v.owner_id, v.client_id, v.kind);
  if v.kind = 'gst' and v.gst_rate not in (5, 12, 18, 28) then
    raise exception 'GST rate must be 5, 12, 18 or 28%%' using errcode = 'P0001';
  end if;

  select count(*), coalesce(sum(amount), 0), coalesce(sum(declared_value), 0)
    into v_lines, v_sub, v_declared from public.invoice_lines where invoice_id = v.id;
  if v_lines = 0 then raise exception 'An invoice needs at least one shipment' using errcode = 'P0001'; end if;

  if exists (select 1 from public.invoice_charges where invoice_id = v.id and base = 'declared_value') and v_declared <= 0 then
    raise exception 'FOV on declared value needs a declared value on at least one shipment' using errcode = 'P0001';
  end if;
  update public.invoice_charges c
     set amount = case c.mode when 'fixed' then round(c.value, 2)
                   else round((case c.base when 'declared_value' then v_declared else v_sub end) * c.value / 100, 2) end
   where c.invoice_id = v.id;
  select coalesce(sum(amount), 0) into v_charges from public.invoice_charges where invoice_id = v.id;

  v_taxable := v_sub + v_charges;
  if v.kind = 'gst' then
    if v_mode = 'intra' then v_cgst := round(v_taxable * v.gst_rate / 200, 2);
    else v_igst := round(v_taxable * v.gst_rate / 100, 2); end if;
  end if;
  v_total := v_taxable + v_cgst * 2 + v_igst + v.round_off;
  if v_total < 0 then raise exception 'Grand total cannot be negative' using errcode = 'P0001'; end if;

  update public.invoices i
     set subtotal = v_sub, charges_total = v_charges, taxable_value = v_taxable,
         tax_mode = v_mode, gst_rate = case when v.kind = 'gst' then v.gst_rate else 0 end,
         cgst = v_cgst, sgst = v_cgst, igst = v_igst, total = v_total,
         bill_to_name = c.name, bill_to_gstin = nullif(c.gstin, ''), bill_to_state = c.state, bill_to_address = c.address
    from public.clients c
   where i.id = v.id and c.id = v.client_id and c.owner_id = v.owner_id;
end $$;

-- Adds shipments to a draft as lines (validates ownership/availability, reserves them).
create or replace function public.invoice_add_lines(p_invoice_id uuid, p_ids uuid[])
returns void language plpgsql security definer set search_path = '' as $$
declare v public.invoices; v_found int; v_bad int; v_pos int;
begin
  select * into v from public.invoices where id = p_invoice_id;
  if p_ids is null or cardinality(p_ids) = 0 then return; end if;
  perform 1 from public.shipments where owner_id = v.owner_id and id = any(p_ids) for update;
  select count(*) into v_found from public.shipments s
   where s.owner_id = v.owner_id and s.id = any(p_ids) and s.client_id = v.client_id
     and s.invoice_id is null and s.draft_invoice_id is null
     and s.ship_date between v.period_from and v.period_to;
  if v_found <> (select count(distinct x) from unnest(p_ids) x) then
    raise exception 'Some selected shipments are not available: they belong to another client, are outside the billing period, already invoiced or on another draft.'
      using errcode = 'P0001';
  end if;
  select count(*) into v_bad from public.shipments
   where owner_id = v.owner_id and id = any(p_ids) and pricing_status = 'needs_review';
  if v_bad > 0 then
    raise exception '% shipment(s) need review (city, zone or rate missing). Fix them before invoicing.', v_bad using errcode = 'P0001';
  end if;
  select count(*) into v_bad from public.shipments
   where owner_id = v.owner_id and id = any(p_ids) and (amount is null or amount <= 0);
  if v_bad > 0 then
    raise exception '% shipment(s) have an amount of ₹0 or less. Fix their amount before invoicing.', v_bad using errcode = 'P0001';
  end if;
  select coalesce(max(position), 0) into v_pos from public.invoice_lines where invoice_id = v.id;
  insert into public.invoice_lines (owner_id, invoice_id, shipment_id, position, ship_date, awb, receiver_name,
                                    destination, service, shipment_type, pieces, weight, rate, amount,
                                    original_weight, original_rate, original_amount, rate_zone, rate_slab)
  select s.owner_id, v.id, s.id, v_pos + row_number() over (order by s.ship_date, s.awb), s.ship_date, s.awb,
         s.receiver_name, s.destination, s.service, s.shipment_type, s.pieces, s.weight,
         coalesce(s.rate_applied, s.amount), s.amount, s.weight, s.rate_applied, s.amount, s.rate_zone, s.rate_slab
    from public.shipments s where s.owner_id = v.owner_id and s.id = any(p_ids);
  update public.shipments set draft_invoice_id = v.id where owner_id = v.owner_id and id = any(p_ids);
end $$;

-- ---------------------------------------------------------------------
-- 7. Public functions (signed-in sellers; every one checks ownership)
-- ---------------------------------------------------------------------
create or replace function public.create_invoice_draft(p_client_id uuid, p_from date, p_to date,
                                                       p_shipment_ids uuid[] default null,
                                                       p_invoice_date date default current_date,
                                                       p_kind public.invoice_kind default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_kind public.invoice_kind; v_mode text; v_ids uuid[]; v_id uuid;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not public.has_access() then raise exception 'Your trial or plan has expired. Renew to create invoices.'; end if;
  if p_from is null or p_to is null or p_from > p_to then raise exception 'Invalid billing period'; end if;
  if p_invoice_date is null then raise exception 'Invoice date required'; end if;
  if not exists (select 1 from public.clients where id = p_client_id and owner_id = v_uid) then
    raise exception 'Client not found';
  end if;
  -- Default type = existing create_invoice rule (client's GST setting), so a new
  -- draft starts exactly like today's invoice. The seller may change it explicitly.
  v_kind := coalesce(p_kind, case when (select is_gst from public.clients where id = p_client_id and owner_id = v_uid)
                                  then 'gst'::public.invoice_kind else 'nongst'::public.invoice_kind end);
  v_mode := public.invoice_tax_mode(v_uid, p_client_id, v_kind);

  if p_shipment_ids is null then
    select array_agg(id) into v_ids from public.shipments
     where owner_id = v_uid and client_id = p_client_id and invoice_id is null and draft_invoice_id is null
       and ship_date between p_from and p_to;
  else
    v_ids := p_shipment_ids;
  end if;
  if v_ids is null or cardinality(v_ids) = 0 then
    raise exception 'No unbilled shipments for this client in the selected period' using errcode = 'P0001';
  end if;

  insert into public.invoices (owner_id, client_id, kind, status, invoice_date, period_from, period_to,
                               subtotal, taxable_value, total, tax_mode, gst_rate)
  values (v_uid, p_client_id, v_kind, 'draft', p_invoice_date, p_from, p_to, 0, 0, 0, v_mode,
          case when v_kind = 'gst' then 18 else 0 end)
  returning id into v_id;
  perform public.invoice_add_lines(v_id, v_ids);
  perform public.invoice_recalc(v_id);
  return v_id;
end $$;

-- p_header: {invoice_date, period_from, period_to, kind, gst_rate, round_off, notes, numbering, requested_invoice_no}
-- p_lines:  [{shipment_id, weight, rate, amount, declared_value}]  (full list; omitted lines are removed)
-- p_charges:[{code, label, mode, base, value}]                     (full list; replaces existing)
create or replace function public.save_invoice_draft(p_invoice_id uuid, p_header jsonb, p_lines jsonb, p_charges jsonb)
returns public.invoices language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v public.invoices; v_kind public.invoice_kind; v_numbering text; v_req text;
  v_ids uuid[]; v_new uuid[]; e jsonb; i int := 0; v_code text; v_mode text; v_base text; v_label text;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not public.has_access() then raise exception 'Your trial or plan has expired.'; end if;
  select * into v from public.invoices where id = p_invoice_id and owner_id = v_uid and status = 'draft' for update;
  if not found then raise exception 'Draft not found or already finalized' using errcode = 'P0001'; end if;

  -- Header
  v_kind := coalesce((p_header->>'kind')::public.invoice_kind, v.kind);
  v_numbering := coalesce(p_header->>'numbering', v.numbering);
  if v_numbering not in ('auto', 'manual') then raise exception 'Numbering must be auto or manual'; end if;
  v_req := nullif(btrim(coalesce(p_header->>'requested_invoice_no', '')), '');
  if v_numbering = 'manual' then
    if v_req is null then raise exception 'Enter the manual invoice number' using errcode = 'P0001'; end if;
    if exists (select 1 from public.invoices where owner_id = v_uid and invoice_no = v_req) then
      raise exception 'Invoice number % is already used (cancelled numbers stay reserved).', v_req using errcode = 'P0001';
    end if;
  else
    v_req := null;
  end if;
  update public.invoices set
    kind = v_kind,
    invoice_date = coalesce((p_header->>'invoice_date')::date, v.invoice_date),
    period_from = coalesce((p_header->>'period_from')::date, v.period_from),
    period_to = coalesce((p_header->>'period_to')::date, v.period_to),
    gst_rate = case when v_kind = 'gst' then coalesce((p_header->>'gst_rate')::numeric, nullif(v.gst_rate, 0), 18) else 0 end,
    tax_mode = public.invoice_tax_mode(v_uid, v.client_id, v_kind),
    round_off = coalesce((p_header->>'round_off')::numeric, 0),
    notes = nullif(btrim(coalesce(p_header->>'notes', '')), ''),
    numbering = v_numbering,
    requested_invoice_no = v_req
  where id = v.id
  returning * into v;
  if v.period_from > v.period_to then raise exception 'Invalid billing period'; end if;

  -- Lines
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'An invoice needs at least one shipment' using errcode = 'P0001';
  end if;
  if jsonb_array_length(p_lines) > 5000 then raise exception 'Too many lines (max 5000)'; end if;
  select array_agg((x->>'shipment_id')::uuid) into v_ids from jsonb_array_elements(p_lines) x;
  if array_position(v_ids, null) is not null then raise exception 'Every line needs a shipment'; end if;
  if (select count(distinct x) from unnest(v_ids) x) <> cardinality(v_ids) then
    raise exception 'A shipment appears twice on the invoice' using errcode = 'P0001';
  end if;

  update public.shipments set draft_invoice_id = null
   where owner_id = v_uid and draft_invoice_id = v.id and not (id = any(v_ids));
  delete from public.invoice_lines where invoice_id = v.id and (shipment_id is null or not (shipment_id = any(v_ids)));
  select array_agg(x) into v_new from unnest(v_ids) x
   where not exists (select 1 from public.invoice_lines l where l.invoice_id = v.id and l.shipment_id = x);
  perform public.invoice_add_lines(v.id, v_new);
  if exists (select 1 from public.invoice_lines where invoice_id = v.id
              and ship_date not between v.period_from and v.period_to) then
    raise exception 'Some shipments are outside the billing period. Widen the period or remove them.' using errcode = 'P0001';
  end if;

  for e in select * from jsonb_array_elements(p_lines) loop
    i := i + 1;
    if (e->>'weight') is null or (e->>'rate') is null or (e->>'amount') is null then
      raise exception 'Line %: weight, rate and amount are required', i using errcode = 'P0001';
    end if;
    if (e->>'amount')::numeric <= 0 then
      raise exception 'Line %: amount must be more than ₹0', i using errcode = 'P0001';
    end if;
    update public.invoice_lines set
      position = i,
      weight = round((e->>'weight')::numeric, 3),
      rate = round((e->>'rate')::numeric, 2),
      amount = round((e->>'amount')::numeric, 2),
      declared_value = round(nullif(e->>'declared_value', '')::numeric, 2),
      updated_at = now()
    where invoice_id = v.id and shipment_id = (e->>'shipment_id')::uuid;
  end loop;

  -- Charges (replace the full list)
  delete from public.invoice_charges where invoice_id = v.id;
  if p_charges is not null and jsonb_typeof(p_charges) = 'array' then
    if jsonb_array_length(p_charges) > 20 then raise exception 'Too many charges (max 20)'; end if;
    i := 0;
    for e in select * from jsonb_array_elements(p_charges) loop
      i := i + 1;
      v_code := lower(coalesce(e->>'code', 'custom'));
      v_mode := lower(coalesce(e->>'mode', 'fixed'));
      v_base := case when v_mode = 'fixed' then 'none' else lower(coalesce(e->>'base', 'subtotal')) end;
      v_label := nullif(btrim(coalesce(e->>'label', '')), '');
      v_label := coalesce(v_label, case v_code when 'fuel' then 'Fuel Surcharge' when 'fov' then 'FOV'
        when 'packing' then 'Packing' when 'pickup' then 'Pickup' when 'handling' then 'Handling'
        when 'delivery' then 'Delivery' when 'extra' then 'Extra Charges' end);
      if v_label is null then raise exception 'Charge %: enter a name', i using errcode = 'P0001'; end if;
      if v_base = 'declared_value' and v_code <> 'fov' then
        raise exception 'Only FOV can be calculated on declared value' using errcode = 'P0001';
      end if;
      insert into public.invoice_charges (owner_id, invoice_id, position, code, label, mode, base, value, amount)
      values (v_uid, v.id, i, v_code, v_label, v_mode, v_base, (e->>'value')::numeric, 0);
    end loop;
  end if;

  perform public.invoice_recalc(v.id);
  select * into v from public.invoices where id = v.id;
  return v;
end $$;

create or replace function public.finalize_invoice(p_invoice_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v public.invoices; v_fy text; v_seq int; v_no text; s public.invoice_series;
  v_n bigint; v_tries int := 0;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not public.has_access() then raise exception 'Your trial or plan has expired. Renew to create invoices.'; end if;
  select * into v from public.invoices where id = p_invoice_id and owner_id = v_uid and status = 'draft' for update;
  if not found then raise exception 'Draft not found or already finalized' using errcode = 'P0001'; end if;

  perform public.invoice_recalc(v.id);       -- fresh totals + tax rules re-checked
  select * into v from public.invoices where id = v.id;

  perform 1 from public.shipments where owner_id = v_uid and draft_invoice_id = v.id for update;
  if exists (select 1 from public.invoice_lines l
              left join public.shipments s on s.id = l.shipment_id and s.owner_id = l.owner_id
             where l.invoice_id = v.id
               and (s.id is null or s.draft_invoice_id is distinct from v.id or s.invoice_id is not null
                    or s.pricing_status = 'needs_review' or s.amount <= 0)) then
    raise exception 'Some shipments on this draft changed or need review. Re-open the draft and check them.' using errcode = 'P0001';
  end if;

  v_fy := public.fy_label(v.invoice_date);
  if v.numbering = 'manual' then
    v_no := v.requested_invoice_no;
    if v_no is null then raise exception 'Enter the manual invoice number' using errcode = 'P0001'; end if;
    if exists (select 1 from public.invoices where owner_id = v_uid and invoice_no = v_no) then
      raise exception 'Invoice number % is already used (cancelled numbers stay reserved).', v_no using errcode = 'P0001';
    end if;
    -- Block anything that starts like an automatic number (any FY, any format,
    -- and the fixed format used by the existing create_invoice), so a manual
    -- entry can never collide with a number the auto series hands out later.
    if exists (select 1 from (select prefix from public.invoice_series where owner_id = v_uid
                              union select 'GST' union select 'BOS') x
                where upper(v_no) like upper(x.prefix) || '/%' or upper(v_no) like upper(x.prefix) || '-%') then
      raise exception 'Number % belongs to your automatic series. Use automatic numbering or a number that does not start with your series prefix.', v_no
        using errcode = 'P0001';
    end if;
  else
    if not exists (select 1 from public.invoice_series where owner_id = v_uid and fy = v_fy and kind = v.kind) then
      insert into public.invoice_series (owner_id, fy, kind, prefix, next_number)
      values (v_uid, v_fy, v.kind, case when v.kind = 'gst' then 'GST' else 'BOS' end,
              coalesce((select max(seq) from public.invoices where owner_id = v_uid and fy = v_fy and kind = v.kind), 0) + 1)
      on conflict (owner_id, fy, kind) do nothing;
    end if;
    loop   -- row lock serialises numbering; numbers taken by manual entries are skipped, never reused
      v_tries := v_tries + 1;
      if v_tries > 1000 then raise exception 'Could not allocate an invoice number'; end if;
      update public.invoice_series set next_number = next_number + 1
       where owner_id = v_uid and fy = v_fy and kind = v.kind
       returning * into s;
      if not found then raise exception 'Invoice series unavailable'; end if;
      v_seq := s.next_number - 1;
      v_no := public.format_invoice_no(s.prefix, s.fy, v_seq, s.fy_format, s.separator, s.pad);
      exit when not exists (select 1 from public.invoices where owner_id = v_uid and invoice_no = v_no);
    end loop;
  end if;

  begin
    update public.invoices
       set status = 'issued', fy = v_fy, seq = case when v.numbering = 'auto' then v_seq end,
           invoice_no = v_no, finalized_at = now()
     where id = v.id;
  exception when unique_violation then
    raise exception 'Invoice number % is already used. Please try again.', v_no using errcode = 'P0001';
  end;
  update public.shipments set invoice_id = v.id, draft_invoice_id = null
   where owner_id = v_uid and draft_invoice_id = v.id;
  return v.id;
end $$;

create or replace function public.discard_invoice_draft(p_invoice_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  perform 1 from public.invoices where id = p_invoice_id and owner_id = v_uid and status = 'draft' for update;
  if not found then raise exception 'Draft not found or already finalized' using errcode = 'P0001'; end if;
  update public.shipments set draft_invoice_id = null where owner_id = v_uid and draft_invoice_id = p_invoice_id;
  delete from public.invoice_charges where invoice_id = p_invoice_id;
  delete from public.invoice_lines where invoice_id = p_invoice_id;
  delete from public.invoices where id = p_invoice_id;
end $$;

-- Corrections: start a new draft from a CANCELLED invoice. The cancelled invoice
-- keeps its number and contents; the new draft links back via reissue_of.
create or replace function public.reissue_invoice(p_cancelled_id uuid, p_kind public.invoice_kind default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); o public.invoices; v_ids uuid[]; v_id uuid;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not public.has_access() then raise exception 'Your trial or plan has expired.'; end if;
  select * into o from public.invoices where id = p_cancelled_id and owner_id = v_uid;
  if not found then raise exception 'Invoice not found'; end if;
  if o.status <> 'cancelled' then raise exception 'Only cancelled invoices can be reissued. Cancel it first.' using errcode = 'P0001'; end if;
  if exists (select 1 from public.invoices where owner_id = v_uid and reissue_of = o.id and status <> 'cancelled') then
    raise exception 'This invoice already has a reissued draft or invoice' using errcode = 'P0001';
  end if;

  if exists (select 1 from public.invoice_lines where invoice_id = o.id) then
    select array_agg(l.shipment_id) into v_ids from public.invoice_lines l
      join public.shipments s on s.id = l.shipment_id and s.owner_id = v_uid
     where l.invoice_id = o.id and s.invoice_id is null and s.draft_invoice_id is null;
    if v_ids is null then
      raise exception 'None of the shipments from this invoice are available to reissue' using errcode = 'P0001';
    end if;
  end if;   -- legacy invoice without lines: take the unbilled shipments of the same client and period

  v_id := public.create_invoice_draft(o.client_id, o.period_from, o.period_to, v_ids, current_date, coalesce(p_kind, o.kind));
  update public.invoices set reissue_of = o.id, notes = o.notes, round_off = o.round_off,
         gst_rate = case when kind = 'gst' and o.gst_rate in (5, 12, 18, 28) then o.gst_rate else gst_rate end
   where id = v_id;
  update public.invoice_lines n
     set weight = l.weight, rate = l.rate, amount = l.amount, declared_value = l.declared_value
    from public.invoice_lines l
   where n.invoice_id = v_id and l.invoice_id = o.id and l.shipment_id = n.shipment_id;
  insert into public.invoice_charges (owner_id, invoice_id, position, code, label, mode, base, value, amount)
  select v_uid, v_id, position, code, label, mode, base, value, 0 from public.invoice_charges where invoice_id = o.id;
  perform public.invoice_recalc(v_id);
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- 8. Function privileges
-- ---------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.invoices_fill_new_columns()', 'public.invoices_snapshot_guard()', 'public.invoices_immutable()',
    'public.shipments_draft_guard()', 'public.invoice_children_guard()',
    'public.invoice_tax_mode(uuid, uuid, public.invoice_kind)', 'public.invoice_recalc(uuid)',
    'public.invoice_add_lines(uuid, uuid[])',
    'public.format_invoice_no(text, text, int, text, text, int)',
    'public.set_invoice_series_format(text, public.invoice_kind, text, text, int)',
    'public.create_invoice_draft(uuid, date, date, uuid[], date, public.invoice_kind)',
    'public.save_invoice_draft(uuid, jsonb, jsonb, jsonb)', 'public.finalize_invoice(uuid)',
    'public.discard_invoice_draft(uuid)', 'public.reissue_invoice(uuid, public.invoice_kind)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
grant execute on function public.format_invoice_no(text, text, int, text, text, int) to authenticated;
grant execute on function public.set_invoice_series_format(text, public.invoice_kind, text, text, int) to authenticated;
grant execute on function public.create_invoice_draft(uuid, date, date, uuid[], date, public.invoice_kind) to authenticated;
grant execute on function public.save_invoice_draft(uuid, jsonb, jsonb, jsonb) to authenticated;
grant execute on function public.finalize_invoice(uuid) to authenticated;
grant execute on function public.discard_invoice_draft(uuid) to authenticated;
grant execute on function public.reissue_invoice(uuid, public.invoice_kind) to authenticated;
-- Internal helpers (invoice_tax_mode, invoice_recalc, invoice_add_lines) stay service_role only.

commit;
notify pgrst, 'reload schema';
