import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { supabase, accessToken, PLANS, JOINING_FEE, inr } from "@/lib/supabase";
import { useProfile, accessState, errMsg } from "@/lib/hooks";
import { createOrder, verifyPayment } from "@/lib/billing.functions";
import { PageHead, appHead } from "@/components/PageHead";
import { Button } from "@/components/ui/button";
import { PaymentProofForm } from "@/components/PaymentProofForm";

export const Route = createFileRoute("/_app/billing")({
  head: appHead("Subscription", "Choose or renew your EntrySetu plan."),
  component: Billing,
});

type RzpResp = { razorpay_order_id: string; razorpay_payment_id: string; razorpay_signature: string };
declare global { interface Window { Razorpay?: new (o: Record<string, unknown>) => { open: () => void; on: (e: string, cb: (r: { error: { description: string } }) => void) => void } } }

function loadRzp() {
  return new Promise<void>((res, rej) => {
    if (window.Razorpay) return res();
    const s = document.createElement("script");
    s.src = "https://checkout.razorpay.com/v1/checkout.js";
    s.onload = () => res(); s.onerror = () => rej(new Error("Could not load Razorpay"));
    document.body.appendChild(s);
  });
}

function Billing() {
  const { data: me } = useProfile();
  const qc = useQueryClient();
  const [busy, setBusy] = useState<string | null>(null);
  const st = accessState(me?.profile);
  const { data: payments = [] } = useQuery({
    queryKey: ["payments"],
    queryFn: async () => (await supabase.from("payments").select("*").eq("status", "paid").order("created_at", { ascending: false })).data || [],
  });

  async function buy(plan: "standard" | "unlimited") {
    setBusy(plan);
    try {
      await loadRzp();
      const token = await accessToken();
      const o = await createOrder({ data: { token, plan } });
      const Razorpay = window.Razorpay;
      if (!Razorpay) throw new Error("Could not load Razorpay");
      const rzp = new Razorpay({
        key: o.keyId, order_id: o.orderId, amount: o.amount * 100, currency: "INR",
        name: "EntrySetu", description: `${PLANS[plan].name} (1 year)${o.withFee ? " + joining fee" : ""}`,
        prefill: { email: o.email, name: me?.profile?.business_name || "" },
        theme: { color: "#1f6f6b" },
        handler: async (r: RzpResp) => {
          try {
            await verifyPayment({ data: { token: await accessToken(), orderId: r.razorpay_order_id, paymentId: r.razorpay_payment_id, signature: r.razorpay_signature } });
            toast.success("Payment successful — plan activated");
            qc.invalidateQueries();
          } catch (e) { toast.error(errMsg(e)); }
        },
        modal: { ondismiss: () => setBusy(null) },
      });
      rzp.on("payment.failed", (r) => toast.error(r.error.description));
      rzp.open();
    } catch (e) { toast.error(errMsg(e)); }
    finally { setBusy(null); }
  }

  const feeDue = !me?.profile?.["joining_fee_paid"];
  return (
    <div>
      <PageHead title="Subscription" />
      <div className="mb-6 rounded-xl border bg-card p-4">Current: <b>{st.label}</b></div>
      <div className="grid gap-4 md:grid-cols-2">
        {(Object.keys(PLANS) as ("standard" | "unlimited")[]).map((k) => {
          const total = PLANS[k].price + (feeDue ? JOINING_FEE : 0);
          return (
            <div key={k} className="rounded-xl border bg-card p-6">
              <h3 className="text-lg font-semibold">{PLANS[k].name}</h3>
              <div className="mt-1 text-3xl font-bold">{inr(PLANS[k].price)}<span className="text-sm font-normal text-muted-foreground"> /year</span></div>
              <p className="mt-1 text-sm text-muted-foreground">{PLANS[k].limit}</p>
              {feeDue && <p className="mt-3 text-sm">+ one-time joining fee {inr(JOINING_FEE)} → <b>{inr(total)}</b> today</p>}
              <Button className="mt-4 w-full" disabled={!!busy || !me?.profile} onClick={() => buy(k)}>{busy === k ? "Opening…" : me?.profile?.plan === k && st.paid ? "Renew for 1 more year" : "Pay with Razorpay"}</Button>
            </div>
          );
        })}
      </div>
      <PaymentProofForm />
      <h2 className="mb-3 mt-8 text-lg font-semibold">Payment history</h2>
      <div className="overflow-x-auto rounded-xl border bg-card">
        <table className="w-full text-sm">
          <thead className="bg-muted text-left"><tr><th className="p-3">Date</th><th className="p-3">Plan</th><th className="p-3">Payment ID</th><th className="p-3 text-right">Amount</th></tr></thead>
          <tbody>
            {payments.map((p: { id: string; created_at: string; plan: string; razorpay_payment_id: string; amount_paise: number }) => (
              <tr key={p.id} className="border-t"><td className="p-3">{new Date(p.created_at).toLocaleDateString("en-IN")}</td><td className="p-3">{p.plan}</td><td className="p-3 font-mono">{p.razorpay_payment_id || "Manual payment"}</td><td className="p-3 text-right">{inr(p.amount_paise / 100)}</td></tr>
            ))}
            {!payments.length && <tr><td colSpan={4} className="p-6 text-center text-muted-foreground">No payments yet.</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}
