# EntrySetu: payment proofs, Super Admin and Blog CMS

## Review boundary

This report is based on local source and repository SQL, not a live DEV database inspection. No application code, SQL files, database records, environment variables or production settings have changed. Only the task roadmap and requirements memory were updated. Nothing was published.

Approve this plan to begin small implementation steps and generate additive DEV SQL plus rollback-only tests. **Plan approval is not permission to execute SQL.** Required schema/storage setup must be reviewed and explicitly approved separately; the existing external Supabase remains in use, Lovable Cloud stays off, and production is untouched.

## Existing functionality to reuse

| Existing files / database objects | Reuse and current gaps |
| --- | --- |
| `src/routes/_app/billing.tsx` | Existing subscription/payment page with Razorpay checkout and paid-only history; no screenshot submission currently exists. Add manual proof submission here, alongside—not replacing—Razorpay. |
| `src/lib/supabase.ts` | Existing external DEV connection and pricing: Standard ₹1,200/year, Standard Unlimited ₹1,800/year, first-purchase joining fee ₹3,000; retain the five-day trial and 50-active-client Standard limit. Do not introduce Basic/Pro monthly pricing. |
| `src/routes/auth.tsx`, `src/lib/hooks.ts`, `src/routes/_app/route.tsx` | Existing accounts, profile/access state, signed-in page gate and admin navigation. Reuse existing `admin` role rather than create duplicate roles or account systems. |
| `src/routes/_app/admin.tsx` | Existing seller list, paid history, grant/revoke/+5-day actions. Missing search, filters, pagination, seller detail, proof queue and action reasons/audit. |
| `src/lib/billing.functions.ts`, `src/routes/api/public/razorpay-webhook.ts` | Existing authenticated billing/admin calls, signature/capture checks and webhook. Keep Razorpay Test Mode; separate manual review from verified gateway activation. |
| `supabase/entrysetu_schema.sql`, `supabase/migration_2026_10_15_permission_hardening.sql` | Inspect/reuse `profiles`, `payments`, `user_roles`, `is_admin()`, `has_access()`, `activate_payment()`, `admin_set_access()` and their grants/RLS. Never rerun the base schema on an existing database. |
| `src/routes/index.tsx`, `src/routes/__root.tsx`, `src/components/PageHead.tsx`, `public/robots.txt` | Existing homepage, document shell and metadata conventions. No blog schema/editor/routes/storage integration or sitemap implementation currently exists. |
| `src/test/*`, `supabase/migration_2026_10_15_security_tests.sql` | Existing test setup and security patterns; add focused tests without changing shipment/invoice rules. |

Subscriptions currently live as the seller's plan and expiry on `profiles`; purchase history lives in `payments`. Reuse this model and link proofs to an actual payment record and its seller/plan rather than invent a second subscription engine.

## Step 1 — DEV database and storage proposals

Generate for review:
- `supabase/migration_2026_10_17_payment_proofs_admin.sql`
- `supabase/migration_2026_10_17_payment_proofs_admin_tests.sql`
- `supabase/migration_2026_10_17_blog_cms.sql`
- `supabase/migration_2026_10_17_blog_cms_tests.sql`

### Payment/admin changes

- `payments`: add a `razorpay/manual` channel. Change the existing **NOT NULL** requirement on `razorpay_order_id` to a channel-aware CHECK: Razorpay requires a real order ID; manual payments do not invent gateway IDs. Preserve its UNIQUE constraint, unique payment ID, positive amount, owner FK, existing rows and `created/paid/failed` enum.
- New `payment_submissions`: one submission per payment, owner/payment linkage enforced by a composite FK; proof path, bounded reference/UTR, MIME/byte count, Pending/Approved/Rejected, reviewer/time/reason. Keep review state separate from gateway payment state. Rejected submissions stay immutable; a new submission/payment records a retry. Do not silently reject duplicate UTRs globally or expose another seller's reference.
- New append-only `subscription_audit`: trusted actor, seller, action, reason, before/after access, payment reference and timestamp. No browser-written audit entries or editable history.
- New submit/review RPCs and an audited admin-access RPC: authenticated server checks plus database role validation; atomic row locks prevent double approval/extension. Upload/submission never activates access. Approval marks the manual payment paid, updates existing entitlement and joining-fee state, and writes audit in one transaction. Rejection writes its reason without changing access.
- `activate_payment()`: explicitly require a Razorpay-channel record so gateway callbacks cannot approve manual proofs. Preserve its existing amount checks, row-locking and idempotent paid handling.
- Preserve the existing service-only `admin_set_access(uuid,text,plan_kind)` signature for compatibility; enforce audit through the authoritative entitlement-write path, and have new interactive admin calls use the audited RPC with trusted actor/reason. Review legacy service calls explicitly so none become an unaudited bypass.
- All new public tables get explicit least-privilege grants, RLS and tightly scoped function execution. Existing profile plan-field restrictions remain intact.

### Storage setup — separate from SQL

Provision through the external Storage API only after separate approval; do not insert buckets through SQL or activate Cloud. Propose private `payment-proofs` and private `blog-images` buckets. Proposed limit: **5 MB per image**, PNG/JPEG/WebP only, no SVG. Private originals and immutable random paths; authorized signed access only. Bucket policies and file metadata checks are included in reviewed SQL, while bucket provisioning is a separate setup step. No payment destination, QR code or bank details will be invented.

### Blog schema

Add `blog_posts`, `blog_categories`, `blog_tags`, `blog_post_tags`. Posts contain title, unique normalized slug, excerpt, structured rich text, draft/published state, category, featured-image path/alt text, SEO title/description, author and content/publication timestamps. Enforce bounded fields, valid slugs, taxonomy FKs and valid publication state. Existing admins manage posts and taxonomy; ordinary users/anonymous visitors read only safe published content. Draft records, associations and images stay private. No sample posts are inserted.

