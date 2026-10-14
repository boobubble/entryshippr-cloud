import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import * as XLSX from "xlsx";
import { supabase, inr } from "@/lib/supabase";
import { useClients, useRateCards, calcAmount, errMsg } from "@/lib/hooks";
import { PageHead, appHead } from "@/components/PageHead";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

export const Route = createFileRoute("/_app/shipments")({
  head: appHead("Shipments", "Search, add and manage courier shipments."),
  component: Shipments,
});

type Row = { id: string; awb: string; ship_date: string; destination: string | null; service: string; weight: number; pieces: number; amount: number; invoice_id: string | null; client_id: string; clients: { name: string } | null };

function Shipments() {
  const { data: clients = [] } = useClients();
  const { data: cards = [] } = useRateCards();
  const qc = useQueryClient();
  const today = new Date().toISOString().slice(0, 10);
  const [filter, setFilter] = useState({ q: "", client: "", from: "", to: "" });
  const [f, setF] = useState({ awb: "", client_id: "", ship_date: today, destination: "", service: "Standard", weight: "", pieces: "1", amount: "" });

  const { data: rows = [] } = useQuery({
    queryKey: ["shipments", filter],
    queryFn: async () => {
      let q = supabase.from("shipments").select("*, clients(name)").order("ship_date", { ascending: false }).limit(500);
      if (filter.q) q = q.ilike("awb", `%${filter.q}%`);
      if (filter.client) q = q.eq("client_id", filter.client);
      if (filter.from) q = q.gte("ship_date", filter.from);
      if (filter.to) q = q.lte("ship_date", filter.to);
      const { data, error } = await q;
      if (error) throw error;
      return data as Row[];
    },
  });

  const auto = f.client_id && f.weight ? calcAmount(cards, f.client_id, f.service, +f.weight) : null;

  async function add(e: React.FormEvent) {
    e.preventDefault();
    const amount = f.amount ? +f.amount : auto;
    if (amount == null) return toast.error("No matching rate card. Enter the amount manually.");
    const { error } = await supabase.from("shipments").insert({ awb: f.awb.trim(), client_id: f.client_id, ship_date: f.ship_date, destination: f.destination, service: f.service, weight: +f.weight, pieces: +f.pieces, amount });
    if (error) return toast.error(error.code === "23505" ? "This AWB already exists" : errMsg(error));
    toast.success("Shipment added");
    setF({ ...f, awb: "", destination: "", weight: "", amount: "" });
    qc.invalidateQueries({ queryKey: ["shipments"] });
  }
  async function del(r: Row) {
    if (r.invoice_id) return toast.error("Already invoiced — delete the invoice first.");
    const { error } = await supabase.from("shipments").delete().eq("id", r.id);
    if (error) return toast.error(errMsg(error));
    qc.invalidateQueries({ queryKey: ["shipments"] });
  }
  function exportXlsx() {
    const ws = XLSX.utils.json_to_sheet(rows.map((r) => ({ AWB: r.awb, Date: r.ship_date, Client: r.clients?.name, Destination: r.destination, Service: r.service, Weight: r.weight, Pieces: r.pieces, Amount: r.amount, Billed: r.invoice_id ? "Yes" : "No" })));
    const wb = XLSX.utils.book_new(); XLSX.utils.book_append_sheet(wb, ws, "Shipments");
    XLSX.writeFile(wb, `shipments-${today}.xlsx`);
  }

  return (
    <div>
      <PageHead title="Shipments"><Button variant="outline" onClick={exportXlsx} disabled={!rows.length}>Export Excel</Button></PageHead>
      <form onSubmit={add} className="mb-6 grid gap-3 rounded-xl border bg-card p-4 md:grid-cols-8 md:items-end">
        <div><Label>AWB</Label><Input required value={f.awb} onChange={(e) => setF({ ...f, awb: e.target.value })} /></div>
        <div className="md:col-span-2"><Label>Client</Label>
          <select required className="h-9 w-full rounded-md border bg-background px-2 text-sm" value={f.client_id} onChange={(e) => setF({ ...f, client_id: e.target.value })}>
            <option value="">Select…</option>{clients.filter((c) => c.active).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select></div>
        <div><Label>Date</Label><Input type="date" required value={f.ship_date} onChange={(e) => setF({ ...f, ship_date: e.target.value })} /></div>
        <div><Label>Destination</Label><Input value={f.destination} onChange={(e) => setF({ ...f, destination: e.target.value })} /></div>
        <div><Label>Service</Label><Input value={f.service} onChange={(e) => setF({ ...f, service: e.target.value })} /></div>
        <div><Label>Weight kg</Label><Input type="number" step="0.001" required value={f.weight} onChange={(e) => setF({ ...f, weight: e.target.value })} /></div>
        <div><Label>Amount ₹</Label><Input type="number" step="0.01" placeholder={auto != null ? String(auto) : "auto"} value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} /></div>
        <Button className="md:col-span-8">Add shipment</Button>
      </form>
      <div className="mb-3 flex flex-wrap gap-2">
        <Input placeholder="Search AWB" className="w-44" value={filter.q} onChange={(e) => setFilter({ ...filter, q: e.target.value })} />
        <select className="h-9 rounded-md border bg-background px-2 text-sm" value={filter.client} onChange={(e) => setFilter({ ...filter, client: e.target.value })}>
          <option value="">All clients</option>{clients.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
        </select>
        <Input type="date" className="w-40" value={filter.from} onChange={(e) => setFilter({ ...filter, from: e.target.value })} />
        <Input type="date" className="w-40" value={filter.to} onChange={(e) => setFilter({ ...filter, to: e.target.value })} />
      </div>
      <div className="overflow-x-auto rounded-xl border bg-card">
        <table className="w-full text-sm">
          <thead className="bg-muted text-left"><tr><th className="p-3">AWB</th><th className="p-3">Date</th><th className="p-3">Client</th><th className="p-3">Destination</th><th className="p-3">Service</th><th className="p-3">Kg</th><th className="p-3 text-right">Amount</th><th className="p-3">Billed</th><th /></tr></thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id} className="border-t"><td className="p-3 font-mono">{r.awb}</td><td className="p-3">{r.ship_date}</td><td className="p-3">{r.clients?.name}</td><td className="p-3">{r.destination}</td><td className="p-3">{r.service}</td><td className="p-3">{r.weight}</td><td className="p-3 text-right">{inr(r.amount)}</td><td className="p-3">{r.invoice_id ? "Yes" : "No"}</td>
                <td className="p-3"><Button size="sm" variant="ghost" onClick={() => del(r)}>Delete</Button></td></tr>
            ))}
            {!rows.length && <tr><td colSpan={9} className="p-6 text-center text-muted-foreground">No shipments found.</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}
