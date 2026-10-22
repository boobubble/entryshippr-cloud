# EntrySetu — isolated GSTIN verification

## Inspected findings
- Existing customer workflow is **Clients**, in `src/routes/_app/clients.tsx`. The `clients` table already stores GSTIN, name, address and state, with owner-scoped permissions and GSTIN/state-prefix consistency checks.
- No supplier form or supplier table exists in this repository. Integrate Clients only; do not create a supplier workflow.
- This is an ESM TanStack Start application using `createServerFn`, Nitro and the existing external DEV database. `vite.config.ts` defaults to the current hosted server target. No Vercel configuration is present; actual Vercel deployment compatibility cannot be established from this repository alone.
- Official `gstinapi@1.0.0` is dependency-free CommonJS and uses fetch, AbortController and timers, with no native/filesystem dependencies. Use its bundled ESM interoperability; confirm through automatic compilation and tests rather than introducing another server framework.
- Provider docs confirm the basic endpoint, safe sandbox GSTIN, distinct error statuses, checksum support and at most three attempts for 429/502.

## User-visible changes
- Add **Verify GSTIN** alongside the existing client GSTIN field, using current styling.
- Normalize and locally validate before lookup; show loading, Active → Verified, Cancelled/Suspended warnings, not-found, exhausted-credit and temporary-failure states distinctly.
- Display a minimal result and offer explicit **Apply verified details** confirmation for GSTIN, name, address and recognized state. Prefer trade name when present, otherwise legal name; show the proposed name before applying it.
- Never automatically replace entered values. Ignore stale results if GSTIN changes, the form closes or a different client opens. Keep ordinary client saves available when verification is unavailable.
- Preview available registration dates, taxpayer type, postal code and address details without adding columns or saving full responses. Never map provider city/locality to the city registry.
- Verification does not prove input-tax-credit or tax-deduction eligibility.

## Reliable usage protection — chosen approach
There is no standard built-in backend rate limiter. Use a small, database-backed atomic limiter rather than server-memory counters.

**Proposed limits for review:** five lookup starts per account per minute, 25 per account per UTC day; shared provider budget of 45 upstream attempts per minute and 250 per UTC day. These are protective defaults, not existing business rules. Count failures too; retries consume the shared attempt budget. No refund of reserved slots on failures, avoiding retry abuse.

- Add private counter storage, not a GST verification history table; store only owner/budget keys, timestamps and counts, never GSTINs, API results or credentials.
- Expose one tightly scoped quota RPC that derives the caller from `auth.uid()`, accepts no owner override and atomically locks account/shared budgets in a consistent order. No direct browser counter edits or cross-account reads; deny anonymous execution.
- Verify the user server-side first, then reserve capacity before each provider call; fail closed if the quota setup is absent or unavailable.
- The quota migration and rollback-only tests are **review-only**. Approval of this plan does not authorize SQL execution or production changes.

## Technical implementation and planned files
**Add:**
- `src/lib/gstin.ts`: shared normalization, validation, allowlisted result/status types and recognized state mapping.
- `src/lib/gstin.functions.ts`: authenticated POST server function, bounded input and no-store responses, dynamically importing server helpers inside its handler.
- `src/lib/gstin.server.ts`: fixed provider endpoint, server-only key, official SDK wrapper, request timeouts, narrow response validation and sanitized errors. Set SDK retries to zero and handle bounded backoff explicitly so each attempt reserves shared capacity; retry only 429/502, maximum three total attempts.
- `src/components/GstinVerification.tsx`: reusable verification/result/confirmation control for Clients, ready for any genuinely existing future supplier form.
- `src/test/gstin.test.ts`, `src/test/gstin-server.test.ts`, `src/test/gstin-verification.test.tsx`: validation, provider/auth/quotas and autofill behavior tests.
- `supabase/migration_2026_10_22_gstin_quota.sql` and `_tests.sql`: isolated quota proposal and rollback-only security/limit assertions, never executed here without separate approval.
- `docs/gstin-verification.md`: configuration, commands, limitations and deployment checklist.

**Modify:**
- `src/routes/_app/clients.tsx`: GSTIN control integration only; reuse existing client save and duplicate-name rules.
- `package.json`, `bun.lock`: official SDK dependency.
- `AGENTS.md`, `roadmap.md`: security boundaries and completion/blockers.

No client/profile columns, supplier tables, verification-history tables, payment logic, billing amounts, invoice snapshots, city tables or subscription changes.

## Credentials and hosting setup
- After plan approval, request `GSTINAPI_API_KEY` through a secure form, never chat; this brief explicitly requests a plain server environment variable. Get it from gstinapi.in → API Keys.
- For local development, use an uncommitted server environment setting. For Vercel, separately configure the exact name under Project Settings → Environment Variables in the intended environment. Never use a `VITE_` prefix.
- Do not edit hosting target settings or deploy. Vercel server-function support, environment scope and deployed revision require independent hosted verification.
- Log only allowlisted status/category and finite numeric `credits_remaining` when returned; never log raw errors/responses, credentials, request tokens or business records. Credits remain server-only.

## Verification
- Run `bunx vitest run src/test/gstin.test.ts src/test/gstin-server.test.ts src/test/gstin-verification.test.tsx`, then `bunx vitest run` for existing regressions.
- Tests: sandbox normalization/checksum, malformed inputs rejected before provider access; Active/Cancelled/Suspended; 400/401/402/403/404/429/502; missing key; timeout/network; malformed or mismatched success data; permanent failures not retried; three-attempt maximum and exponential delays; no raw provider leakage; absent/forged auth, caller-derived ownership and fail-closed quota errors.
- Rollback-only SQL tests: actual account limits, UTC day rollover, shared attempt limits, anonymous denial, no owner override/counter mutation/cross-account reads. True concurrent enforcement requires separately authorized database execution; do not claim mock tests prove it.
- UI tests and desktop/mobile browser checks: confirmation before overwriting, preserved fields on cancel/error, stale responses, changed GSTIN, duplicate-name validation and warning states.
- Automatic compilation is provided by this workspace; do not run a manual production build. Hosted production build remains unverified until deployment evidence is available.
- Use only documented sandbox `00AAAAA0000A1ZT` for any separately approved live provider check; never save that sandbox code as a real client or use a real customer GSTIN without authorization.

## Boundaries and remaining blockers
Nothing has been changed in app code, databases, Storage, credentials, Razorpay, production or deployments. Only planning/requirements tracking changed.

Implementation starts after plan review. Live verification additionally needs the provider key, separately approved DEV quota installation, and an authenticated external-DEV session. No SQL, Storage action, payment order or publishing is authorized by this plan.
