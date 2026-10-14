# EntrySetu
- Backend is the user's external Supabase (URL + publishable key in src/lib/supabase.ts); Lovable Cloud is not used — user's explicit choice.
- Schema lives in supabase/entrysetu_schema.sql and is applied manually by the user in the Supabase SQL Editor — no migration tooling access.
- Privileged writes (payment activation, admin actions) go through SECURITY DEFINER RPCs executable only by service_role, called from src/lib/billing.functions.ts and the Razorpay webhook with EXT_SUPABASE_SECRET_KEY; invoices are issued/cancelled only via create_invoice/cancel_invoice RPCs — keeps numbering atomic and billed data immutable.
- Signed-in pages live under src/routes/_app (ssr:false, client-side getUser gate) — the session is in localStorage.
