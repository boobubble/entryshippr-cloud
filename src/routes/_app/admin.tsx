import { createFileRoute } from "@tanstack/react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { supabase, accessToken, inr } from "@/lib/supabase";
import { useProfile, accessState, errMsg, type Profile } from "@/lib/hooks";
import { adminUpdateUser } from "@/lib/billing.functions";
import { PageHead, appHead } from "@/components/PageHead";
import { Button } from "@/components/ui/button";

export const Route = createFileRoute("/_app/admin")({
  head: appHead("Super admin", "Manage EntrySetu subscribers and payments."),
  component: Admin,
});

function Admin() {
  const { data: me } = useProfile();
  const qc = useQueryClient();
  const { data } = useQuery({
    queryKey: ["admin"],
    enabled: !!me?.isAdmin,
    queryFn: async () => {
      const [p, pay] = await Promise.all([
        supabase.from("profiles").select("*").order("created_at", { ascending: false }),
        supabase.from("payments").select("*").eq("status", "paid").order("created_at", { ascending: false }),
      ]);
      return { profiles: (p.data || []) as (Profile & { created_at: string })[], payments: (pay.data || []) as { id: string; owner_id: string; amount_paise: number; plan: string; created_at: string; razorpay_payment_id: string }[] };
    },
  });
  if (me && !me.isAdmin) return <p>Admins only.</p>;

  async function act(userId: string, action: "extend_trial" | "grant_plan" | "revoke", plan?: "standard" | "unlimited") {
    try {
      await adminUpdateUser({ data: { token: await accessToken(), userId, action, plan } });
      toast.success("Updated");
      qc.invalidateQueries({ queryKey: ["admin"] });
    } catch (e) { toast.error(errMsg(e)); }
  }
  const revenue = (data?.payments || []).reduce((a, p) => a + Number(p.amount_paise) / 100, 0);
  const paid = (data?.profiles || []).filter((p) => accessState(p).paid).length;
  const email = (id: string) => data?.profiles.find((p) => p.id === id)?.email;

  return (
    <div>
      <PageHead title="Super admin" />
      <div className="mb-6 grid gap-4 md:grid-cols-3">
        {[["Businesses", data?.profiles.length ?? "–"], ["Paid subscribers", paid], ["Total revenue", inr(revenue)]].map(([l, v]) => (
          <div key={String(l)} className="rounded-xl border bg-card p-5"><div className="text-xs uppercase text-muted-foreground">{l}</div><div className="mt-2 text-2xl font-bold">{v}</div></div>
        ))}
      </div>
      <div className="overflow-x-auto rounded-xl border bg-card">
        <table className="w-full text-sm">
          <thead className="bg-muted text-left"><tr><th className="p-3">Business</th><th className="p-3">Email</th><th className="p-3">Joined</th><th className="p-3">Status</th><th className="p-3" /></tr></thead>
          <tbody>{data?.profiles.map((p) => (
            <tr key={p.id} className="border-t"><td className="p-3">{p.business_name}</td><td className="p-3">{p.email}</td><td className="p-3">{new Date(p.created_at).toLocaleDateString("en-IN")}</td><td className="p-3">{accessState(p).label}</td>
              <td className="space-x-1 whitespace-nowrap p-3 text-right">
                <Button size="sm" variant="outline" onClick={() => act(p.id, "extend_trial")}>+5d trial</Button>
                <Button size="sm" variant="outline" onClick={() => act(p.id, "grant_plan", "standard")}>Grant Std</Button>
                <Button size="sm" variant="outline" onClick={() => act(p.id, "grant_plan", "unlimited")}>Grant Unl.</Button>
                <Button size="sm" variant="ghost" onClick={() => confirm("Revoke access?") && act(p.id, "revoke")}>Revoke</Button>
              </td></tr>
          ))}</tbody>
        </table>
      </div>
      <h2 className="mb-3 mt-8 text-lg font-semibold">Payments</h2>
      <div className="overflow-x-auto rounded-xl border bg-card">
        <table className="w-full text-sm">
          <thead className="bg-muted text-left"><tr><th className="p-3">Date</th><th className="p-3">User</th><th className="p-3">Plan</th><th className="p-3">Payment ID</th><th className="p-3 text-right">Amount</th></tr></thead>
          <tbody>{data?.payments.map((p) => (
            <tr key={p.id} className="border-t"><td className="p-3">{new Date(p.created_at).toLocaleDateString("en-IN")}</td><td className="p-3">{email(p.owner_id)}</td><td className="p-3">{p.plan}</td><td className="p-3 font-mono">{p.razorpay_payment_id}</td><td className="p-3 text-right">{inr(p.amount_paise / 100)}</td></tr>
          ))}</tbody>
        </table>
      </div>
    </div>
  );
}
