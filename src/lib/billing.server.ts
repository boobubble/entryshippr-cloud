import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from "./supabase";
import { providerError } from './provider-errors';
export async function getUser(token: string): Promise<{ id: string; email: string }> {
  const r = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${token}` },
  }).catch(() => { throw providerError({ status: 401 }); });
  if (!r.ok) throw new Error("Not signed in");
  return r.json();
}

export async function rest(path: string, init: RequestInit = {}) {
  const key = process.env["EXT_SUPABASE_SECRET_KEY"];
  if (!key) throw providerError({}, 'Payment configuration');
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: { apikey: key, "Content-Type": "application/json", Prefer: "return=representation", ...(init.headers || {}) },
  }).catch(() => { throw providerError({}, 'Database request'); });
  const text = await r.text();
  if (!r.ok) {
    let code: string | undefined;
    try { const body = JSON.parse(text); if (typeof body.code === 'string') code = body.code; } catch { /* Do not forward response bodies. */ }
    throw providerError({ status: r.status, code }, 'Database request');
  }
  try { return text ? JSON.parse(text) : null; } catch { throw providerError({}, 'Database response'); }
}

export function rzpAuth() {
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

