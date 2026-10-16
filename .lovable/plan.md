# Service options: DOX Standard/Fast, NON-DOX Surface/Air/Fast

Review only. No SQL is run and no code is changed until you approve.

## What I found

- The database only accepts **Standard** or **Fast**. This applies to price-list rows and to all DOX/NON-DOX shipments.
- Pricing matches the service exactly. A NON-DOX Air shipment only uses NON-DOX Air rates. If there's no Air price list, it becomes Needs Review at ₹0. Prices never borrow from another service, so Needs Review keeps working without changes.
- Excel import currently turns "Air", "Express" or "Priority" into **Fast** and everything else into **Standard**. That is the silent mapping to remove.
- The invoice, the Shipments list and the billing export show the stored service name, so the new names appear there automatically.

## Decision needed: existing NON-DOX "Standard" data

NON-DOX Standard won't be a valid choice anymore. Existing records:

- **Option A (recommended): keep as old data.** The database still accepts NON-DOX Standard on records that already exist, but nothing new can use it. Nothing is renamed and no invoice changes. Old NON-DOX Standard price lists stay readable, and you re-enter them as Surface or Air yourself.
- **Option B: rename NON-DOX Standard to Surface.** This applies only to price lists and to shipments that aren't on any invoice. Invoiced and draft shipments stay as they are because they're locked. This only works if every old NON-DOX Standard really was Surface. Imported "Air" rows were saved as Fast, so they can't be told apart now.

NON-DOX Fast stays exactly as it is under both options.

## Database update (DEV only, one new file)

`supabase/migration_2026_10_16_service_matrix.sql`
- `rate_slabs` service check: change it to the allowed pairs (DOX: Standard/Fast; NON-DOX: Surface/Air/Fast). Option A also keeps existing NON-DOX Standard rows valid.
- `save_rate_card()`: same allowed pairs, so no new NON-DOX Standard price list can be saved.
- `shipments_typed_service_chk`: same allowed pairs. Option A allows old NON-DOX Standard only on existing rows, using a trigger that blocks new inserts or changes *to* it.
- `copy_rate_cards`, `shipment_rate`, `shipments_apply_rate`, invoices, numbering, GST, locks and audit stay unchanged.
- A matching rollback-only test file, `..._service_matrix_tests.sql`. It checks that Air never prices from Surface or Fast, missing Air gives Needs Review, DOX Standard/Fast pricing is unchanged, and existing shipments and invoices are untouched.

## App changes

- `src/lib/rates.ts`: service list for each type; import name matching ("air" goes to Air, "surface"/"ground" to Surface, "fast"/"express"/"priority" to Fast). An unrecognised NON-DOX service is no longer guessed: the row becomes Needs Review.
- `src/routes/_app/entry.tsx`: the Service dropdown follows the Type (DOX: Standard/Fast; NON-DOX: Surface/Air/Fast). Changing the type resets the service if it isn't valid for that type.
- `src/routes/_app/rate-cards.tsx`: the price-list sections follow the selected type.
- `src/routes/_app/import.tsx`: uses the new matching and service type.
- `src/test/rates.test.ts`: tests for the matrix, Air never using Surface or Fast, and missing Air giving Needs Review.

No changes to invoices, the export layout, numbering, GST or production. Nothing is published.
