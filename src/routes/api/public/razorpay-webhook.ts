import { createFileRoute } from "@tanstack/react-router";


// Razorpay -> Settings -> Webhooks. Events: payment.captured, order.paid.
// Backup path so a plan still activates if the buyer closes the browser before verification.
export const Route = createFileRoute("/api/public/razorpay-webhook")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const { hmacHex, safeEqual, rest, activatePayment } = await import("@/lib/billing.server");
        const secret = process.env["RAZORPAY_WEBHOOK_SECRET"];
        if (!secret) return new Response("Webhook not configured", { status: 503 });
        const raw = await request.text();
        if (raw.length > 100_000) return new Response("Too large", { status: 413 });
        const sig = request.headers.get("x-razorpay-signature") || "";
        if (!safeEqual(await hmacHex(secret, raw), sig)) return new Response("Bad signature", { status: 401 });

        let body: { event?: string; payload?: { payment?: { entity?: { id: string; order_id: string; amount: number; currency: string; status: string } } } };
        try { body = JSON.parse(raw); } catch { return new Response("Bad JSON", { status: 400 }); }
        const eventId = request.headers.get("x-razorpay-event-id") || "";
        const type = body.event || "";
        if (!eventId) return new Response("Missing event id", { status: 400 });

        const p = body.payload?.payment?.entity;
        if ((type === "payment.captured" || type === "order.paid") && p?.order_id && p.status === "captured" && p.currency === "INR") {
          try {
            await activatePayment(p.order_id, p.id, Number(p.amount));
          } catch (e) {
            console.error("Webhook activation failed", e);
            return new Response("Activation failed", { status: 500 });
          }
        }
        // Recorded only after successful processing so Razorpay retries still work; activation itself is idempotent.
        await rest("rpc/record_webhook_event", { method: "POST", body: JSON.stringify({ p_event_id: eventId, p_event_type: type }) });
        return new Response("ok", { status: 200 });
      },
    },
  },
});
