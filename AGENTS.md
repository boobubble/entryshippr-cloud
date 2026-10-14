# EntrySetu
- Backend is the user's external Supabase (URL + publishable key in src/lib/supabase.ts); Lovable Cloud is not used — user's explicit choice.
- Schema lives in supabase/entrysetu_schema.sql and is applied manually by the user in the Supabase SQL Editor — no migration tooling access.
- Privileged writes (payments, plan activation, admin actions) go through server functions in src/lib/billing.functions.ts using EXT_SUPABASE_SECRET_KEY via REST; the browser can only update whitelisted profile columns.
- Signed-in pages live under src/routes/_app (ssr:false, client-side getUser gate) — the session is in localStorage.
