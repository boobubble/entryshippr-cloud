import { createFileRoute, Link } from "@tanstack/react-router";
import { useMemo, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { useZones, errMsg } from "@/lib/hooks";
import { normCity, registerCities } from "@/lib/cities";
import { CityZoneDialog } from "@/components/CityZoneDialog";
import { PageHead, appHead } from "@/components/PageHead";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

export const Route = createFileRoute("/_app/cities")({
  head: appHead("Cities & zones", "Assign your zones to cities, fix unmapped cities and review shipments."),
  component: CitiesPage,
});

const sel = "h-9 rounded-md border bg-background px-2 text-sm";
type City = { id: string; name: string; state: string | null; source: string };
type Mapping = { city_id: string; zone_id: string; cities: { name: string; state: string | null } | null };

function CitiesPage() {
  const qc = useQueryClient();
  const zonesQ = useZones();
  const zones = zonesQ.data ?? [];
  const [q, setQ] = useState("");
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const [bulkZone, setBulkZone] = useState("");
  const [dialog, setDialog] = useState(false);

  const mappings = useQuery({
    queryKey: ["seller_city_zones"], retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.from("seller_city_zones").select("city_id, zone_id, cities(name, state)");
      if (error) throw error;
      return (data as unknown as Mapping[]).sort((a, b) => (a.cities?.name ?? "").localeCompare(b.cities?.name ?? ""));
    },
  });
  const review = useQuery({
    queryKey: ["review_cities"], retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.from("shipments").select("destination").eq("pricing_status", "needs_review").limit(5000);
      if (error) throw error;
      const names = [...new Set(data.map((d) => (d.destination ?? "").trim()).filter(Boolean))];
      const res = names.length ? await registerCities(names) : new Map();
      return { count: data.length, unmapped: [...res.values()].filter((r) => (r.status === "unmapped" && r.city_id) || r.status === "ambiguous") };
    },
  });
  const search = useQuery({
    queryKey: ["cities", q], retry: false,
    queryFn: async () => {
      let req = supabase.from("cities").select("id, name, state, source").order("name").limit(100);
      const n = normCity(q);
      if (n) req = req.like("name_norm", `%${n.replace(/[%_]/g, "")}%`);
      const { data, error } = await req;
      if (error) throw error;
      return data as City[];
    },
  });

  const zoneByCity = useMemo(() => new Map((mappings.data ?? []).map((m) => [m.city_id, m.zone_id])), [mappings.data]);
  const refresh = () => { ["seller_city_zones", "review_cities", "shipments", "zones"].forEach((k) => qc.invalidateQueries({ queryKey: [k] })); };

  async function assign(cityIds: string[], zoneId: string) {
    const { error } = await supabase.from("seller_city_zones")
      .upsert(cityIds.map((city_id) => ({ city_id, zone_id: zoneId, updated_at: new Date().toISOString() })), { onConflict: "owner_id,city_id" });
    if (error) { toast.error(errMsg(error)); return false; }
    toast.success(`Zone set for ${cityIds.length} ${cityIds.length === 1 ? "city" : "cities"}`); refresh(); return true;
  }
  async function unassign(cityId: string) {
    const { error } = await supabase.from("seller_city_zones").delete().eq("city_id", cityId);
    if (error) { toast.error(errMsg(error)); return; }
    refresh();
  }

  const notReady = mappings.isError || search.isError;
  const zoneName = (id?: string) => zones.find((z) => z.id === id)?.name;

  return (
    <div className="space-y-6">
      <PageHead title="Cities & zones" />
      {notReady && <p className="rounded-lg border border-destructive/40 bg-destructive/10 p-3 text-sm text-destructive">City management isn't available yet. Run the cities database update in Supabase, then reload.</p>}
      {!zones.length && !zonesQ.isLoading && <p className="text-sm">You have no zones yet. Create them on the <Link to="/rate-cards" className="text-primary underline">Rate cards</Link> page.</p>}

      <section className="rounded-xl border bg-card p-4">
        <div className="flex flex-wrap items-center gap-3">
          <h2 className="mr-auto font-semibold">Needs review</h2>
          <span className="text-sm text-muted-foreground">{review.data?.count ?? 0} shipments waiting · {review.data?.unmapped.length ?? 0} cities without your zone</span>
          <Button disabled={!review.data?.unmapped.length} onClick={() => setDialog(true)}>Assign zones</Button>
        </div>
        <p className="mt-2 text-sm text-muted-foreground">Shipments are re-priced automatically as soon as their city gets a zone.</p>
      </section>

      <section className="rounded-xl border bg-card p-4">
        <h2 className="mb-3 font-semibold">My city zones ({mappings.data?.length ?? 0})</h2>
        <div className="max-h-96 overflow-auto">
          <table className="w-full text-sm">
            <thead className="sticky top-0 bg-muted text-left"><tr><th className="p-2">City</th><th className="p-2">State</th><th className="p-2">Zone</th><th /></tr></thead>
            <tbody>
              {(mappings.data ?? []).map((m) => (
                <tr key={m.city_id} className="border-t">
                  <td className="p-2">{m.cities?.name}</td><td className="p-2 text-muted-foreground">{m.cities?.state ?? "—"}</td>
                  <td className="p-2"><select aria-label={`Zone for ${m.cities?.name}`} className={sel} value={m.zone_id} onChange={(e) => assign([m.city_id], e.target.value)}>
                    {zones.map((z) => <option key={z.id} value={z.id}>{z.name}</option>)}
                  </select></td>
                  <td className="p-2 text-right"><Button size="sm" variant="ghost" onClick={() => unassign(m.city_id)}>Remove</Button></td>
                </tr>
              ))}
              {!mappings.data?.length && <tr><td colSpan={4} className="p-4 text-center text-muted-foreground">No cities assigned yet.</td></tr>}
            </tbody>
          </table>
        </div>
      </section>

      <section className="rounded-xl border bg-card p-4">
        <div className="mb-3 flex flex-wrap items-center gap-2">
          <h2 className="mr-auto font-semibold">All cities</h2>
          <Input placeholder="Search city" className="w-52" value={q} onChange={(e) => setQ(e.target.value)} />
          <select className={sel} value={bulkZone} onChange={(e) => setBulkZone(e.target.value)}>
            <option value="">Zone for selected…</option>{zones.map((z) => <option key={z.id} value={z.id}>{z.name}</option>)}
          </select>
          <Button disabled={!picked.size || !bulkZone} onClick={async () => { if (await assign([...picked], bulkZone)) setPicked(new Set()); }}>Assign {picked.size || ""}</Button>
        </div>
        <p className="mb-2 text-xs text-muted-foreground">Cities are shared by everyone using EntrySetu. Zones are yours only. New cities are added automatically from your shipments and the reviewed city list.</p>
        <div className="max-h-[480px] overflow-auto">
          <table className="w-full text-sm">
            <thead className="sticky top-0 bg-muted text-left"><tr><th className="p-2 w-8" /><th className="p-2">City</th><th className="p-2">State</th><th className="p-2">My zone</th></tr></thead>
            <tbody>
              {(search.data ?? []).map((c) => (
                <tr key={c.id} className="border-t">
                  <td className="p-2"><input type="checkbox" aria-label={`Select ${c.name}`} checked={picked.has(c.id)} onChange={(e) => { const s = new Set(picked); if (e.target.checked) s.add(c.id); else s.delete(c.id); setPicked(s); }} /></td>
                  <td className="p-2">{c.name}{c.source === "user" && <span className="ml-2 text-xs text-muted-foreground">(added from shipments)</span>}</td>
                  <td className="p-2 text-muted-foreground">{c.state ?? "—"}</td>
                  <td className="p-2">{zoneName(zoneByCity.get(c.id)) ?? <span className="text-muted-foreground">Not set</span>}</td>
                </tr>
              ))}
              {!search.data?.length && <tr><td colSpan={4} className="p-4 text-center text-muted-foreground">No cities found.</td></tr>}
            </tbody>
          </table>
        </div>
      </section>

      <CityZoneDialog open={dialog} items={review.data?.unmapped ?? []} zones={zones} onClose={() => setDialog(false)} onSaved={() => { setDialog(false); refresh(); }} />
    </div>
  );
}
