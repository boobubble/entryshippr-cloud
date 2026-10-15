import { up } from "@/lib/text";
import { invDate } from "@/components/InvoiceDocument";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useMemo, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { supabase, inr } from "@/lib/supabase";
import { useClients, errMsg } from "@/lib/hooks";
import { PageHead, appHead } from "@/components/PageHead";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

export const Route = createFileRoute("/_app/invoices/")({
  head: appHead("Invoices", "Create, edit and finalize GST and non-GST invoices from unbilled shipments."),
  component: Invoices,
});

type Row = { id: string; invoice_no: string | null; invoice_date: string; total: number; kind: "gst" | "nongst"; status: "draft" | "issued" | "cancelled"; clients: { name: string } | null; bill_to_name?: string | null; reissue_of?: string | null };
type Ship = { id: string; ship_date: string; awb: string; destination: string | null; amount: number; pricing_status: string | null };

const badge = { draft: "bg-muted text-muted-foreground", issued: "bg-primary/10 text-primary", cancelled: "bg-destructive/10 text-destructive" };

function Invoices() {
  const { data: clients = [] } = useClients();
  const qc = useQueryClient();
  const nav = useNavigate();
  const d = new Date();
  const first = new Date(d.getFullYear(), d.getMonth() - 1, 1).toLocaleDateString("en-CA");
  const last = new Date(d.getFullYear(), d.getMonth(), 0).toLocaleDateString("en-CA");
  const [f, setF] = useState({ client_id: "", from: first, to: last });
  const [busy, setBusy] = useState(false);
  const [picked, setPicked] = useState<Set<string> | null>(null);

  const { data: invoices = [] } = useQuery({
    queryKey: ["invoices"],
    queryFn: async () => {
      const { data, error } = await supabase.from("invoices").select("*, clients(name)").order("created_at", { ascending: false });
      if (error) throw error;
      return data as Row[];
    },
  });

  const [tab, setTab] = useState<"gst" | "nongst" | "all">("gst");
  const [status, setStatus] = useState<"active" | "issued" | "draft" | "cancelled" | "all">("active");
  const [desc, setDesc] = useState(true);
  const shown = useMemo(() => {
    const rows = invoices.filter((i) => (tab === "all" || i.kind === tab) &&
      (status === "all" || (status === "active" ? i.status !== "cancelled" : i.status === status)));
    return [...rows].sort((a, b) => { const c = compareInvoices(a, b); return desc ? -c : c; });
  }, [invoices, tab, status, desc]);

  const { data: eligible = [] } = useQuery({
    queryKey: ["eligible-shipments", f.client_id, f.from, f.to],
    enabled: !!f.client_id && !!f.from && !!f.to,
    queryFn: async () => {
      const { data, error } = await supabase.from("shipments").select("id, ship_date, awb, destination, amount, pricing_status")
        .eq("client_id", f.client_id).is("invoice_id", null).is("draft_invoice_id", null)
        .gte("ship_date", f.from).lte("ship_date", f.to).order("ship_date").order("awb");
      if (error) throw error;
      return data as Ship[];
    },
  });
  const ok = (s: Ship) => s.pricing_status !== "needs_review" && Number(s.amount) > 0;
  const sel = picked ?? new Set(eligible.filter(ok).map((s) => s.id));
  const toggle = (id: string) => { const n = new Set(sel); n.has(id) ? n.delete(id) : n.add(id); setPicked(n); };

  async function create(e: React.FormEvent) {
    e.preventDefault();
    if (!sel.size) { toast.error("Select at least one shipment"); return; }
    setBusy(true);
    try {
      const { data: id, error } = await supabase.rpc("create_invoice_draft", { p_client_id: f.client_id, p_from: f.from, p_to: f.to, p_shipment_ids: [...sel] });
      if (error) throw error;
      qc.invalidateQueries();
      setPicked(null);
      toast.success("Draft created");
      nav({ to: "/invoices/edit/$id", params: { id: id as string } });
    } catch (err) { toast.error(errMsg(err)); } finally { setBusy(false); }
  }

  async function cancel(id: string) {
    const reason = prompt("Cancel this invoice? Its number is kept and its shipments become unbilled again. Reason:");
    if (reason === null) return;
    if (!reason.trim()) { toast.error("Please enter a reason"); return; }
    const { error } = await supabase.rpc("cancel_invoice", { p_invoice_id: id, p_reason: reason.trim() });
    if (error) { toast.error(errMsg(error)); return; }
    toast.success("Invoice cancelled");
    qc.invalidateQueries();
  }

  async function reissue(id: string) {
    if (!confirm("Start a new draft from this cancelled invoice? It gets a new number when you finalize it.")) return;
    const { data: nid, error } = await supabase.rpc("reissue_invoice", { p_cancelled_id: id });
    if (error) { toast.error(errMsg(error)); return; }
    qc.invalidateQueries();
    nav({ to: "/invoices/edit/$id", params: { id: nid as string } });
  }

  const reissued = new Set(invoices.filter((i) => i.reissue_of && i.status !== "cancelled").map((i) => i.reissue_of));

  return (
    <div>
      <PageHead title="Invoices" />
      <form onSubmit={create} className="mb-6 rounded-xl border bg-card p-4">
        <div className="grid gap-3 md:grid-cols-4 md:items-end">
          <div><Label>Client</Label>
            <select required className="h-9 w-full rounded-md border bg-background px-2 text-sm" value={f.client_id} onChange={(e) => { setF({ ...f, client_id: e.target.value }); setPicked(null); }}>
              <option value="">Select…</option>{clients.map((c) => <option key={c.id} value={c.id}>{up(c.name)} {c.is_gst ? "(GST)" : "(Non-GST)"}</option>)}
            </select></div>
          <div><Label>From</Label><Input type="date" required value={f.from} onChange={(e) => { setF({ ...f, from: e.target.value }); setPicked(null); }} /></div>
          <div><Label>To</Label><Input type="date" required value={f.to} onChange={(e) => { setF({ ...f, to: e.target.value }); setPicked(null); }} /></div>
          <Button disabled={busy || !f.client_id}>{busy ? "Creating…" : `Create draft (${sel.size})`}</Button>
        </div>
        {f.client_id && (
          <div className="mt-4 max-h-64 overflow-auto rounded-md border">
            <table className="w-full text-sm">
              <thead className="sticky top-0 bg-muted text-left"><tr><th className="w-8 p-2" /><th className="p-2">Date</th><th className="p-2">AWB</th><th className="p-2">Destination</th><th className="p-2 text-right">Amount</th></tr></thead>
              <tbody>
                {eligible.map((s) => (
                  <tr key={s.id} className="border-t">
                    <td className="p-2"><input type="checkbox" aria-label={`Select ${s.awb}`} disabled={!ok(s)} checked={sel.has(s.id)} onChange={() => toggle(s.id)} /></td>
                    <td className="p-2">{invDate(s.ship_date)}</td><td className="p-2 font-mono">{s.awb}</td><td className="p-2">{up(s.destination)}</td>
                    <td className="p-2 text-right">{ok(s) ? inr(s.amount) : <span className="text-destructive">Needs review</span>}</td>
                  </tr>
                ))}
                {!eligible.length && <tr><td colSpan={5} className="p-4 text-center text-muted-foreground">No unbilled shipments for this client in this period.</td></tr>}
              </tbody>
            </table>
          </div>
        )}
      </form>
      <div className="mb-3 flex flex-wrap items-center gap-2">
        <div className="inline-flex rounded-md border bg-card p-0.5" role="tablist" aria-label="Invoice series">
          {([["gst", "GST"], ["nongst", "Non-GST"], ["all", "All"]] as const).map(([k, l]) => (
            <button key={k} type="button" role="tab" aria-selected={tab === k} onClick={() => setTab(k)}
              className={`rounded px-3 py-1 text-sm ${tab === k ? "bg-primary text-primary-foreground" : "text-muted-foreground"}`}>{l}</button>
          ))}
        </div>
        <select aria-label="Status filter" className="h-8 rounded-md border bg-background px-2 text-sm" value={status} onChange={(e) => setStatus(e.target.value as typeof status)}>
          <option value="active">Drafts & issued</option><option value="issued">Issued</option><option value="draft">Drafts</option><option value="cancelled">Cancelled</option><option value="all">All statuses</option>
        </select>
        <Button type="button" size="sm" variant="outline" onClick={() => setDesc(!desc)}>{desc ? "Latest first ↓" : "Oldest first ↑"}</Button>
      </div>
      <div className="overflow-x-auto rounded-xl border bg-card">
        <table className="w-full text-sm">
          <thead className="bg-muted text-left"><tr><th className="p-3">Invoice</th><th className="p-3">Date</th><th className="p-3">Client</th><th className="p-3">Type</th><th className="p-3">Status</th><th className="p-3 text-right">Total</th><th /></tr></thead>
          <tbody>
            {shown.map((i) => (
              <tr key={i.id} className="border-t">
                <td className="p-3">{i.status === "draft"
                  ? <Link to="/invoices/edit/$id" params={{ id: i.id }} className="text-primary underline">Draft</Link>
                  : <Link to="/invoices/$id" params={{ id: i.id }} className="text-primary underline">{i.invoice_no}</Link>}</td>
                <td className="p-3">{invDate(i.invoice_date)}</td><td className="p-3">{up(i.bill_to_name ?? i.clients?.name)}</td>
                <td className="p-3">{i.kind === "gst" ? "GST" : "Non-GST"}</td>
                <td className="p-3"><span className={`rounded px-2 py-0.5 text-xs font-medium capitalize ${badge[i.status]}`}>{i.status}</span></td>
                <td className="p-3 text-right">{inr(i.total)}</td>
                <td className="p-3 text-right whitespace-nowrap">
                  {i.status === "draft" && <Button size="sm" variant="ghost" asChild><Link to="/invoices/edit/$id" params={{ id: i.id }}>Edit</Link></Button>}
                  {i.status === "issued" && <Button size="sm" variant="ghost" onClick={() => cancel(i.id)}>Cancel</Button>}
                  {i.status === "cancelled" && !reissued.has(i.id) && <Button size="sm" variant="ghost" onClick={() => reissue(i.id)}>Reissue</Button>}
                </td>
              </tr>
            ))}
            {!shown.length && <tr><td colSpan={7} className="p-6 text-center text-muted-foreground">{invoices.length ? "No invoices match this filter." : "No invoices yet."}</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}

// Numeric serial order: drafts (no number) count as newest; then financial year,
// then sequence number as a number; manual numbers (no seq) by issue time, then natural text order.
function compareInvoices(a: Row & { fy?: string | null; seq?: number | null; finalized_at?: string | null; created_at?: string }, b: typeof a): number {
  const da = a.status === "draft" ? 1 : 0, db = b.status === "draft" ? 1 : 0;
  if (da !== db) return da - db;
  if (da) return (a.created_at ?? "").localeCompare(b.created_at ?? "");
  const fy = (a.fy ?? "").localeCompare(b.fy ?? "");
  if (fy) return fy;
  if (a.seq != null && b.seq != null && a.seq !== b.seq) return a.seq - b.seq;
  const t = (a.finalized_at ?? a.invoice_date).localeCompare(b.finalized_at ?? b.invoice_date);
  if (t) return t;
  return (a.invoice_no ?? "").localeCompare(b.invoice_no ?? "", undefined, { numeric: true });
}
