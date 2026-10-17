import { createServerFn } from "@tanstack/react-start";
import { PLANS, JOINING_FEE } from "./supabase";
import { providerError } from './provider-errors';

export const createOrder = createServerFn({ method: "POST" })
  .inputValidator((d: { token: string; plan: "standard" | "unlimited" }) => {
    if (typeof d?.token !== "string" || !["standard", "unlimited"].includes(d.plan)) throw new Error("Invalid request");
    return d;
  })
  .handler(async ({ data }) => {
    const { getUser, rest, rzpAuth, hmacHex, safeEqual, activatePayment } = await import("./billing.server");
    const user = await getUser(data.token);
    const [profile] = await rest(`profiles?id=eq.${user.id}&select=joining_fee_paid`);
    if (!profile) throw new Error("Profile not found");
    const withFee = !profile["joining_fee_paid"];
    const amountPaise = (PLANS[data.plan].price + (withFee ? JOINING_FEE : 0)) * 100;
    const r = await fetch("https://api.razorpay.com/v1/orders", {
      method: "POST",
      headers: { Authorization: rzpAuth(), "Content-Type": "application/json" },
      body: JSON.stringify({ amount: amountPaise, currency: "INR", receipt: `es_${Date.now()}`, notes: { user_id: user.id, plan: data.plan } }),
    }).catch(() => { throw providerError({}, 'Payment checkout'); });
    const order = await r.json().catch(() => { throw providerError({}, 'Payment checkout'); });
    if (!r.ok) throw providerError({ status: r.status }, 'Payment checkout');
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
    const { getUser, rest, rzpAuth, hmacHex, safeEqual, activatePayment } = await import("./billing.server");
    const user = await getUser(data.token);
    const expected = await hmacHex(process.env["RAZORPAY_KEY_SECRET"]!, `${data.orderId}|${data.paymentId}`);
    if (!safeEqual(expected, data.signature)) throw new Error("Payment signature mismatch");

    const [pay] = await rest(`payments?razorpay_order_id=eq.${encodeURIComponent(data.orderId)}&owner_id=eq.${user.id}&select=amount_paise,status`);
    if (!pay) throw new Error("Order not found");
    if (pay.status === "paid") return { ok: true };

    // Confirm with Razorpay itself: right order, right amount, money captured.
    const pr = await fetch(`https://api.razorpay.com/v1/payments/${encodeURIComponent(data.paymentId)}`, { headers: { Authorization: rzpAuth() } }).catch(() => { throw providerError({}, 'Payment verification'); });
    const payment = await pr.json().catch(() => { throw providerError({}, 'Payment verification'); });
    if (!pr.ok) throw new Error("Could not confirm payment with Razorpay");
    if (payment.order_id !== data.orderId || Number(payment.amount) !== Number(pay.amount_paise) || payment.currency !== "INR")
      throw new Error("Payment does not match order");
    if (payment.status === "authorized") {
      const cr = await fetch(`https://api.razorpay.com/v1/payments/${encodeURIComponent(data.paymentId)}/capture`, {
        method: "POST", headers: { Authorization: rzpAuth(), "Content-Type": "application/json" },
        body: JSON.stringify({ amount: payment.amount, currency: "INR" }),
      }).catch(() => { throw providerError({}, 'Payment capture'); });
      if (!cr.ok) throw new Error("Payment capture failed");
    } else if (payment.status !== "captured") {
      throw new Error('Payment not completed');
    }
    await activatePayment(data.orderId, data.paymentId, Number(payment.amount));
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
