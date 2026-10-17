# EntrySetu: payment proofs, Super Admin and Blog CMS

## Review boundary

Source/SQL inspection only; live DEV schema and account access are unverified. Only roadmap/requirements memory changed; no app code, SQL, records, environment or production changes, and no publication.

Approve the plan to start small code steps and generate DEV SQL/tests for review. **This does not authorize SQL execution or storage provisioning.** External Supabase only; Cloud off; production untouched.

## Existing files/schema to reuse

- `src/routes/_app/billing.tsx`: Razorpay checkout and paid-only history. No current screenshot submission form.
- `src/lib/supabase.ts`: external DEV connection; retain Standard ₹1,200/year (50 active clients), Standard Unlimited ₹1,800/year, ₹3,000 first-purchase joining fee and five-day trial. No Basic/Pro monthly pricing.
- `src/routes/auth.tsx`, `src/lib/hooks.ts`, `src/routes/_app/route.tsx`: existing accounts, profile/access state, signed-in gate and admin navigation.
- `src/routes/_app/admin.tsx`: seller list, paid history and grant/revoke/+5-day actions; lacks pagination, filters, proof review and audit.
- `src/lib/billing.functions.ts`, `src/routes/api/public/razorpay-webhook.ts`: authenticated billing/admin operations and verified Razorpay activation. Preserve Test Mode.
- `supabase/entrysetu_schema.sql`, `supabase/migration_2026_10_15_permission_hardening.sql`: reuse `profiles`, `payments`, `user_roles`, `is_admin()`, `has_access()`, `activate_payment()`, `admin_set_access()` and existing grants/RLS. Never rerun the base schema on an existing database.
- `src/routes/index.tsx`, `src/routes/__root.tsx`, `src/components/PageHead.tsx`, `public/robots.txt`: homepage, shell and metadata. No blog editor/schema/routes/storage integration or sitemap exists.
- `src/test/*`, `supabase/migration_2026_10_15_security_tests.sql`: existing regression/security patterns.

Current subscription state lives on `profiles`; purchases live in `payments`. Reuse these rather than adding a duplicate subscription engine.

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

Add `blog_posts`, `blog_categories`, `blog_tags`, `blog_post_tags`: title, unique slug, excerpt, validated rich-text JSON, draft/published status, category/tags, image/alt text, SEO fields, author and timestamps. Enforce field bounds, FKs and publication consistency. Admin writes only; public reads only published content. Draft associations/images stay private. No sample posts.

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
- `src/routes/_app/admin_.sellers.$id.tsx`: protected seller detail with plan/dates and paginated payment/audit history. Un-nested filename preserves the existing `/admin` page.

Proof access is payment-owner/admin checked, short-lived and private/no-store. Validate image signatures, MIME and size server-side; never trust seller/amount/reviewer fields from the browser.

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

New routes get individual title/description/OG/Twitter metadata. Article canonicals use `https://entryshippr-cloud.lovable.app/blog/<slug>`. Add `src/routes/api/public/blog-images.$id.ts` for published-post-aware delivery of private featured images, including share-sized renditions prepared during upload. Draft images never become public. Share images match displayed images; CMS previews are noindex/no-store. Existing `entrysetu.in` remains untouched.

## Verification and blockers

Add `src/test/payment-proofs.test.ts`, `src/test/admin-access.test.ts`, `src/test/blog.test.ts`, `src/test/sitemap.test.ts` for upload limits/signatures, authorization, unsafe content/URLs, publication visibility, latest-four ordering, pagination and sitemap batch failures.

Rollback-only SQL tests cover grants/RLS, cross-seller proof denial, unprivileged activation denial, immutable audit, approval idempotency/concurrency, subscription arithmetic and draft exclusion. Use a throwaway local database where possible; no DEV SQL without approval. Run existing shipment/rate/import/invoice/AWB regression tests.

Real Preview verification must cover seller upload/read-back, admin rejection/approval, access changes and CMS publish/public read-back. Intercepted/stand-in checks are not real-account verification.

**BLOCKED:** external-account session unavailable; deployed schema/grants, buckets, secrets and Razorpay Test Mode unverified. No tests ran during inspection. Implementation awaits plan review; SQL/storage setup needs separate approval. Nothing published/deployed.
