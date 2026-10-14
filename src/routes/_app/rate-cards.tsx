import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { supabase, inr } from "@/lib/supabase";
import { useClients, useRateCards, errMsg } from "@/lib/hooks";
import { PageHead, appHead } from "@/components/PageHead";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

export const Route = createFileRoute("/_app/rate-cards")({
  head: appHead("Rate cards", "Weight-slab rates per service, default or per client."),
  component: RateCards,
});

function RateCards() {
  const { data: cards = [] } = useRateCards();
  const { data: clients = [] } = useClients();
  const qc = useQueryClient();
  const [f, setF] = useState({ client_id: "", service: "Standard", min_weight: "0", max_weight: "0.5", rate: "", extra_per_kg: "0" });

  async function add(e: React.FormEvent) {
    e.preventDefault();
    const row = { client_id: f.client_id || null, service: f.service.trim(), min_weight: +f.min_weight, max_weight: +f.max_weight, rate: +f.rate, extra_per_kg: +f.extra_per_kg };
    if (row.max_weight < row.min_weight) { toast.error("Max weight must be ≥ min weight"); return; }
    const { error } = await supabase.from("rate_cards").insert(row);
    if (error) { toast.error(errMsg(error)); return; }
    toast.success("Slab added");
    setF({ ...f, min_weight: f.max_weight, max_weight: "", rate: "" });
    qc.invalidateQueries({ queryKey: ["rate_cards"] });
  }
  async function del(id: string) {
    const { error } = await supabase.from("rate_cards").delete().eq("id", id);
    if (error) { toast.error(errMsg(error)); return; }
    qc.invalidateQueries({ queryKey: ["rate_cards"] });
  }
  const name = (id: string | null) => (id ? clients.find((c) => c.id === id)?.name || "?" : "Default (all clients)");

  return (
    <div>
      <PageHead title="Rate cards" />
      <form onSubmit={add} className="mb-6 grid gap-3 rounded-xl border bg-card p-4 md:grid-cols-7 md:items-end">
        <div className="md:col-span-2"><Label>Applies to</Label>
          <select className="h-9 w-full rounded-md border bg-background px-2 text-sm" value={f.client_id} onChange={(e) => setF({ ...f, client_id: e.target.value })}>
            <option value="">Default (all clients)</option>
            {clients.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </div>
        <div><Label>Service</Label><Input required value={f.service} onChange={(e) => setF({ ...f, service: e.target.value })} /></div>
        <div><Label>From kg</Label><Input type="number" step="0.001" required value={f.min_weight} onChange={(e) => setF({ ...f, min_weight: e.target.value })} /></div>
        <div><Label>To kg</Label><Input type="number" step="0.001" required value={f.max_weight} onChange={(e) => setF({ ...f, max_weight: e.target.value })} /></div>
        <div><Label>Rate ₹</Label><Input type="number" step="0.01" required value={f.rate} onChange={(e) => setF({ ...f, rate: e.target.value })} /></div>
        <div><Label>Extra ₹/kg above</Label><Input type="number" step="0.01" value={f.extra_per_kg} onChange={(e) => setF({ ...f, extra_per_kg: e.target.value })} /></div>
        <Button className="md:col-span-7">Add slab</Button>
      </form>
      <p className="mb-3 text-sm text-muted-foreground">Client-specific slabs are used first; otherwise default slabs apply. Weights above the highest slab add the extra per-kg rate.</p>
      <div className="overflow-x-auto rounded-xl border bg-card">
        <table className="w-full text-sm">
          <thead className="bg-muted text-left"><tr><th className="p-3">Applies to</th><th className="p-3">Service</th><th className="p-3">Weight (kg)</th><th className="p-3">Rate</th><th className="p-3">Extra/kg</th><th /></tr></thead>
          <tbody>
            {cards.map((c) => (
              <tr key={c.id} className="border-t"><td className="p-3">{name(c.client_id)}</td><td className="p-3">{c.service}</td><td className="p-3">{c.min_weight} – {c.max_weight}</td><td className="p-3">{inr(c.rate)}</td><td className="p-3">{inr(c.extra_per_kg)}</td>
                <td className="p-3 text-right"><Button size="sm" variant="ghost" onClick={() => del(c.id)}>Delete</Button></td></tr>
            ))}
            {!cards.length && <tr><td colSpan={6} className="p-6 text-center text-muted-foreground">No slabs yet.</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}
