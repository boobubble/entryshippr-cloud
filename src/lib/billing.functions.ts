import { createServerFn } from "@tanstack/react-start";
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, PLANS, JOINING_FEE } from "./supabase";

async function getUser(token: string): Promise<{ id: string; email: string }> {
  const r = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${token}` },
  });
  if (!r.ok) throw new Error("Not signed in");
  return r.json();
}

export async function rest(path: string, init: RequestInit = {}) {
  const key = process.env["EXT_SUPABASE_SECRET_KEY"]!;
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: { apikey: key, "Content-Type": "application/json", Prefer: "return=representation", ...(init.headers || {}) },
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`Database error: ${text}`);
  return text ? JSON.parse(text) : null;
}

function rzpAuth() {
  return "Basic " + btoa(`${process.env["RAZORPAY_KEY_ID"]}:${process.env["RAZORPAY_KEY_SECRET"]}`);
}

export async function hmacHex(secret: string, msg: string) {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function safeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** Idempotent; returns true only the first time an order is activated. */
export async function activatePayment(orderId: string, paymentId: string, amountPaise: number) {
  return rest("rpc/activate_payment", {
    method: "POST",
    body: JSON.stringify({ p_order_id: orderId, p_payment_id: paymentId, p_amount_paise: amountPaise }),
  }) as Promise<boolean>;
}

export const createOrder = createServerFn({ method: "POST" })
  .inputValidator((d: { token: string; plan: "standard" | "unlimited" }) => {
    if (typeof d?.token !== "string" || !["standard", "unlimited"].includes(d.plan)) throw new Error("Invalid request");
    return d;
  })
  .handler(async ({ data }) => {
    const user = await getUser(data.token);
    const [profile] = await rest(`profiles?id=eq.${user.id}&select=joining_fee_paid`);
    if (!profile) throw new Error("Profile not found");
    const withFee = !profile["joining_fee_paid"];
    const amountPaise = (PLANS[data.plan].price + (withFee ? JOINING_FEE : 0)) * 100;
    const r = await fetch("https://api.razorpay.com/v1/orders", {
      method: "POST",
      headers: { Authorization: rzpAuth(), "Content-Type": "application/json" },
      body: JSON.stringify({ amount: amountPaise, currency: "INR", receipt: `es_${Date.now()}`, notes: { user_id: user.id, plan: data.plan } }),
    });
    const order = await r.json();
    if (!r.ok) throw new Error(order?.error?.description || "Could not start payment");
    await rest("payments", {
      method: "POST",
      body: JSON.stringify({ owner_id: user.id, plan: data.plan, amount_paise: amountPaise, includes_joining_fee: withFee, razorpay_order_id: order.id }),
    });
    return { orderId: order.id as string, amount: amountPaise / 100, keyId: process.env["RAZORPAY_KEY_ID"]!, email: user.email, withFee };
  });

export const verifyPayment = createServerFn({ method: "POST" })
  .inputValidator((d: { token: string; orderId: string; paymentId: string; signature: string }) => {
    for (const k of ["token", "orderId", "paymentId", "signature"] as const)
      if (typeof d?.[k] !== "string" || d[k].length > 4000) throw new Error("Invalid request");
    return d;
  })
  .handler(async ({ data }) => {
    const user = await getUser(data.token);
    const expected = await hmacHex(process.env["RAZORPAY_KEY_SECRET"]!, `${data.orderId}|${data.paymentId}`);
    if (!safeEqual(expected, data.signature)) throw new Error("Payment signature mismatch");

    const [pay] = await rest(`payments?razorpay_order_id=eq.${encodeURIComponent(data.orderId)}&owner_id=eq.${user.id}&select=amount_paise,status`);
    if (!pay) throw new Error("Order not found");
    if (pay.status === "paid") return { ok: true };

    // Confirm with Razorpay itself: right order, right amount, money captured.
    const pr = await fetch(`https://api.razorpay.com/v1/payments/${encodeURIComponent(data.paymentId)}`, { headers: { Authorization: rzpAuth() } });
    const payment = await pr.json();
    if (!pr.ok) throw new Error("Could not confirm payment with Razorpay");
    if (payment.order_id !== data.orderId || Number(payment.amount) !== Number(pay.amount_paise) || payment.currency !== "INR")
      throw new Error("Payment does not match order");
    if (payment.status === "authorized") {
      const cr = await fetch(`https://api.razorpay.com/v1/payments/${encodeURIComponent(data.paymentId)}/capture`, {
        method: "POST", headers: { Authorization: rzpAuth(), "Content-Type": "application/json" },
        body: JSON.stringify({ amount: payment.amount, currency: "INR" }),
      });
      if (!cr.ok) throw new Error("Payment capture failed");
    } else if (payment.status !== "captured") {
      throw new Error(`Payment not completed (${payment.status})`);
    }
    await activatePayment(data.orderId, data.paymentId, Number(payment.amount));
    return { ok: true };
  });

export const adminUpdateUser = createServerFn({ method: "POST" })
  .inputValidator((d: { token: string; userId: string; action: "extend_trial" | "grant_plan" | "revoke"; plan?: "standard" | "unlimited" | undefined }) => {
    if (!/^[0-9a-f-]{36}$/i.test(d?.userId) || !["extend_trial", "grant_plan", "revoke"].includes(d.action)) throw new Error("Invalid request");
    if (d.plan && !["standard", "unlimited"].includes(d.plan)) throw new Error("Invalid plan");
    return d;
  })
  .handler(async ({ data }) => {
    const me = await getUser(data.token);
    const roles = await rest(`user_roles?user_id=eq.${me.id}&role=eq.admin&select=id`);
    if (!roles.length) throw new Error("Admins only");
    await rest("rpc/admin_set_access", {
      method: "POST",
      body: JSON.stringify({ p_user_id: data.userId, p_action: data.action, p_plan: data.plan ?? null }),
    });
    return { ok: true };
  });
