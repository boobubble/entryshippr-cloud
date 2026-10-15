# Phase 1 — Client Name Mapping, raw client names, Safe Delete/Deactivate (SQL + tests only)

Development project zfvnqcyqxxipjaugkmvf only. Client Merge is a later phase. On approval I create two files for your review; nothing is executed, no app code changes, nothing published.

## Deliverables
- `supabase/migration_2026_10_15_client_mapping.sql` — one transaction, re-runnable.
- `supabase/migration_2026_10_15_client_mapping_tests.sql` — runs inside a transaction and rolls back; uses the existing `expect_fail` style with exact error codes.
- Copies in Files for download.

## Confirmed current state
- Client policies: own rows only, writes need an active plan (`has_access()`).
- Authenticated users may delete clients directly. Shipments and invoices block a delete, but zone rate cards and legacy rate slabs are silently deleted with the client.
- Shipments have no column for the raw Excel client name; inserts use a column-level grant list.

## 1. Client name mappings (new table)
- Columns: owner_id (always the signed-in seller, set by default and checked by policy), alias_norm, raw_name, client_id, created_at, updated_at.
- One mapping per normalised raw name per seller (primary key owner_id + alias_norm). A conflicting insert fails with 23505 and is never overwritten silently.
- Normalising trigger, same rule as the app: trim, collapse spaces, lowercase. Rejects empty names; raw_name ≤ 200 characters.
- Link to clients is tenant-scoped (owner_id + client_id) with **on delete restrict**, so a mapping can never point to a deleted client or another seller's client.
- Grants: select, delete; insert (raw_name, client_id); update (raw_name, client_id) to authenticated; all to service_role. owner_id and alias_norm can't be written directly (alias_norm comes from raw_name).
- RLS: read own; insert, update and delete own only with an active plan.

## 2. Raw client name on shipments
- New nullable column `source_client_name` (≤ 200 chars). Existing rows untouched.
- Added to the insert grant only. No update grant, so it stays as imported.
- No trigger or pricing changes.

## 3. Safe Delete / Deactivate
- Revoke direct client delete from authenticated users (service_role keeps it).
- New function `delete_client(p_client_id, p_confirm_rate_cards int)`:
  - Runs as the signed-in user's identity (auth.uid()); no owner parameter, so the owner can't be spoofed.
  - Requires an active plan; locks the client row.
  - Refuses (P0001, clear message) if the client has any shipments, invoices or name mappings. The seller should deactivate instead.
  - Counts the client's rate cards (zone and legacy). If that count is not zero and doesn't equal `p_confirm_rate_cards`, it refuses and reports the count. Rate cards are never removed without an explicit, matching confirmation.
  - Otherwise deletes the client, letting its confirmed rate cards cascade.
  - EXECUTE granted to authenticated only; empty search_path; fully qualified names.
- Deactivate keeps using the existing column update (already restricted by RLS and the 50-client limit trigger).
- Read helper `client_usage(p_client_id)` returns counts of shipments, billed shipments, invoices, rate cards and mappings for the signed-in seller. The app uses it to show reasons and counts before you confirm.

## 4. Security tests (two test sellers A and B)
- Mapping:
  - A creates and edits a mapping.
  - Duplicate normalised name ("abc  traders" vs "ABC TRADERS") fails with 23505.
  - A can't map to B's client.
  - B can't read, change or delete A's mappings.
  - owner_id and alias_norm can't be set directly (42501).
  - An expired plan can read but not write.
- Raw name: insert with source_client_name works; a later update is denied (42501).
- Delete:
  - Direct delete denied (42501).
  - delete_client refuses with shipments, with invoices and with mappings.
  - It refuses rate cards without a matching count and succeeds with it.
  - B can't delete A's client (not found).
  - Mapped client can't be removed, even by cascade.
- Invoices, invoice numbers and shipment amounts are compared before and after: unchanged.

## Not changed
Existing tables' data, invoices, pricing functions, existing RLS (except revoking direct client delete), the exact-name unique rule on clients, production.

## After you run and approve Phase 1
Frontend: Client mapping section (search/add/edit/delete), import resolves mapping first and saves the raw name, and Delete/Deactivate dialogs use client_usage and delete_client. Then Phase 2 (Merge) gets its own plan.
