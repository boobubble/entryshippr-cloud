import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { supabase, inr } from "@/lib/supabase";
import { useClients, useProfile, errMsg } from "@/lib/hooks";
import { PageHead, appHead } from "@/components/PageHead";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

export const Route = createFileRoute("/_app/invoices/")({
  head: appHead("Invoices", "Create GST and non-GST invoices from unbilled shipments."),
  component: Invoices,
});

const r2 = (n: number) => Math.round(n * 100) / 100;

function Invoices() {
  const { data: clients = [] } = useClients();
  const { data: me } = useProfile();
  const qc = useQueryClient();
  const nav = useNavigate();
  const d = new Date();
  const first = new Date(d.getFullYear(), d.getMonth() - 1, 1).toLocaleDateString("en-CA");
  const last = new Date(d.getFullYear(), d.getMonth(), 0).toLocaleDateString("en-CA");
  const [f, setF] = useState({ client_id: "", from: first, to: last });
  const [busy, setBusy] = useState(false);

  const { data: invoices = [] } = useQuery({
    queryKey: ["invoices"],
    queryFn: async () => {
      const { data, error } = await supabase.from("invoices").select("*, clients(name)").order("created_at", { ascending: false });
      if (error) throw error;
      return data as { id: string; invoice_no: string; invoice_date: string; total: number; is_gst: boolean; clients: { name: string } | null }[];
    },
  });

  async function create(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    try {
      const client = clients.find((c) => c.id === f.client_id)!;
      const { data: ships, error } = await supabase.from("shipments").select("id, amount").eq("client_id", f.client_id).is("invoice_id", null).gte("ship_date", f.from).lte("ship_date", f.to);
      if (error) throw error;
      if (!ships.length) throw new Error("No unbilled shipments for this client in the period");
      const subtotal = r2(ships.reduce((a, s) => a + Number(s.amount), 0));
      const p = me?.profile;
      const intra = !p?.state || !client.state || p.state.trim().toLowerCase() === client.state.trim().toLowerCase();
      const gst = client.is_gst ? r2(subtotal * 0.18) : 0;
      const cgst = client.is_gst && intra ? r2(gst / 2) : 0;
      const igst = client.is_gst && !intra ? gst : 0;
      const { count } = await supabase.from("invoices").select("id", { count: "exact", head: true });
      const fy = d.getMonth() >= 3 ? d.getFullYear() : d.getFullYear() - 1;
      const invoice_no = `${p?.invoice_prefix || "INV"}/${fy}-${String(fy + 1).slice(2)}/${String((count || 0) + 1).padStart(4, "0")}`;
      const { data: inv, error: e2 } = await supabase.from("invoices").insert({ client_id: client.id, invoice_no, period_from: f.from, period_to: f.to, is_gst: client.is_gst, subtotal, cgst, sgst: cgst, igst, total: r2(subtotal + cgst * 2 + igst) }).select("id").single();
      if (e2) throw e2;
      const { error: e3 } = await supabase.from("shipments").update({ invoice_id: inv.id }).in("id", ships.map((s) => s.id));
      if (e3) throw e3;
      qc.invalidateQueries();
      toast.success(`Invoice ${invoice_no} created`);
      nav({ to: "/invoices/$id", params: { id: inv.id } });
    } catch (err) { toast.error(errMsg(err)); } finally { setBusy(false); }
  }

  async function del(id: string) {
    if (!confirm("Delete this invoice? Its shipments become unbilled again.")) return;
    const { error } = await supabase.from("invoices").delete().eq("id", id);
    if (error) return toast.error(errMsg(error));
    qc.invalidateQueries();
  }

  return (
    <div>
      <PageHead title="Invoices" />
      <form onSubmit={create} className="mb-6 grid gap-3 rounded-xl border bg-card p-4 md:grid-cols-4 md:items-end">
        <div><Label>Client</Label>
          <select required className="h-9 w-full rounded-md border bg-background px-2 text-sm" value={f.client_id} onChange={(e) => setF({ ...f, client_id: e.target.value })}>
            <option value="">Select…</option>{clients.map((c) => <option key={c.id} value={c.id}>{c.name} {c.is_gst ? "(GST)" : "(Non-GST)"}</option>)}
          </select></div>
        <div><Label>From</Label><Input type="date" required value={f.from} onChange={(e) => setF({ ...f, from: e.target.value })} /></div>
        <div><Label>To</Label><Input type="date" required value={f.to} onChange={(e) => setF({ ...f, to: e.target.value })} /></div>
        <Button disabled={busy}>{busy ? "Creating…" : "Create invoice"}</Button>
      </form>
      <div className="overflow-x-auto rounded-xl border bg-card">
        <table className="w-full text-sm">
          <thead className="bg-muted text-left"><tr><th className="p-3">Invoice</th><th className="p-3">Date</th><th className="p-3">Client</th><th className="p-3">Type</th><th className="p-3 text-right">Total</th><th /></tr></thead>
          <tbody>
            {invoices.map((i) => (
              <tr key={i.id} className="border-t"><td className="p-3"><Link to="/invoices/$id" params={{ id: i.id }} className="text-primary underline">{i.invoice_no}</Link></td><td className="p-3">{i.invoice_date}</td><td className="p-3">{i.clients?.name}</td><td className="p-3">{i.is_gst ? "GST" : "Non-GST"}</td><td className="p-3 text-right">{inr(i.total)}</td>
                <td className="p-3 text-right"><Button size="sm" variant="ghost" onClick={() => del(i.id)}>Delete</Button></td></tr>
            ))}
            {!invoices.length && <tr><td colSpan={6} className="p-6 text-center text-muted-foreground">No invoices yet.</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}
