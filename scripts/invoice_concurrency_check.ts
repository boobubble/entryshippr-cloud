/**
 * EntrySetu — REAL concurrency check for invoice numbering. DEVELOPMENT ONLY.
 * Not run automatically. Run only after the invoice editor migration is applied
 * to DEV (zfvnqcyqxxipjaugkmvf), signed in as a dedicated DEV test seller:
 *
 *   DEV_TEST_EMAIL=... DEV_TEST_PASSWORD=... bun scripts/invoice_concurrency_check.ts
 *
 * The SQL test file runs in one session, so it can only check ordering. This
 * script opens many parallel API calls at once and checks that:
 *   1. N simultaneous finalize_invoice calls get N unique, gap-free numbers;
 *   2. a create_invoice call racing those finalizations shares the same series
 *      without duplicates;
 *   3. two drafts finalizing the SAME manual number at once: exactly one wins.
 * It creates a "CONCURRENCY TEST <time>" client with small test shipments and
 * cancels every invoice it issued at the end (numbers stay used, as in real life).
 */
import { createClient } from "@supabase/supabase-js";

const URL = "https://zfvnqcyqxxipjaugkmvf.supabase.co"; // DEV only — never production
const KEY = "sb_publishable_YN1n6XqxiNb5_osRp3-Qcg_3riV7sYJ";
const N = 12;

const db = createClient(URL, KEY, { auth: { persistSession: false } });
const fail = (m: string) => { console.error("FAIL:", m); process.exit(1); };
const today = new Date().toISOString().slice(0, 10);
const from = new Date(Date.now() - 30 * 864e5).toISOString().slice(0, 10);

const { error: authErr } = await db.auth.signInWithPassword({
  email: process.env.DEV_TEST_EMAIL ?? fail("set DEV_TEST_EMAIL")!,
  password: process.env.DEV_TEST_PASSWORD ?? fail("set DEV_TEST_PASSWORD")!,
});
if (authErr) fail(authErr.message);

const tag = `CONCURRENCY TEST ${Date.now()}`;
const { data: client, error: cErr } = await db.from("clients").insert({ name: tag, state: "Maharashtra", is_gst: true }).select().single();
if (cErr) fail(cErr.message);
const legacy = await db.from("clients").insert({ name: `${tag} L`, state: "Maharashtra", is_gst: true }).select().single();
if (legacy.error) fail(legacy.error.message);

async function ship(clientId: string, awb: string) {
  const { data, error } = await db.from("shipments").insert({ client_id: clientId, awb, ship_date: today, destination: "MUMBAI", weight: 1 }).select("id").single();
  if (error) fail(error.message);
  const u = await db.from("shipments").update({ amount: 10 }).eq("id", data!.id);
  if (u.error) fail(u.error.message);
  return data!.id as string;
}

const ids = await Promise.all(Array.from({ length: N + 2 }, (_, i) => ship(client!.id, `CC${Date.now()}${i}`)));
await ship(legacy.data!.id, `CCL${Date.now()}`);
const drafts: string[] = [];
for (const id of ids) {
  const { data, error } = await db.rpc("create_invoice_draft", { p_client_id: client!.id, p_from: from, p_to: today, p_shipment_ids: [id] });
  if (error) fail(error.message);
  drafts.push(data as string);
}
const autoDrafts = drafts.slice(0, N);
const [m1, m2] = drafts.slice(N);
const manualNo = `RACE-${Date.now() % 100000}`;
for (const d of [m1, m2]) {
  const line = await db.from("invoice_lines").select("shipment_id, weight, rate, amount").eq("invoice_id", d);
  const r = await db.rpc("save_invoice_draft", { p_invoice_id: d, p_header: { numbering: "manual", requested_invoice_no: manualNo }, p_lines: line.data, p_charges: [] });
  if (r.error) fail(r.error.message);
}

// Fire everything at once.
const results = await Promise.all([
  ...autoDrafts.map((d) => db.rpc("finalize_invoice", { p_invoice_id: d })),
  db.rpc("create_invoice", { p_client_id: legacy.data!.id, p_from: from, p_to: today }),
  db.rpc("finalize_invoice", { p_invoice_id: m1 }),
  db.rpc("finalize_invoice", { p_invoice_id: m2 }),
]);
const autoRes = results.slice(0, N + 1);
const [r1, r2] = results.slice(N + 1);
autoRes.forEach((r, i) => r.error && fail(`auto #${i}: ${r.error.message}`));
if (Boolean(r1.error) === Boolean(r2.error)) fail("manual race: expected exactly one winner");
console.log("PASS manual race, loser said:", (r1.error ?? r2.error)!.message);

const issuedIds = [...autoRes.map((r) => r.data as string), (r1.data ?? r2.data) as string];
const { data: inv } = await db.from("invoices").select("id, seq, invoice_no, kind, fy").in("id", issuedIds);
const seqs = inv!.filter((i) => i.seq !== null).map((i) => i.seq as number).sort((a, b) => a - b);
if (new Set(inv!.map((i) => i.invoice_no)).size !== inv!.length) fail("duplicate invoice numbers");
if (seqs.length !== N + 1 || new Set(seqs).size !== seqs.length) fail(`duplicate/missing seqs ${seqs}`);
if (seqs[seqs.length - 1] - seqs[0] !== seqs.length - 1) fail(`gap in seqs ${seqs}`);
console.log(`PASS ${N + 1} concurrent auto numbers unique and gap-free:`, seqs.join(","));

for (const id of issuedIds) await db.rpc("cancel_invoice", { p_invoice_id: id, p_reason: "concurrency test cleanup" });
console.log("ALL CONCURRENCY CHECKS PASSED (test invoices cancelled; numbers stay used)");
