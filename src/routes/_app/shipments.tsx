import { up } from "@/lib/text";
import { createFileRoute, Link } from "@tanstack/react-router";
import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import * as XLSX from "xlsx";
import { supabase, inr } from "@/lib/supabase";
import { useClients, errMsg } from "@/lib/hooks";
import { PageHead, appHead } from "@/components/PageHead";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

export const Route = createFileRoute("/_app/shipments")({
  head: appHead("Shipments", "Search, add and manage courier shipments."),
  component: Shipments,
});

type Row = { id: string; awb: string; ship_date: string; destination: string | null; service: string; weight: number; pieces: number; amount: number; invoice_id: string | null; client_id: string; clients: { name: string; address: string | null; phone: string | null; email: string | null; state: string | null } | null; rate_zone?: string | null; pricing_status?: string; review_reason?: string | null; shipment_type?: string | null; billing_weight?: number | null; weight_unit?: string | null };

function Shipments() {
  const { data: clients = [] } = useClients();
  const qc = useQueryClient();
  const today = new Date().toISOString().slice(0, 10);
  const [filter, setFilter] = useState({ q: "", client: "", from: "", to: "", review: false });
  const [busy, setBusy] = useState(false);
  const [selected, setSelected] = useState<Set<string>>(new Set());

  const { data: rows = [] } = useQuery({
    queryKey: ["shipments", filter],
    queryFn: async () => {
      let q = supabase.from("shipments").select("*, clients(name, address, phone, email, state)").order("ship_date", { ascending: false }).limit(500);
      if (filter.q) q = q.ilike("awb", `%${filter.q}%`);
      if (filter.client) q = q.eq("client_id", filter.client);
      if (filter.from) q = q.gte("ship_date", filter.from);
      if (filter.to) q = q.lte("ship_date", filter.to);
      if (filter.review) q = q.eq("pricing_status", "needs_review");
      const { data, error } = await q;
      if (error) throw error;
      return data as Row[];
    },
  });

  async function del(r: Row) {
    if (r.invoice_id) { toast.error("Already invoiced — delete the invoice first."); return; }
    const { error } = await supabase.from("shipments").delete().eq("id", r.id);
    if (error) { toast.error(errMsg(error)); return; }
    qc.invalidateQueries({ queryKey: ["shipments"] });
  }

  const deletable = rows.filter((r) => !r.invoice_id);
  const selRows = deletable.filter((r) => selected.has(r.id));
  function toggle(id: string, on: boolean) {
    setSelected((s) => { const n = new Set(s); on ? n.add(id) : n.delete(id); return n; });
  }
  function toggleAll(on: boolean) {
    setSelected(on ? new Set(deletable.map((r) => r.id)) : new Set());
  }
  async function delSelected() {
    if (!selRows.length) return;
    if (!window.confirm(`Delete ${selRows.length} shipment${selRows.length > 1 ? "s" : ""}? This cannot be undone.`)) return;
    setBusy(true);
    const { error } = await supabase.from("shipments").delete().in("id", selRows.map((r) => r.id));
    setBusy(false);
    if (error) { toast.error(errMsg(error)); return; }
    toast.success(`Deleted ${selRows.length} shipment${selRows.length > 1 ? "s" : ""}`);
    setSelected(new Set());
    qc.invalidateQueries({ queryKey: ["shipments"] });
  }
  function exportXlsx() {
    const ws = XLSX.utils.json_to_sheet(rows.map((r) => ({ AWB: r.awb, Date: r.ship_date, Client: up(r.clients?.name), City: up(r.destination), Type: r.shipment_type ?? "", Service: r.service, "Weight (kg)": r.weight, Pieces: r.pieces, Amount: r.amount, Status: r.pricing_status === "needs_review" ? `Needs review: ${r.review_reason}` : "Priced", Billed: r.invoice_id ? "Yes" : "No" })));
    const wb = XLSX.utils.book_new(); XLSX.utils.book_append_sheet(wb, ws, "Shipments");
    XLSX.writeFile(wb, `shipments-${today}.xlsx`);
  }

  // Billing export in the 130893 layout (same headers and order). Values EntrySetu does not store stay blank.
  function exportBilling() {
    const head = ["Date", "Consignment No.", "Customer Name", "Station", "Wt. (Gms)", "Amount", "Remarks", "RateZone", "Customer Address Line 1", "Customer Address Line 2", "Customer City", "Customer Phone", "Customer Mobile", "Customer Email", "Contact Person", "Consignment ID", "AccountID", "Pincode", "State", "ServiceType", "To", "Address Line 1", "Address Line 2", "Contact No. 1", "2", "Sender Mobile", "Value of Goods", "Pcs"];
    const dmy = (d: string) => d.split("-").reverse().join("-");
    const wt = (r: Row) => r.shipment_type === "NON-DOX" ? `${+Number(r.weight).toFixed(3)} Kgs` : +Number(r.weight).toFixed(3);
    const body = rows.map((r) => {
      const c = r.clients; const review = r.pricing_status === "needs_review";
      const v: Record<string, string | number> = {
        "Date": dmy(r.ship_date), "Consignment No.": r.awb, "Customer Name": up(c?.name), "Station": up(r.destination),
        "Wt. (Gms)": wt(r), "Amount": review ? "" : Number(r.amount), "Remarks": review ? `Needs review: ${r.review_reason ?? ""}` : "",
        "RateZone": review ? "" : (r.rate_zone ?? ""), "Customer Address Line 1": c?.address ?? "", "Customer Mobile": c?.phone ?? "",
        "Customer Email": c?.email ?? "", "State": up(c?.state), "ServiceType": r.shipment_type === "DOX" ? "DOX" : r.service, "Pcs": r.pieces,
      };
      return head.map((h) => v[h] ?? "");
    });
    const wb = XLSX.utils.book_new(); XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet([head, ...body]), "Sheet1");
    XLSX.writeFile(wb, `billing-${today}.xlsx`);
  }

  return (
    <div>
      <PageHead title="Shipments"><div className="flex gap-2"><Button variant="outline" onClick={exportXlsx} disabled={!rows.length}>Export Excel</Button><Button onClick={exportBilling} disabled={!rows.length}>Billing export</Button></div></PageHead>
      <div className="mb-6 flex flex-wrap items-center justify-between gap-3 rounded-xl border bg-card p-4">
        <p className="text-sm text-muted-foreground">Add shipments one by one on the Consignment Entry screen (AWB suggestions, Auto/Manual charges, keyboard entry).</p>
        <Button asChild><Link to="/entry">Add shipment</Link></Button>
      </div>
      <div className="mb-3 flex flex-wrap gap-2">
        <Input placeholder="Search AWB" className="w-44" value={filter.q} onChange={(e) => setFilter({ ...filter, q: e.target.value })} />
        <select className="h-9 rounded-md border bg-background px-2 text-sm" value={filter.client} onChange={(e) => setFilter({ ...filter, client: e.target.value })}>
          <option value="">All clients</option>{clients.map((c) => <option key={c.id} value={c.id}>{up(c.name)}</option>)}
        </select>
        <Input type="date" className="w-40" value={filter.from} onChange={(e) => setFilter({ ...filter, from: e.target.value })} />
        <Input type="date" className="w-40" value={filter.to} onChange={(e) => setFilter({ ...filter, to: e.target.value })} />
        <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={filter.review} onChange={(e) => setFilter({ ...filter, review: e.target.checked })} />Needs review only</label>
        {selRows.length > 0 && <Button variant="destructive" size="sm" disabled={busy} onClick={delSelected}>Delete selected ({selRows.length})</Button>}
      </div>
      <div className="overflow-x-auto rounded-xl border bg-card">
        <table className="w-full text-sm">
          <thead className="bg-muted text-left"><tr><th className="p-3 w-8"><input type="checkbox" aria-label="Select all" checked={deletable.length > 0 && selRows.length === deletable.length} onChange={(e) => toggleAll(e.target.checked)} /></th><th className="p-3">AWB</th><th className="p-3">Date</th><th className="p-3">Client</th><th className="p-3">City</th><th className="p-3">Service</th><th className="p-3">Weight</th><th className="p-3 text-right">Amount</th><th className="p-3">Status</th><th /></tr></thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id} className="border-t"><td className="p-3">{r.invoice_id ? null : <input type="checkbox" aria-label={`Select ${r.awb}`} checked={selected.has(r.id)} onChange={(e) => toggle(r.id, e.target.checked)} />}</td><td className="p-3 font-mono">{r.awb}</td><td className="p-3">{r.ship_date}</td><td className="p-3">{up(r.clients?.name)}</td><td className="p-3">{up(r.destination)}</td><td className="p-3">{r.service}</td><td className="p-3">{r.billing_weight != null && r.weight_unit ? `${+r.billing_weight} ${r.weight_unit}` : `${r.weight} kg`}{r.shipment_type ? ` · ${r.shipment_type}` : ""}</td><td className="p-3 text-right">{r.pricing_status === "needs_review" ? "—" : inr(r.amount)}</td><td className="p-3">{r.pricing_status === "needs_review" ? <span className="text-destructive">Needs review: {r.review_reason}</span> : r.invoice_id ? "Billed" : "Unbilled"}</td>
                <td className="p-3"><Button size="sm" variant="ghost" onClick={() => del(r)}>Delete</Button></td></tr>
            ))}
            {!rows.length && <tr><td colSpan={10} className="p-6 text-center text-muted-foreground">No shipments found.</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}
