import { createServerFn } from "@tanstack/react-start";
import { PLANS, JOINING_FEE } from "./supabase";
import { providerError, paymentStage } from './provider-errors';

/** Razorpay is called with server-held keys: 401/403 means gateway credentials, never the user's session. */
async function razorpay(url: string, init: RequestInit, operation: string) {
  const r = await fetch(url, init).catch(() => { throw providerError({}, operation); });
  if (!r.ok) throw providerError({ status: r.status }, operation, 'server');
  return r.json().catch(() => { throw providerError({}, operation); });
}

export const createOrder = createServerFn({ method: "POST" })
  .inputValidator((d: { token: string; plan: "standard" | "unlimited" }) => {
    if (typeof d?.token !== "string" || !["standard", "unlimited"].includes(d.plan)) throw new Error("Invalid request");
    return d;
  })
  .handler(async ({ data }) => {
    const { getUser, rest, rzpAuth } = await import("./billing.server");
    const user = await paymentStage('checkout', 'auth-verify', () => getUser(data.token));
    const [profile] = await paymentStage('checkout', 'profile-read', () => rest(`profiles?id=eq.${user.id}&select=joining_fee_paid`));
    if (!profile) throw new Error("Profile not found");
    const withFee = !profile["joining_fee_paid"];
    const amountPaise = (PLANS[data.plan].price + (withFee ? JOINING_FEE : 0)) * 100;
    const order = await paymentStage('checkout', 'gateway-order', () => razorpay("https://api.razorpay.com/v1/orders", {
      method: "POST",
      headers: { Authorization: rzpAuth(), "Content-Type": "application/json" },
      body: JSON.stringify({ amount: amountPaise, currency: "INR", receipt: `es_${Date.now()}`, notes: { user_id: user.id, plan: data.plan } }),
    }, 'Payment checkout'));
    await paymentStage('checkout', 'order-record', () => rest("payments", {
      method: "POST",
      body: JSON.stringify({ owner_id: user.id, plan: data.plan, amount_paise: amountPaise, includes_joining_fee: withFee, razorpay_order_id: order.id }),
    }));
    return { orderId: order.id as string, amount: amountPaise / 100, keyId: process.env["RAZORPAY_KEY_ID"]!, email: user.email, withFee };
  });

export const verifyPayment = createServerFn({ method: "POST" })
  .inputValidator((d: { token: string; orderId: string; paymentId: string; signature: string }) => {
    for (const k of ["token", "orderId", "paymentId", "signature"] as const)
      if (typeof d?.[k] !== "string" || d[k].length > 4000) throw new Error("Invalid request");
    return d;
  })
  .handler(async ({ data }) => {
    const { getUser, rest, rzpAuth, hmacHex, safeEqual, activatePayment } = await import("./billing.server");
    const user = await paymentStage('payment-verification', 'auth-verify', () => getUser(data.token));
    const expected = await hmacHex(process.env["RAZORPAY_KEY_SECRET"]!, `${data.orderId}|${data.paymentId}`);
    if (!safeEqual(expected, data.signature)) throw new Error("Payment signature mismatch");

    const [pay] = await paymentStage('payment-verification', 'order-read', () => rest(`payments?razorpay_order_id=eq.${encodeURIComponent(data.orderId)}&owner_id=eq.${user.id}&select=amount_paise,status`));
    if (!pay) throw new Error("Order not found");
    if (pay.status === "paid") return { ok: true };

    // Confirm with Razorpay itself: right order, right amount, money captured.
    const payment = await paymentStage('payment-verification', 'gateway-payment', () => razorpay(`https://api.razorpay.com/v1/payments/${encodeURIComponent(data.paymentId)}`, { headers: { Authorization: rzpAuth() } }, 'Payment verification'));
    if (payment.order_id !== data.orderId || Number(payment.amount) !== Number(pay.amount_paise) || payment.currency !== "INR")
      throw new Error("Payment does not match order");
    if (payment.status === "authorized") {
      await paymentStage('payment-verification', 'gateway-capture', () => razorpay(`https://api.razorpay.com/v1/payments/${encodeURIComponent(data.paymentId)}/capture`, {
        method: "POST", headers: { Authorization: rzpAuth(), "Content-Type": "application/json" },
        body: JSON.stringify({ amount: payment.amount, currency: "INR" }),
      }, 'Payment capture'));
    } else if (payment.status !== "captured") {
      throw new Error('Payment not completed');
    }
    await paymentStage('payment-verification', 'activation', () => activatePayment(data.orderId, data.paymentId, Number(payment.amount)));
    return { ok: true };
  });

/** Compatibility endpoint: interactive admin writes now require the audited path. */
export const adminUpdateUser = createServerFn({ method: "POST" })
  .inputValidator((d: { token: string; userId: string; action: "extend_trial" | "grant_plan" | "revoke"; plan?: "standard" | "unlimited"; reason?: string }) => d)
  .handler(async ({ data }) => {
    const { authenticatedClient, dbError } = await import("./external-auth.server");
    const { client } = await authenticatedClient(data.token, true);
    if (!data.reason || data.reason.trim().length < 3 || data.reason.length > 1000) throw new Error("Use the admin confirmation dialog and enter a reason.");
    const r = await client.rpc("admin_set_access_audited", { p_user_id: data.userId, p_action: data.action, p_plan: data.plan ?? null, p_reason: data.reason.trim() });
    dbError(r.error); return { ok: true };
  });
