# Client Merge, Safe Delete/Deactivate and Client Name Mapping (development only)

## What the database does today
- `clients`: unique (owner_id, name) is exact-case, so "abc traders" and "ABC TRADERS" can both exist. Seller RLS covers read/insert/update/delete (active plan); column-level grants.
- Links to a client:
  - `shipments` → **on delete restrict**
  - `invoices` → **on delete restrict**
  - zone rate cards and legacy rate slabs → **on delete cascade** (deleting a client silently deletes its rate cards)
- Invoices store `client_id` only, with no copy of the bill-to name/GSTIN/state. The invoice page reads them live from the client. **So invoices and their billed shipments must never be moved to another client**; that would change issued invoices.
- Shipments don't keep the raw Excel client name today.
- The current Delete button calls a direct delete; the database blocks it when shipments/invoices exist, but rate cards cascade.

## Merge — safe strategy
Pick primary (kept) and secondary (retired). Dialog shows both side by side: billing type, GSTIN, state, phone, active, counts of unbilled shipments, billed shipments, invoices and rate cards.

**Blocked, with an explanation, if any of these hold:**
- The secondary has any invoice or billed shipment (issued records must stay on their client).
- The secondary has its own rate cards that differ from the primary's (a seller must first remove or copy them in Rate Cards; never auto-overwritten).
- Same client chosen twice, or either client not owned by the seller.

**Shown as a warning, needing explicit confirmation:** different GST/NON-GST, GSTIN or state. Unbilled shipments will be billed with the primary's settings.

**What a merge does, in one transaction:**
1. Moves only the secondary's **unbilled** shipments to the primary; existing triggers re-price them with the primary's rate cards. The before/after total is shown in the dialog.
2. Re-points the secondary's name mappings to the primary, and adds a mapping "secondary name → primary".
3. **Deactivates** the secondary (never deleted, never renamed). Its details stay for audit.
4. Writes a `client_merges` audit row (who, when, primary, secondary, shipments moved, amount before/after).

## Safe Delete / Deactivate
- Delete is offered only when the client has no shipments, invoices or mappings. Confirmation lists any rate cards that will also be removed, and you must type the client name.
- Otherwise Delete is disabled with the reason, and **Deactivate** is offered instead (existing update, already RLS-protected).

## Client Name Mapping
- New "Client mapping" section on the Clients page: searchable list of raw Excel name → billing client (with GST/NON-GST, state). Add, edit and delete; many raw names may point to one client.
- Saved by `client_id`. One active mapping per normalised raw name per seller (database-enforced).
- Import order: **saved mapping → single exact-name match → explicit choice when several match → create new client** (if allowed). The mapped client's rate cards and GST setting apply automatically, since they belong to that client_id.
- The raw sheet name is stored on each imported shipment for traceability.
- "Save as mapping" checkbox on the import "Choose client…" picker so a choice is remembered.

## Database changes (minimal; you run the SQL in the dev SQL Editor)
1. Table `client_name_mappings(owner_id default auth.uid(), alias_norm, raw_name, client_id, created_at, updated_at)`
   - Primary key (owner_id, alias_norm) prevents conflicting mappings.
   - FK (owner_id, client_id) → clients(owner_id, id) **on delete restrict**: a mapping can never point to a deleted client.
   - Normalising trigger (same rules as the app: trim, collapse spaces, lowercase).
   - Grants: select, delete, insert(alias_norm, raw_name, client_id), update(client_id, raw_name) to authenticated; all to service_role.
   - RLS: owner-only read; insert/update/delete own with active plan (same as clients).
2. Column `shipments.source_client_name text` (nullable, ≤200 chars) added to the existing insert grant. Existing rows untouched.
3. Table `client_merges` (audit): owner read-only; written only by the merge function.
4. Function `merge_clients(p_owner, p_primary, p_secondary, p_confirm_billing_diff)`: SECURITY DEFINER, empty search_path, **service_role only**, called from a server function that first verifies the signed-in user (existing billing pattern). It locks both client rows, re-checks ownership and every block rule inside the transaction, then performs the steps above. Any failure rolls everything back.
5. Security tests added to the existing test script: cross-tenant mapping/merge rejected, mapping to another seller's client rejected, merge blocked with invoices/billed shipments/conflicting rate cards, deleting a mapped client blocked, duplicate mapping rejected.

No changes to existing tables' data, invoices, RLS of existing tables or the unique name rule.

## Frontend
- Clients page: duplicate warning gets **Open · Merge · Delete/Deactivate**; Merge dialog; Delete dialog; Client mapping section.
- Excel import: mapping lookup first, optional "Save as mapping", raw name saved per shipment.
- Uppercase display, autocomplete and duplicate detection unchanged.

## Order
SQL file + tests → you run them in development → frontend → type checks + tests → you verify in preview. Nothing published; production untouched.
