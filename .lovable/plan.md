# Simplify City & Zone Management (V2, development only)

## What exists today
- Import already detects destination cities (`register_cities`) and flags unmapped/ambiguous ones; `CityZoneDialog` assigns zones one city at a time.
- City & Zone Master, CityZoneDialog and bulk assign all write `seller_city_zones` directly via `upsert(... onConflict owner_id,city_id)`.
- The schema file grants only column-level rights: INSERT (city_id, zone_id, updated_at), UPDATE (zone_id, updated_at), SELECT, DELETE. The "permission denied" means the dev database's grants don't match this (or the upsert path trips them). Your pasted `GRANT INSERT, UPDATE` on the whole table would also allow writing `owner_id` — not recommended.

## Backend fix (smallest safe option, needs your approval)
One new SQL function, no table/RLS changes:

`assign_city_zones(p_items jsonb)` — SECURITY DEFINER, empty search_path, EXECUTE granted to `authenticated` only.
- `owner_id` is always `auth.uid()` — never taken from input.
- Rejects any zone not owned by the caller and any unknown city_id.
- Requires an active trial/plan (same check `register_cities` uses).
- Upserts all rows in one transaction on (owner_id, city_id) → moving never duplicates.
- Existing triggers then re-price Needs Review shipments (City → Zone → Rate Card → Slab). Invoiced shipments untouched.
- Security tests added: cross-tenant zone rejected, owner spoofing impossible, expired plan blocked.

I'll give you the SQL file to run manually in the dev SQL Editor. Alternative if you prefer: just re-run the existing three column-level GRANT lines (no new function).

## Frontend
1. **One shared popup** `CityZoneDialog` rewritten as "Assign zones to new cities":
   - Lists every unmapped city with a zone dropdown (seller's zones) + "+ New zone" inline.
   - "Apply to selected" to give many cities the same zone.
   - Ambiguous names show a State/District picker (choice saved to `seller_city_aliases`).
   - "Save all" → single `assign_city_zones` call; "Skip" → shipments stay Needs Review at ₹0.
2. **Import**: after file parse, if any unmapped/ambiguous cities, open the popup automatically; on save, refresh the city map so the preview reprices. Column mapping, weight logic and duplicate detection unchanged.
3. **City & Zone Master**: Add City (name + zone, Advanced State/District only for ambiguity), bulk assign and move all call the same `assign_city_zones`.
4. Never auto-pick a zone; no defaults.

## Unchanged
Pricing chain, invoice safeguards (amount ≤ 0 blocked), historical invoice amounts, Excel mapping, duplicate detection. Production and entrysetu.in never touched; nothing published.

## Order
SQL file + tests → you run it in dev → frontend changes → tsgo + tests → you verify in preview.
