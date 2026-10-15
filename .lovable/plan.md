# Final Invoice Editor (draft step before issuing)

## What exists today
- Invoices are created in one step by the `create_invoice` RPC: it takes all unbilled shipments for a client and date range, works out GST (9% + 9% same state, 18% IGST otherwise), takes the next number from `invoice_series` and links the shipments. The invoice is `issued` straight away.
- `invoices` stores only subtotal, cgst, sgst, igst and total. There is no draft status, no line table, no charges, no round-off and no tax-rate fields.
- Invoice lines are read live from `shipments` (weight and amount). So editing a line on the invoice would change the shipment itself, which the brief does not allow.
- The invoice type (GST or Non-GST) comes from the client's setting and cannot be overridden. The two numbering series (GST and BOS) are already separate for each financial year.
- `cancel_invoice` already exists for cancelling. There is no reissue link.
- Users cannot write to `invoices` or `invoice_series` directly; all writes go through the database functions. This stays the same.

## Approach
All totals are calculated **in the database**. The editor shows a live preview using the same formula, and the database recalculates and checks every figure on save and on finalize.

```text
Select shipments -> Create draft (no number used yet) -> Edit lines, charges, taxes
  -> Save draft / Preview -> Finalize (number assigned, everything locked) -> Print / PDF
Issued invoice -> Cancel (reason kept) -> "Reissue as new draft" (copies lines and links to the old invoice)
```

### Calculation (rounded to 2 decimal places at each step)
1. Line subtotal = sum of the line amounts after edits
2. Each charge: a fixed ₹ amount, or a % of the **line subtotal** (the base is fixed and shown on screen)
3. Taxable value = line subtotal + all charges
4. GST invoice: CGST and SGST at rate/2 each when the seller's and client's states match, otherwise IGST at the full rate (default 18%, can be changed: 0, 5, 12, 18 or 28). Non-GST invoice: no tax.
5. Round-off: optional, between -₹1 and +₹1 (a button can work it out automatically)
6. Grand total = taxable value + taxes + round-off

## Database changes (new file `supabase/migration_2026_10_15_invoice_editor.sql`, for you to review; I won't run it)
- `invoice_status` enum: add a `draft` value.
- `invoices`: new columns `charges_total`, `taxable_value`, `gst_rate`, `tax_mode` (`intra`, `inter` or `none`), `round_off`, `notes`, `reissue_of` (link to the cancelled invoice). `fy`, `seq` and `invoice_no` can be empty while the invoice is a draft. Existing invoices are backfilled with `taxable_value = subtotal` and `gst_rate = 18`.
- New table `invoice_lines` (owner, invoice, shipment, ship_date, awb, receiver, destination, service, weight, rate, amount, plus the original weight and amount for the audit trail). It stores a copy of each shipment, so shipments and rate cards are never changed.
- New table `invoice_charges` (owner, invoice, label, mode `fixed` or `percent`, value, calculated amount, sort order).
- Both tables are read-only for signed-in users, with seller-only access rules and grants. All writes go through the functions below.
- A guard trigger stops any change to lines, charges or the invoice header once the status is not `draft`.
- Shipments are reserved while a draft holds them (new `draft_invoice_id` field) so two drafts can't take the same shipment. They link to the invoice only when it is finalized.
- New functions (seller-only, each rechecks every total):
  - `create_invoice_draft(client, from, to, shipment_ids[] default null, kind default by client)`
  - `save_invoice_draft(id, header jsonb, lines jsonb, charges jsonb)`: validates the data, recalculates the totals and blocks amounts at or below ₹0
  - `finalize_invoice(id, manual_no text default null)`: automatic numbering uses the series. A manual number must be unique within the seller's type and financial year and must not reuse a number the series has already given out.
  - `discard_invoice_draft(id)`
  - `reissue_invoice(cancelled_id)`: creates a new draft linked to the cancelled invoice
- The existing `create_invoice` stays as it is, so nothing breaks before the new screens go live.
- A matching `_tests.sql` file (rolled back at the end): seller isolation, editing blocked after finalize, duplicate manual numbers rejected, shipments and rate cards unchanged, totals recalculated on the server.

## Frontend
- "New invoice" now creates a **draft** and opens the editor, a new page at `/invoices/$id/edit`.
- Editor sections: Header (date, billing period, GST or Non-GST, number set automatically or typed in), Lines table (weight, rate and amount can be edited, with the original values shown), Charges (presets: Fuel Surcharge, FOV, Packing, Pickup, Handling, Delivery, Extra Charges, or a custom name; fixed ₹ or %), Tax (rate and same-state/other-state shown), Round-off, a live Totals panel, and Save Draft / Preview / Finalize / Discard buttons.
- The invoice list shows Draft, Issued and Cancelled badges. Cancelled invoices get a "Reissue" button.
- The shared invoice layout reads from `invoice_lines` and `invoice_charges` and shows charges, taxable value, taxes, round-off and grand total, so the preview and the PDF always match. Old invoices that have no lines still show their shipments, as they do today.
- Print / Save PDF is only offered for issued invoices.

## Order of work
1. Write the migration and test SQL for you to review (no database changes).
2. After you run them on DEV, build the editor, the list changes and the layout updates, then run all the tests.

## Questions to confirm
- Default % base = line subtotal. Should any charge (for example FOV) use a different base?
- Should manual invoice numbers keep the `PREFIX/FY/NNNN` format, or can they be any text?
