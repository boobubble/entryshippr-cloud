import { up } from "@/lib/text";
import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { supabase, inr } from "@/lib/supabase";
import { useProfile } from "@/lib/hooks";
import { appHead } from "@/components/PageHead";
import { Button } from "@/components/ui/button";

export const Route = createFileRoute("/_app/invoices/$id")({
  head: appHead("Invoice", "Printable courier invoice."),
  component: InvoiceView,
});

function InvoiceView() {
  const { id } = Route.useParams();
  const { data: me } = useProfile();
  const { data } = useQuery({
    queryKey: ["invoice", id],
    queryFn: async () => {
      const { data: inv, error } = await supabase.from("invoices").select("*, clients(*)").eq("id", id).single();
      if (error) throw error;
      const { data: ships } = await supabase.from("shipments").select("*").eq("invoice_id", id).order("ship_date");
      return { inv, ships: ships || [] };
    },
  });
  if (!data) return <p className="text-muted-foreground">Loading…</p>;
  const { inv, ships } = data;
  const p = me?.profile;
  const c = inv.clients;
  return (
    <div>
      <div className="no-print mb-4 flex gap-2"><Button variant="outline" asChild><Link to="/invoices">Back</Link></Button><Button onClick={() => window.print()}>Print / Save PDF</Button></div>
      <div className="rounded-xl border bg-card p-8 text-sm">
        <div className="flex justify-between gap-6">
          <div><h2 className="text-xl font-bold">{p?.business_name}</h2><p className="whitespace-pre-line">{p?.address}</p><p>{up(p?.state)}</p>{p?.gstin && <p>GSTIN: {p.gstin}</p>}{p?.phone && <p>Ph: {p.phone}</p>}</div>
          <div className="text-right"><h3 className="text-lg font-bold">{inv.kind === "gst" ? "TAX INVOICE" : "INVOICE"}</h3><p>No: {inv.invoice_no}</p>{inv.status === "cancelled" && <p className="font-bold text-destructive">CANCELLED</p>}<p>Date: {inv.invoice_date}</p><p>Period: {inv.period_from} to {inv.period_to}</p></div>
        </div>
        <div className="mt-6 border-t pt-4"><b>Bill to:</b> {up(c?.name)}<br />{c?.address}{c?.state && <>, {up(c.state)}</>}{c?.gstin && <><br />GSTIN: {c.gstin}</>}</div>
        <table className="mt-6 w-full">
          <thead className="border-y text-left"><tr><th className="py-2">#</th><th>AWB</th><th>Date</th><th>Destination</th><th>Service</th><th>Weight</th><th>Rate applied</th><th className="text-right">Amount</th></tr></thead>
          <tbody>{ships.map((s, i) => <tr key={s.id} className="border-b"><td className="py-1">{i + 1}</td><td className="font-mono">{s.awb}</td><td>{s.ship_date}</td><td>{up(s.destination)}</td><td>{s.service}</td><td>{s.billing_weight != null && s.weight_unit ? `${+s.billing_weight} ${s.weight_unit}` : `${s.weight} kg`}{s.shipment_type ? ` (${s.shipment_type})` : ""}</td><td className="text-xs">{[s.rate_zone, s.rate_slab].filter(Boolean).join(" · ")}{s.rate_applied != null ? ` @ ${inr(s.rate_applied)}` : ""}</td><td className="text-right">{inr(s.amount)}</td></tr>)}</tbody>
        </table>
        <div className="ml-auto mt-4 w-64 space-y-1">
          <div className="flex justify-between"><span>Subtotal</span><span>{inr(inv.subtotal)}</span></div>
          {inv.kind === "gst" && Number(inv.igst) > 0 && <div className="flex justify-between"><span>IGST 18%</span><span>{inr(inv.igst)}</span></div>}
          {inv.kind === "gst" && Number(inv.cgst) > 0 && <><div className="flex justify-between"><span>CGST 9%</span><span>{inr(inv.cgst)}</span></div><div className="flex justify-between"><span>SGST 9%</span><span>{inr(inv.sgst)}</span></div></>}
          <div className="flex justify-between border-t pt-1 text-base font-bold"><span>Total</span><span>{inr(inv.total)}</span></div>
        </div>
        <p className="mt-10 text-xs text-muted-foreground">SAC 996812 · Courier services. This is a computer-generated invoice.</p>
      </div>
    </div>
  );
}
