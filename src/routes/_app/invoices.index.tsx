import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { supabase, inr } from "@/lib/supabase";
import { useClients, errMsg } from "@/lib/hooks";
import { PageHead, appHead } from "@/components/PageHead";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

export const Route = createFileRoute("/_app/invoices/")({
  head: appHead("Invoices", "Create GST and non-GST invoices from unbilled shipments."),
  component: Invoices,
});


function Invoices() {
  const { data: clients = [] } = useClients();
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
      return data as { id: string; invoice_no: string; invoice_date: string; total: number; kind: "gst" | "nongst"; status: "issued" | "cancelled"; clients: { name: string } | null }[];
    },
  });

  async function create(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    try {
      const { data: id, error } = await supabase.rpc("create_invoice", { p_client_id: f.client_id, p_from: f.from, p_to: f.to });
      if (error) throw error;
      qc.invalidateQueries();
      toast.success("Invoice created");
      nav({ to: "/invoices/$id", params: { id: id as string } });
    } catch (err) { toast.error(errMsg(err)); } finally { setBusy(false); }
  }

  async function cancel(id: string) {
    const reason = prompt("Cancel this invoice? Its number is kept and its shipments become unbilled again. Reason:");
    if (reason === null) return;
    const { error } = await supabase.rpc("cancel_invoice", { p_invoice_id: id, p_reason: reason });
    if (error) { toast.error(errMsg(error)); return; }
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
              <tr key={i.id} className="border-t"><td className="p-3"><Link to="/invoices/$id" params={{ id: i.id }} className="text-primary underline">{i.invoice_no}</Link></td><td className="p-3">{i.invoice_date}</td><td className="p-3">{i.clients?.name}</td><td className="p-3">{i.kind === "gst" ? "GST" : "Non-GST"}{i.status === "cancelled" && <span className="ml-2 text-destructive">Cancelled</span>}</td><td className="p-3 text-right">{inr(i.total)}</td>
                <td className="p-3 text-right">{i.status === "issued" && <Button size="sm" variant="ghost" onClick={() => cancel(i.id)}>Cancel</Button>}</td></tr>
            ))}
            {!invoices.length && <tr><td colSpan={6} className="p-6 text-center text-muted-foreground">No invoices yet.</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}
