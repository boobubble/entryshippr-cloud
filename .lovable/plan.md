# City & Zone Master — "Add a city" redesign

## Finding: does add_city require state?
Yes. `add_city(p_name, p_state, p_district)` rejects a missing/invalid state and matches on (name, state, district). It cannot do name-only entry.

However, the existing `register_cities(p_names text[])` RPC already does exactly what name-only entry needs:
- resolves via `city_resolve` (seller confirmations → global name → global aliases),
- reuses an existing global city when exactly one matches,
- returns `ambiguous` + candidate list (name/state/district) when several match — never guesses,
- registers an unknown valid name globally (state NULL, source `user`) via `ensure_city`, with ON CONFLICT reuse,
- registers only when the seller has an active plan/trial (expired = resolve only).

**Proposed backend change: none.** Name-only entry is built on `register_cities`; `add_city` is kept for the optional Advanced path. No SQL, table, RLS or migration changes.

## New form
```text
City name *        [ Nashik            ]   (live list of matching global cities)
My zone *          [ West          v ]     (from seller's own zones; "+ New zone")
> Advanced: State / District (optional — only to tell same-name cities apart)
[ Add & assign ]
```

## Submit flow
1. Validate city name and zone (create zone first if "+ New zone").
2. If Advanced state is filled → `add_city(name, state, district)` (reuses existing or adds a new global city).
   Else → `register_cities([name])`:
   - `mapped`/`unmapped` with city_id → use it (existing global city reused).
   - `ambiguous` → show inline "Which one?" picker with candidates (name, district, state). Seller must pick; on pick, save the confirmation to `seller_city_aliases` (own account only).
   - `invalid` → show the reason; nothing saved.
   - no city_id because plan expired → show read-only message.
3. Upsert `seller_city_zones (city_id, zone_id)` on (owner_id, city_id). If the city was already in another zone, toast "Moved from X to Y".
4. Existing database triggers re-price that seller's Needs Review shipments automatically; refresh lists and the review counts.

## Guarantees kept
- Global registry shared; zone mappings and confirmations private (existing RLS, `owner_id = auth.uid()`).
- Never guesses a state; same-name cities always need explicit seller choice.
- No duplicate cities (resolve-first + unique index + ON CONFLICT).
- Pricing chain City → Seller Zone → Rate Card → Slab → Amount unchanged.

## Technical details
- Files: `src/routes/_app/cities.tsx` only (form state `{name, zoneId, state, district}`, collapsible Advanced section, ambiguous-candidate picker). `StateSelect` reused inside Advanced. `CityZoneDialog`, import and shipments untouched.
- Zone dropdown uses the existing seller zones query (RLS-scoped).
- Known limitation: a name-only new city is stored with no state; it can later become ambiguous if a same-name city in a real state is added, at which point the seller is asked to confirm once. Optional later hardening (not proposed now): an RPC that lets the creating seller attach a state to a state-less city they created.
- Verification: type check, existing tests, Playwright on sign-in page only (authenticated UI can't be signed into from here).
