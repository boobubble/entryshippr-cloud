import { createServerFn } from "@tanstack/react-start";
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, PLANS, JOINING_FEE } from "./supabase";

async function getUser(token: string): Promise<{ id: string; email: string }> {
  const r = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${token}` },
  });
  if (!r.ok) throw new Error("Not signed in");
  return r.json();
}

async function rest(path: string, init: RequestInit = {}) {
  const key = process.env["EXT_SUPABASE_SECRET_KEY"]!;
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: { apikey: key, "Content-Type": "application/json", Prefer: "return=representation", ...(init.headers || {}) },
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`Database error: ${text}`);
  return text ? JSON.parse(text) : null;
}

async function isAdmin(uid: string) {
  const rows = await rest(`user_roles?user_id=eq.${uid}&role=eq.admin&select=id`);
  return rows.length > 0;
}

export const createOrder = createServerFn({ method: "POST" })
  .inputValidator((d: { token: string; plan: "standard" | "unlimited" }) => {
    if (!["standard", "unlimited"].includes(d.plan)) throw new Error("Invalid plan");
    return d;
  })
  .handler(async ({ data }) => {
    const user = await getUser(data.token);
    const [profile] = await rest(`profiles?id=eq.${user.id}&select=joining_fee_paid`);
    const withFee = !profile?.["joining_fee_paid"];
    const amount = PLANS[data.plan].price + (withFee ? JOINING_FEE : 0);
    const keyId = process.env["RAZORPAY_KEY_ID"]!;
    const auth = btoa(`${keyId}:${process.env["RAZORPAY_KEY_SECRET"]}`);
    const r = await fetch("https://api.razorpay.com/v1/orders", {
      method: "POST",
      headers: { Authorization: `Basic ${auth}`, "Content-Type": "application/json" },
      body: JSON.stringify({ amount: amount * 100, currency: "INR", receipt: `es_${Date.now()}`, notes: { user_id: user.id, plan: data.plan } }),
    });
    const order = await r.json();
    if (!r.ok) throw new Error(order?.error?.description || "Could not start payment");
    await rest("payments", {
      method: "POST",
      body: JSON.stringify({ owner_id: user.id, plan: data.plan, amount, includes_joining_fee: withFee, razorpay_order_id: order.id }),
    });
    return { orderId: order.id as string, amount, keyId, email: user.email, withFee };
  });

async function hmacHex(secret: string, msg: string) {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function activate(uid: string, plan: string, includesFee: boolean) {
  const [p] = await rest(`profiles?id=eq.${uid}&select=plan_expires_at`);
  const base = p?.plan_expires_at && new Date(p.plan_expires_at) > new Date() ? new Date(p.plan_expires_at) : new Date();
  base.setFullYear(base.getFullYear() + 1);
  const patch: Record<string, unknown> = { plan, plan_expires_at: base.toISOString() };
  if (includesFee) patch.joining_fee_paid = true;
  await rest(`profiles?id=eq.${uid}`, { method: "PATCH", body: JSON.stringify(patch) });
}

export const verifyPayment = createServerFn({ method: "POST" })
  .inputValidator((d: { token: string; orderId: string; paymentId: string; signature: string }) => d)
  .handler(async ({ data }) => {
    const user = await getUser(data.token);
    const expected = await hmacHex(process.env["RAZORPAY_KEY_SECRET"]!, `${data.orderId}|${data.paymentId}`);
    if (expected !== data.signature) throw new Error("Payment signature mismatch");
    const [pay] = await rest(`payments?razorpay_order_id=eq.${encodeURIComponent(data.orderId)}&owner_id=eq.${user.id}&select=*`);
    if (!pay) throw new Error("Order not found");
    if (pay.status === "paid") return { ok: true };
    await rest(`payments?id=eq.${pay.id}`, { method: "PATCH", body: JSON.stringify({ status: "paid", razorpay_payment_id: data.paymentId }) });
    await activate(user.id, pay.plan, pay.includes_joining_fee);
    return { ok: true };
  });

export const adminUpdateUser = createServerFn({ method: "POST" })
  .inputValidator((d: { token: string; userId: string; action: "extend_trial" | "grant_plan" | "revoke"; plan?: "standard" | "unlimited" }) => d)
  .handler(async ({ data }) => {
    const me = await getUser(data.token);
    if (!(await isAdmin(me.id))) throw new Error("Admins only");
    const uid = encodeURIComponent(data.userId);
    if (data.action === "extend_trial") {
      const d = new Date(); d.setDate(d.getDate() + 5);
      await rest(`profiles?id=eq.${uid}`, { method: "PATCH", body: JSON.stringify({ trial_ends_at: d.toISOString() }) });
    } else if (data.action === "grant_plan") {
      await activate(data.userId, data.plan || "standard", false);
    } else {
      await rest(`profiles?id=eq.${uid}`, { method: "PATCH", body: JSON.stringify({ plan: null, plan_expires_at: null, trial_ends_at: new Date().toISOString() }) });
    }
    return { ok: true };
  });
