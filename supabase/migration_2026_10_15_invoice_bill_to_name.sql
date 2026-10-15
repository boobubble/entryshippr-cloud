-- =====================================================================
-- EntrySetu V1 — Editable Bill To Name on draft invoices. DEVELOPMENT ONLY
-- (zfvnqcyqxxipjaugkmvf). Never run on production.
-- Run AFTER migration_2026_10_15_invoice_editor_part1.sql and
-- migration_2026_10_15_invoice_editor.sql. Re-runnable.
--
-- What changes
--   * invoices.bill_to_name_custom (boolean, default false): true when the seller
--     set a Bill To Name for this invoice. Existing rows get false = today's
--     behaviour; no existing invoice value is changed.
--   * invoice_recalc: keeps a custom name; otherwise refreshes it from the client
--     as before. GSTIN / state / address still always come from the client.
--   * save_invoice_draft: optional header key "bill_to_name" (drafts only, blank
--     rejected). Same signature, privileges and ownership checks.
--   * reissue_invoice: the new draft inherits the cancelled invoice's saved name.
-- What does NOT change
--   Client records, client_id, shipments, GST maths, numbering, RLS, table grants,
--   and the triggers that freeze issued / cancelled invoices (invoices_immutable,
--   invoices_snapshot_guard) — they already block any name change after issue.
--   create_invoice_draft is untouched: new drafts start with the client's current
--   name via the existing invoices_snapshot_client trigger + invoice_recalc.
-- =====================================================================

alter table public.invoices add column if not exists bill_to_name_custom boolean not null default false;

-- A custom name must be a real name. NOT VALID: only new/changed rows are checked;
-- historical rows are never re-checked (they all have custom = false anyway).
alter table public.invoices drop constraint if exists invoices_bill_to_name_custom_chk;
alter table public.invoices add constraint invoices_bill_to_name_custom_chk
  check (not bill_to_name_custom
         or (bill_to_name is not null and btrim(bill_to_name) <> '' and char_length(bill_to_name) <= 200)) not valid;

-- Recalculates every amount of a draft from its lines and charges. Never trusts the browser.
-- Bill To Name: kept when custom, otherwise refreshed from the client (unchanged rule).
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
         bill_to_name = case when v.bill_to_name_custom then v.bill_to_name else c.name end, bill_to_gstin = nullif(c.gstin, ''), bill_to_state = c.state, bill_to_address = c.address
    from public.clients c
   where i.id = v.id and c.id = v.client_id and c.owner_id = v.owner_id;
end $$;

-- p_header may now also carry bill_to_name (see the Bill To Name block).
create or replace function public.save_invoice_draft(p_invoice_id uuid, p_header jsonb, p_lines jsonb, p_charges jsonb)
returns public.invoices language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v public.invoices; v_kind public.invoice_kind; v_numbering text; v_req text;
  v_ids uuid[]; v_new uuid[]; e jsonb; i int := 0; v_code text; v_mode text; v_base text; v_label text;
  v_name text; v_client_name text;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not public.has_access() then raise exception 'Your trial or plan has expired.'; end if;
  select * into v from public.invoices where id = p_invoice_id and owner_id = v_uid and status = 'draft' for update;
  if not found then raise exception 'Draft not found or already finalized' using errcode = 'P0001'; end if;

  -- Header (keys left out of p_header keep their current value)
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
    round_off = case when p_header ? 'round_off' then coalesce((p_header->>'round_off')::numeric, 0) else v.round_off end,
    -- taxes are rewritten by invoice_recalc below; clear them so a GST -> Non-GST
    -- switch satisfies the existing "Non-GST carries no tax" check mid-call
    cgst = 0, sgst = 0, igst = 0,
    notes = case when p_header ? 'notes' then nullif(btrim(coalesce(p_header->>'notes', '')), '') else v.notes end,
    numbering = v_numbering,
    requested_invoice_no = v_req
  where id = v.id
  returning * into v;
  if v.period_from > v.period_to then raise exception 'Invalid billing period'; end if;

  -- Bill To Name (draft only; key left out = keep current). Trimmed, inner spaces
  -- collapsed, UPPERCASE like client names. Blank / whitespace-only / JSON null is
  -- rejected. Typing exactly the client's current name clears the custom flag so the
  -- draft follows that client again; anything else is kept through every recalc.
  if p_header ? 'bill_to_name' then
    v_name := upper(regexp_replace(btrim(coalesce(p_header->>'bill_to_name', '')), '\s+', ' ', 'g'));
    if v_name = '' then raise exception 'Bill To Name cannot be blank' using errcode = 'P0001'; end if;
    if char_length(v_name) > 200 then
      raise exception 'Bill To Name is too long (max 200 characters)' using errcode = 'P0001';
    end if;
    select upper(regexp_replace(btrim(c.name), '\s+', ' ', 'g')) into v_client_name
      from public.clients c where c.id = v.client_id and c.owner_id = v_uid;
    update public.invoices
       set bill_to_name = v_name, bill_to_name_custom = (v_name is distinct from v_client_name)
     where id = v.id
    returning * into v;
  end if;

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

  insert into entrysetu_private.shipment_transfer_grants values (txid_current(), v.id, 'release') on conflict do nothing;
  update public.shipments set draft_invoice_id = null
   where owner_id = v_uid and draft_invoice_id = v.id and not (id = any(v_ids));
  delete from entrysetu_private.shipment_transfer_grants where xact_id = txid_current() and invoice_id = v.id;
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
  -- Carry the cancelled invoice's saved Bill To Name forward (kept as custom, so a
  -- later client rename does not silently replace it; the seller can still edit it).
  update public.invoices set reissue_of = o.id, notes = o.notes, round_off = o.round_off,
         bill_to_name = coalesce(o.bill_to_name, bill_to_name),
         bill_to_name_custom = (o.bill_to_name is not null),
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

-- Same signatures as before; privileges re-stated exactly as in the editor migration.
revoke all on function public.invoice_recalc(uuid) from public, anon, authenticated;
grant execute on function public.invoice_recalc(uuid) to service_role;
revoke all on function public.save_invoice_draft(uuid, jsonb, jsonb, jsonb) from public, anon;
grant execute on function public.save_invoice_draft(uuid, jsonb, jsonb, jsonb) to authenticated, service_role;
revoke all on function public.reissue_invoice(uuid, public.invoice_kind) from public, anon;
grant execute on function public.reissue_invoice(uuid, public.invoice_kind) to authenticated, service_role;

notify pgrst, 'reload schema';
