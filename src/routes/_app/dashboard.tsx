import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { supabase, inr } from "@/lib/supabase";
import { useProfile, accessState } from "@/lib/hooks";
import { PageHead, appHead } from "@/components/PageHead";
import { Button } from "@/components/ui/button";

export const Route = createFileRoute("/_app/dashboard")({
  head: appHead("Dashboard", "Overview of shipments, billing and your subscription."),
  component: Dashboard,
});

function Dashboard() {
  const { data: me } = useProfile();
  const st = accessState(me?.profile);
  const { data } = useQuery({
    queryKey: ["dashboard"],
    queryFn: async () => {
      const monthStart = new Date(); monthStart.setDate(1);
      const ms = monthStart.toISOString().slice(0, 10);
      const [clients, shipMonth, unbilled, invMonth, recent] = await Promise.all([
        supabase.from("clients").select("id", { count: "exact", head: true }).eq("active", true),
        supabase.from("shipments").select("amount").gte("ship_date", ms),
        supabase.from("shipments").select("amount").is("invoice_id", null),
        supabase.from("invoices").select("total").eq("status", "issued").gte("invoice_date", ms),
        supabase.from("shipments").select("id, awb, ship_date, destination, amount, clients(name)").order("created_at", { ascending: false }).limit(8),
      ]);
      const sum = (r: { data: { amount?: number; total?: number }[] | null }) => (r.data || []).reduce((a, x) => a + Number(x.amount ?? x.total ?? 0), 0);
      return {
        activeClients: clients.count || 0,
        shipCount: shipMonth.data?.length || 0, shipValue: sum(shipMonth),
        unbilledCount: unbilled.data?.length || 0, unbilledValue: sum(unbilled),
        invoiced: sum(invMonth),
        recent: (recent.data || []) as unknown as { id: string; awb: string; ship_date: string; destination: string; amount: number; clients: { name: string } | null }[],
      };
    },
  });
  const cards = [
    { l: "Active clients", v: String(data?.activeClients ?? "–") },
    { l: "Shipments this month", v: `${data?.shipCount ?? "–"} · ${inr(data?.shipValue || 0)}` },
    { l: "Unbilled shipments", v: `${data?.unbilledCount ?? "–"} · ${inr(data?.unbilledValue || 0)}` },
    { l: "Invoiced this month", v: inr(data?.invoiced || 0) },
  ];
  return (
    <div>
      <PageHead title={`Hello${me?.profile?.business_name ? ", " + me.profile.business_name : ""}`}>
        <Button asChild><Link to="/import">Import Excel</Link></Button>
        <Button variant="outline" asChild><Link to="/invoices">Create invoice</Link></Button>
      </PageHead>
      <div className="mb-6 rounded-lg border bg-card p-4 text-sm">Plan: <b>{st.label}</b> {!st.paid && <Link to="/billing" className="ml-2 text-primary underline">Upgrade</Link>}</div>
      <div className="grid gap-4 md:grid-cols-4">
        {cards.map((c) => (
          <div key={c.l} className="rounded-xl border bg-card p-5">
            <div className="text-xs uppercase tracking-wide text-muted-foreground">{c.l}</div>
            <div className="mt-2 text-xl font-bold">{c.v}</div>
          </div>
        ))}
      </div>
      <h2 className="mb-3 mt-8 text-lg font-semibold">Recent shipments</h2>
      <div className="overflow-x-auto rounded-xl border bg-card">
        <table className="w-full text-sm">
          <thead className="bg-muted text-left"><tr><th className="p-3">AWB</th><th className="p-3">Date</th><th className="p-3">Client</th><th className="p-3">Destination</th><th className="p-3 text-right">Amount</th></tr></thead>
          <tbody>
            {data?.recent.map((r) => (
              <tr key={r.id} className="border-t"><td className="p-3 font-mono">{r.awb}</td><td className="p-3">{r.ship_date}</td><td className="p-3">{r.clients?.name}</td><td className="p-3">{r.destination}</td><td className="p-3 text-right">{inr(r.amount)}</td></tr>
            ))}
            {data && !data.recent.length && <tr><td colSpan={5} className="p-6 text-center text-muted-foreground">No shipments yet. Add clients and rate cards, then import your Excel sheet.</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}