## Step 2 — Payment proofs and admin UI

**Modify:**
- `src/routes/_app/billing.tsx`: proof/reference submission, file validation, pending/rejected/approved history, errors and retry; retain checkout and pricing.
- `src/routes/_app/admin.tsx`: server-backed search, plan/status/date filters, bounded pagination, payment/review queue, reasons and audit history.
- `src/lib/billing.functions.ts`: reuse gateway functions; route interactive access changes through the audited path and move shared secret-backed helpers behind a server-only boundary.
- `src/routes/api/public/razorpay-webhook.ts`: update imports only if shared helpers move; preserve signature checks and gateway behavior.

**Add:**
- `src/lib/billing.server.ts`: shared gateway/database helpers for handlers, not imported by UI.
- `src/lib/admin.functions.ts`, `src/lib/payment-proofs.functions.ts`: validate authenticated callers and database-backed admin roles before privileged work.
- `src/lib/payment-proof-validation.ts`: shared file/reference validation.
- `src/components/PaymentProofForm.tsx`, `src/components/admin/PaymentReview.tsx`: focused submission/review controls.
- `src/routes/_app/admin_.sellers.$id.tsx`: separately rendered protected seller detail, plan/dates and paginated payment/audit history, without requiring the current `/admin` page to become a layout.

Owner proof access is verified against its payment. Admin review URLs are short-lived and responses are private/no-store. Validate actual image signatures server-side as well as MIME, extension and size; never trust uploaded metadata or client-supplied seller/amount/reviewer values.

## Step 3 — Blog editor, public articles and SEO

**Add:**
- `src/lib/blog-validation.ts`, `src/lib/blog.functions.ts`: restricted rich-text schema, authoritative validation, admin mutations and anonymous published-only reads.
- `src/components/blog/BlogEditor.tsx`, `BlogContent.tsx`, `BlogCard.tsx`, `LatestPosts.tsx`: maintained rich-text editor with headings, paragraphs, bold/italic, lists and hyperlinks/anchor text; render validated structured content as React nodes, never arbitrary stored HTML. Reject scripts, unsafe URL schemes, event attributes, embeds and unapproved nodes/marks at the write and render boundaries.
- `src/routes/_app/admin_.posts.index.tsx`, `src/routes/_app/admin_.posts.$id.tsx`: protected WordPress-style post list/editor, draft/publish controls, taxonomy, image and SEO fields. Use un-nested filenames so the existing admin page does not swallow these pages.
- `src/routes/blog.index.tsx`, `src/routes/blog.$slug.tsx`: public listing and SSR article pages with published-only reads and genuine missing-article handling.
- `src/lib/sitemap.ts`, `src/routes/sitemap[.]xml.ts`: router-derived static URLs and fully paginated published article URLs; failures must not emit successful partial XML. Public reads use a session-free publishable client, never the privileged billing helper.

**Modify:**
- `package.json` and dependency lockfile: maintained editor packages; no native/Node-only server dependencies.
- `src/routes/index.tsx`: show latest **4** real published posts; no fake article content, no pricing/layout redesign. Add self-canonical metadata.
- `src/routes/_app/route.tsx`: admin-only CMS navigation and sitemap exclusion for the private subtree.
- All existing route files: explicit sitemap inclusion/exclusion only; private/auth/reset/API pages stay excluded. Preserve existing route paths and business behavior; never edit generated `src/routeTree.gen.ts`.
- `public/robots.txt`: preserve its crawler blocks and add `https://entryshippr-cloud.lovable.app/sitemap.xml` once the handler exists.
- `AGENTS.md`: record the new module/security boundaries; keep `roadmap.md` current.

Each new content route gets its own title, description, OG and Twitter metadata. Article canonicals use `https://entryshippr-cloud.lovable.app/blog/<slug>`. Published featured images are delivered through a published-post-aware endpoint or signed delivery; draft originals never get public object URLs. Any share image must match the visible article image, be publicly fetchable and sized appropriately. Private CMS previews are noindex/no-store. Sitemap public-origin URLs do not touch the existing `entrysetu.in` site.

## Verification and honest reporting

Add focused tests:
- `src/test/payment-proofs.test.ts`: allowed formats/5 MB cap, malformed files and references; pending submission cannot activate access.
- `src/test/admin-access.test.ts`: ordinary seller denied privileged endpoints, bounded pagination and validated actions.
- `src/test/blog.test.ts`: forbidden rich-text nodes/URLs, publication visibility, slug validation and latest-four ordering.
- `src/test/sitemap.test.ts`: private/draft exclusions, multiple data batches and later-batch errors.
- Rollback-only SQL tests: grants/RLS, cross-seller proof denial, unprivileged activation denial, immutable audit, approval concurrency/idempotency, subscription arithmetic and public draft exclusion. Run locally against a throwaway database where possible; never execute DEV SQL without approval.

Run existing shipment/rate/import/invoice/AWB tests for regressions. Check DEV Preview uploads, pending/rejected/approved review, seller detail and CMS publication/read-back only when real seller/admin access and schema are available. Stand-in or intercepted-data browser checks are labelled as such, not authenticated verification.

**Current blockers:** no available external-account session; deployed DEV schema/grants, buckets, secret configuration and Razorpay Test Mode are not verified. Real seller/admin saves and database isolation remain BLOCKED until access and reviewed setup are available. No tests have been run during this inspection. Nothing is published or deployed under this plan.
