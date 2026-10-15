import { up, upName } from "@/lib/text";
import { CityInput } from "@/components/Autocomplete";
import { createFileRoute } from "@tanstack/react-router";
import { useMemo, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { useZones, errMsg } from "@/lib/hooks";
import { normCity, registerCities, type CityRes, type Candidate } from "@/lib/cities";
import { CityZoneDialog } from "@/components/CityZoneDialog";
import { StateSelect } from "@/components/StateSelect";
import { PageHead, appHead } from "@/components/PageHead";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

export const Route = createFileRoute("/_app/cities")({
  head: appHead("City & Zone Master", "Add cities, manage your zones, assign cities to zones and fix shipments waiting for a zone."),
  component: CitiesPage,
});

const sel = "h-9 rounded-md border bg-background px-2 text-sm";
const NEW_ZONE = "__new";
type City = { id: string; name: string; state: string | null; district: string | null; source: string };
type Mapping = { city_id: string; zone_id: string; cities: { name: string; state: string | null; district: string | null } | null };
const place = (c: { state: string | null; district?: string | null } | null | undefined) =>
  up([c?.district, c?.state].filter(Boolean).join(", ")) || "—";

function CitiesPage() {
  const qc = useQueryClient();
  const zonesQ = useZones();
  const zones = zonesQ.data ?? [];
  const [q, setQ] = useState("");
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const [mapPicked, setMapPicked] = useState<Set<string>>(new Set());
  const [bulkZone, setBulkZone] = useState("");
  const [moveZone, setMoveZone] = useState("");
  const [zoneFilter, setZoneFilter] = useState("");
  const [dialog, setDialog] = useState(false);
  const [newZone, setNewZone] = useState("");
  const [renaming, setRenaming] = useState<{ id: string; name: string } | null>(null);
  const [nc, setNc] = useState({ name: "", zone: "", state: "", district: "" });
  const [ncZoneName, setNcZoneName] = useState("");
  const [adv, setAdv] = useState(false);
  const [amb, setAmb] = useState<{ input: string; zoneId: string; candidates: Candidate[]; pick: string } | null>(null);
  const [busy, setBusy] = useState(false);

  const mappings = useQuery({
    queryKey: ["seller_city_zones"], retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.from("seller_city_zones").select("city_id, zone_id, cities(name, state, district)");
      if (error) throw error;
      return (data as unknown as Mapping[]).sort((a, b) => (a.cities?.name ?? "").localeCompare(b.cities?.name ?? ""));
    },
  });
  const review = useQuery({
    queryKey: ["review_cities"], retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.from("shipments").select("destination").eq("pricing_status", "needs_review").limit(5000);
      if (error) throw error;
      const counts = new Map<string, number>();
      for (const d of data) { const n = normCity(d.destination); if (n) counts.set(n, (counts.get(n) ?? 0) + 1); }
      const names = [...new Set(data.map((d) => (d.destination ?? "").trim()).filter(Boolean))];
      const res = names.length ? await registerCities(names) : new Map();
      const unmapped = [...res.values()].filter((r) => (r.status === "unmapped" && r.city_id) || r.status === "ambiguous");
      return { count: data.length, unmapped, counts };
    },
  });
  const search = useQuery({
    queryKey: ["cities", q], retry: false,
    queryFn: async () => {
      let req = supabase.from("cities").select("id, name, state, district, source").order("name").limit(100);
      const n = normCity(q);
      if (n) req = req.like("name_norm", `%${n.replace(/[%_]/g, "")}%`);
      const { data, error } = await req;
      if (error) throw error;
      return data as City[];
    },
  });
  // duplicate check while typing a new city
  const dupes = useQuery({
    queryKey: ["cities_dupe", normCity(nc.name)], retry: false, enabled: normCity(nc.name).length >= 2,
    queryFn: async () => {
      const { data, error } = await supabase.from("cities").select("id, name, state, district, source").eq("name_norm", normCity(nc.name)).limit(20);
      if (error) throw error;
      return data as City[];
    },
  });

  const zoneByCity = useMemo(() => new Map((mappings.data ?? []).map((m) => [m.city_id, m.zone_id])), [mappings.data]);
  const mapCount = useMemo(() => { const m = new Map<string, number>(); (mappings.data ?? []).forEach((x) => m.set(x.zone_id, (m.get(x.zone_id) ?? 0) + 1)); return m; }, [mappings.data]);
  const shownMappings = (mappings.data ?? []).filter((m) => !zoneFilter || m.zone_id === zoneFilter);
  const refresh = () => { ["seller_city_zones", "review_cities", "shipments", "zones", "cities", "cities_dupe"].forEach((k) => qc.invalidateQueries({ queryKey: [k] })); };
  const zoneName = (id?: string) => zones.find((z) => z.id === id)?.name;

  async function assign(cityIds: string[], zoneId: string) {
    if (!cityIds.length || !zoneId) return false;
    const { error } = await supabase.from("seller_city_zones")
      .upsert(cityIds.map((city_id) => ({ city_id, zone_id: zoneId, updated_at: new Date().toISOString() })), { onConflict: "owner_id,city_id" });
    if (error) { toast.error(errMsg(error)); return false; }
    toast.success(`${cityIds.length} ${cityIds.length === 1 ? "city" : "cities"} set to ${zoneName(zoneId) ?? "zone"}. Waiting shipments were re-priced.`);
    refresh(); return true;
  }
  async function unassign(cityIds: string[]) {
    if (!cityIds.length) return;
    const { error } = await supabase.from("seller_city_zones").delete().in("city_id", cityIds);
    if (error) { toast.error(errMsg(error)); return; }
    toast.success(`Removed ${cityIds.length} ${cityIds.length === 1 ? "city" : "cities"} from zones`);
    setMapPicked(new Set()); refresh();
  }

  async function createZone() {
    const name = newZone.trim();
    if (!name) return;
    setBusy(true);
    const { error } = await supabase.from("zones").insert({ name, sort_order: zones.length });
    setBusy(false);
    if (error) { toast.error(error.code === "23505" ? "A zone with this name already exists" : errMsg(error)); return; }
    setNewZone(""); toast.success(`Zone "${name}" created`); refresh();
  }
  async function renameZone() {
    if (!renaming) return;
    const name = renaming.name.trim();
    if (!name) return;
    const { error } = await supabase.from("zones").update({ name }).eq("id", renaming.id);
    if (error) { toast.error(error.code === "23505" ? "A zone with this name already exists" : errMsg(error)); return; }
    setRenaming(null); toast.success("Zone renamed"); refresh();
  }
  async function deleteZone(id: string, name: string) {
    const n = mapCount.get(id) ?? 0;
    if (!confirm(`Delete zone "${name}"?${n ? ` ${n} city assignment(s) will be removed and those cities will need a zone again.` : ""} Rates for this zone in your rate cards will no longer apply.`)) return;
    const { error } = await supabase.from("zones").delete().eq("id", id);
    if (error) { toast.error(errMsg(error)); return; }
    toast.success(`Zone "${name}" deleted`); if (zoneFilter === id) setZoneFilter(""); refresh();
  }

  const resetAdd = () => { setNc({ name: "", zone: "", state: "", district: "" }); setNcZoneName(""); setAmb(null); setAdv(false); };

  // Assigns a resolved city to the chosen zone (upsert on owner_id,city_id: moving never duplicates).
  async function finishAdd(cityId: string, label: string, zoneId: string) {
    const prev = zoneByCity.get(cityId);
    const { error } = await supabase.from("seller_city_zones")
      .upsert({ city_id: cityId, zone_id: zoneId, updated_at: new Date().toISOString() }, { onConflict: "owner_id,city_id" });
    if (error) throw error;
    const to = zoneName(zoneId) ?? "the zone";
    toast.success(prev && prev !== zoneId ? `${label} moved from ${zoneName(prev) ?? "another zone"} to ${to}` : `${label} assigned to ${to}. Waiting shipments were re-priced.`);
    setQ(label.split(",")[0] ?? ""); resetAdd(); refresh();
  }

  async function ensureZone(): Promise<string> {
    if (nc.zone !== NEW_ZONE) return nc.zone;
    const name = ncZoneName.trim();
    const { data, error } = await supabase.from("zones").insert({ name, sort_order: zones.length }).select("id").single();
    if (error) throw error.code === "23505" ? new Error("A zone with this name already exists") : error;
    setNc((p) => ({ ...p, zone: data.id })); setNcZoneName("");
    await qc.invalidateQueries({ queryKey: ["zones"] });
    return data.id as string;
  }

  async function addCity() {
    if (normCity(nc.name).length < 2) { toast.error("Enter a city name"); return; }
    if (!nc.zone) { toast.error("Choose your zone"); return; }
    if (nc.zone === NEW_ZONE && !ncZoneName.trim()) { toast.error("Enter the new zone name"); return; }
    if (adv && nc.district.trim() && !nc.state) { toast.error("Choose the state for this district"); return; }
    setBusy(true);
    try {
      const zoneId = await ensureZone();
      if (adv && nc.state) {
        const { data, error } = await supabase.rpc("add_city", { p_name: upName(nc.name), p_state: nc.state, p_district: nc.district.trim() || null });
        if (error) throw error;
        const r = (data as { city_id: string; existed: boolean; name: string; state: string; district: string | null }[])[0];
        if (!r) throw new Error("City could not be added");
        await finishAdd(r.city_id, [r.name, r.district, r.state].filter(Boolean).join(", "), zoneId);
        return;
      }
      const { data, error } = await supabase.rpc("register_cities", { p_names: [upName(nc.name)] });
      if (error) throw error;
      const r = (data as CityRes[])[0];
      if (!r) throw new Error("City could not be checked");
      if (r.status === "invalid") { toast.error(r.reason ?? "Not a valid city name"); return; }
      if (r.status === "ambiguous") {
        setAmb({ input: r.input, zoneId, candidates: r.candidates ?? [], pick: "" });
        toast.message("Several cities share this name — choose which one you mean");
        return;
      }
      if (!r.city_id) {
        // unknown city and no active plan: nothing could be registered
        toast.error("This city isn't in the list yet, and your plan is not active, so it can't be added. Renew your plan or pick an existing city.");
        return;
      }
      await finishAdd(r.city_id, [r.city_name ?? nc.name.trim(), r.state].filter(Boolean).join(", "), zoneId);
    } catch (e) { toast.error(errMsg(e)); } finally { setBusy(false); }
  }

  // Ambiguous name: explicit choice stored as the seller's own alias (seller_city_aliases), never guessed.
  async function confirmAmbiguous() {
    if (!amb?.pick) { toast.error("Choose which city you mean"); return; }
    const c = amb.candidates.find((k) => k.id === amb.pick);
    setBusy(true);
    try {
      const { error } = await supabase.from("seller_city_aliases")
        .upsert({ alias_norm: normCity(amb.input), city_id: amb.pick }, { onConflict: "owner_id,alias_norm" });
      if (error) throw error;
      await finishAdd(amb.pick, [c?.name ?? amb.input, c?.district, c?.state].filter(Boolean).join(", "), amb.zoneId);
    } catch (e) { toast.error(errMsg(e)); } finally { setBusy(false); }
  }

  const notReady = mappings.isError || search.isError;
  const toggle = (s: Set<string>, id: string, on: boolean) => { const n = new Set(s); if (on) n.add(id); else n.delete(id); return n; };

  return (
    <div className="space-y-6">
      <PageHead title="City & Zone Master" />
      {notReady && <p className="rounded-lg border border-destructive/40 bg-destructive/10 p-3 text-sm text-destructive">City management isn't available yet. Run the cities database update in Supabase, then reload.</p>}

      {/* Needs review */}
      <section className="rounded-xl border bg-card p-4">
        <div className="flex flex-wrap items-center gap-3">
          <h2 className="mr-auto font-semibold">Cities needing a zone</h2>
          <span className="text-sm text-muted-foreground">{review.data?.count ?? 0} shipments waiting · {review.data?.unmapped.length ?? 0} cities</span>
          <Button disabled={!review.data?.unmapped.length || !zones.length} onClick={() => setDialog(true)}>Assign zones</Button>
        </div>
        {!!review.data?.unmapped.length && (
          <ul className="mt-3 flex flex-wrap gap-2">
            {review.data.unmapped.slice(0, 60).map((r) => (
              <li key={r.input} className="rounded-full border px-3 py-1 text-xs">
                {up(r.input)}{r.status === "ambiguous" && <span className="text-destructive"> · confirm state</span>}
                <span className="text-muted-foreground"> · {review.data.counts.get(normCity(r.input)) ?? 0} shipments</span>
              </li>
            ))}
          </ul>
        )}
        <p className="mt-2 text-sm text-muted-foreground">Shipments are re-priced automatically as soon as their city gets a zone. Names that match cities in more than one state need you to confirm which one.</p>
      </section>

      <div className="grid gap-6 lg:grid-cols-2">
        {/* Zones */}
        <section className="rounded-xl border bg-card p-4">
          <h2 className="mb-3 font-semibold">My zones ({zones.length})</h2>
          <form className="mb-3 flex gap-2" onSubmit={(e) => { e.preventDefault(); createZone(); }}>
            <Input placeholder="New zone name, e.g. West" value={newZone} maxLength={60} onChange={(e) => setNewZone(e.target.value)} />
            <Button type="submit" disabled={busy || !newZone.trim()}>Create</Button>
          </form>
          <ul className="divide-y">
            {zones.map((z) => (
              <li key={z.id} className="flex flex-wrap items-center gap-2 py-2">
                {renaming?.id === z.id ? (
                  <form className="flex flex-1 gap-2" onSubmit={(e) => { e.preventDefault(); renameZone(); }}>
                    <Input autoFocus value={renaming.name} maxLength={60} onChange={(e) => setRenaming({ id: z.id, name: e.target.value })} />
                    <Button type="submit" size="sm">Save</Button>
                    <Button type="button" size="sm" variant="ghost" onClick={() => setRenaming(null)}>Cancel</Button>
                  </form>
                ) : (
                  <>
                    <button type="button" className="mr-auto text-left text-sm font-medium hover:underline" onClick={() => setZoneFilter(zoneFilter === z.id ? "" : z.id)}>
                      {z.name} <span className="font-normal text-muted-foreground">· {mapCount.get(z.id) ?? 0} cities</span>
                    </button>
                    <Button size="sm" variant="ghost" onClick={() => setRenaming({ id: z.id, name: z.name })}>Rename</Button>
                    <Button size="sm" variant="ghost" className="text-destructive" onClick={() => deleteZone(z.id, z.name)}>Delete</Button>
                  </>
                )}
              </li>
            ))}
            {!zones.length && !zonesQ.isLoading && <li className="py-3 text-sm text-muted-foreground">No zones yet. Create your first zone above.</li>}
          </ul>
        </section>

        {/* Add city */}
        <section className="rounded-xl border bg-card p-4">
          <h2 className="mb-3 font-semibold">Add a city</h2>
          <form className="grid gap-2 sm:grid-cols-2" onSubmit={(e) => { e.preventDefault(); addCity(); }}>
            <label className="grid gap-1 text-sm">City name *
              <CityInput placeholder="e.g. NASHIK" value={nc.name} required onChange={(name) => { setNc({ ...nc, name }); setAmb(null); }} />
            </label>
            <label className="grid gap-1 text-sm">My zone *
              <select className={`${sel} w-full`} value={nc.zone} required onChange={(e) => setNc({ ...nc, zone: e.target.value })}>
                <option value="">Choose zone…</option>
                {zones.map((z) => <option key={z.id} value={z.id}>{z.name}</option>)}
                <option value={NEW_ZONE}>+ New zone</option>
              </select>
            </label>
            {nc.zone === NEW_ZONE && (
              <Input className="sm:col-span-2" placeholder="New zone name, e.g. West" value={ncZoneName} maxLength={60} onChange={(e) => setNcZoneName(e.target.value)} />
            )}
            <div className="sm:col-span-2">
              <button type="button" className="text-xs text-muted-foreground underline" aria-expanded={adv} onClick={() => setAdv(!adv)}>
                {adv ? "▾" : "▸"} Advanced: State / District (optional)
              </button>
              {adv && (
                <div className="mt-2 grid gap-2 sm:grid-cols-2">
                  <StateSelect value={nc.state} onChange={(state) => setNc({ ...nc, state })} />
                  <Input placeholder="District (optional)" value={nc.district} maxLength={60} onChange={(e) => setNc({ ...nc, district: e.target.value })} />
                  <p className="text-xs text-muted-foreground sm:col-span-2">Only needed to tell apart cities with the same name.</p>
                </div>
              )}
            </div>
            <Button type="submit" className="sm:col-span-2" disabled={busy || !!amb}>{busy ? "Saving…" : "Add & assign"}</Button>
          </form>
          {amb && (
            <div className="mt-3 space-y-2 rounded-lg border border-destructive/40 p-2 text-sm">
              <p className="font-medium">"{amb.input}" matches several cities. Which one do you mean?</p>
              <select aria-label={`Which ${amb.input}`} className={`${sel} w-full`} value={amb.pick} onChange={(e) => setAmb({ ...amb, pick: e.target.value })}>
                <option value="">Choose…</option>
                {amb.candidates.map((k) => <option key={k.id} value={k.id}>{up(k.name)}{k.district ? `, ${up(k.district)}` : ""}{k.state ? `, ${up(k.state)}` : " (state unknown)"}</option>)}
              </select>
              <div className="flex gap-2">
                <Button size="sm" disabled={busy || !amb.pick} onClick={confirmAmbiguous}>Confirm & assign</Button>
                <Button size="sm" variant="ghost" onClick={() => setAmb(null)}>Cancel</Button>
              </div>
              <p className="text-xs text-muted-foreground">Your choice is remembered for your account only.</p>
            </div>
          )}
          {!!dupes.data?.length && (
            <div className="mt-3 rounded-lg border bg-muted/40 p-2 text-sm">
              <p className="mb-1 font-medium">Already in the city list:</p>
              <ul className="space-y-1">
                {dupes.data.map((c) => (
                  <li key={c.id} className="flex flex-wrap items-center gap-2">
                    <span className="mr-auto">{up(c.name)} <span className="text-muted-foreground">({place(c)})</span>{zoneByCity.has(c.id) && <span className="text-muted-foreground"> · {zoneName(zoneByCity.get(c.id))}</span>}</span>
                    {!zoneByCity.has(c.id) && zones.length > 0 && (
                      <select aria-label={`Zone for ${c.name}`} className={sel} defaultValue="" onChange={(e) => e.target.value && assign([c.id], e.target.value)}>
                        <option value="">Assign zone…</option>{zones.map((z) => <option key={z.id} value={z.id}>{z.name}</option>)}
                      </select>
                    )}
                  </li>
                ))}
              </ul>
              <p className="mt-1 text-xs text-muted-foreground">Only add it if your city is in a different state or district.</p>
            </div>
          )}
          <p className="mt-2 text-xs text-muted-foreground">Cities are shared by everyone using EntrySetu once checked. Your zones and assignments stay private to you.</p>
        </section>
      </div>

      {/* Assignments */}
      <section className="rounded-xl border bg-card p-4">
        <div className="mb-3 flex flex-wrap items-center gap-2">
          <h2 className="mr-auto font-semibold">My city assignments ({shownMappings.length})</h2>
          <select aria-label="Filter by zone" className={sel} value={zoneFilter} onChange={(e) => setZoneFilter(e.target.value)}>
            <option value="">All zones</option>{zones.map((z) => <option key={z.id} value={z.id}>{z.name}</option>)}
          </select>
          <select aria-label="Move selected to zone" className={sel} value={moveZone} onChange={(e) => setMoveZone(e.target.value)}>
            <option value="">Move selected to…</option>{zones.map((z) => <option key={z.id} value={z.id}>{z.name}</option>)}
          </select>
          <Button size="sm" disabled={!mapPicked.size || !moveZone} onClick={async () => { if (await assign([...mapPicked], moveZone)) setMapPicked(new Set()); }}>Move {mapPicked.size || ""}</Button>
          <Button size="sm" variant="outline" disabled={!mapPicked.size} onClick={() => unassign([...mapPicked])}>Remove {mapPicked.size || ""}</Button>
        </div>
        <div className="max-h-96 overflow-auto">
          <table className="w-full min-w-[480px] text-sm">
            <thead className="sticky top-0 bg-muted text-left"><tr>
              <th className="w-8 p-2"><input type="checkbox" aria-label="Select all" checked={!!shownMappings.length && shownMappings.every((m) => mapPicked.has(m.city_id))}
                onChange={(e) => setMapPicked(e.target.checked ? new Set(shownMappings.map((m) => m.city_id)) : new Set())} /></th>
              <th className="p-2">City</th><th className="p-2">District / State</th><th className="p-2">Zone</th><th /></tr></thead>
            <tbody>
              {shownMappings.map((m) => (
                <tr key={m.city_id} className="border-t">
                  <td className="p-2"><input type="checkbox" aria-label={`Select ${m.cities?.name}`} checked={mapPicked.has(m.city_id)} onChange={(e) => setMapPicked(toggle(mapPicked, m.city_id, e.target.checked))} /></td>
                  <td className="p-2">{m.cities?.name}</td><td className="p-2 text-muted-foreground">{place(m.cities)}</td>
                  <td className="p-2"><select aria-label={`Zone for ${m.cities?.name}`} className={sel} value={m.zone_id} onChange={(e) => assign([m.city_id], e.target.value)}>
                    {zones.map((z) => <option key={z.id} value={z.id}>{z.name}</option>)}
                  </select></td>
                  <td className="p-2 text-right"><Button size="sm" variant="ghost" onClick={() => unassign([m.city_id])}>Remove</Button></td>
                </tr>
              ))}
              {!shownMappings.length && <tr><td colSpan={5} className="p-4 text-center text-muted-foreground">No cities assigned yet.</td></tr>}
            </tbody>
          </table>
        </div>
      </section>

      {/* All cities */}
      <section className="rounded-xl border bg-card p-4">
        <div className="mb-3 flex flex-wrap items-center gap-2">
          <h2 className="mr-auto font-semibold">All cities</h2>
          <Input placeholder="Search city" className="w-full sm:w-52" value={q} onChange={(e) => setQ(e.target.value)} />
          <select aria-label="Zone for selected" className={sel} value={bulkZone} onChange={(e) => setBulkZone(e.target.value)}>
            <option value="">Zone for selected…</option>{zones.map((z) => <option key={z.id} value={z.id}>{z.name}</option>)}
          </select>
          <Button size="sm" disabled={!picked.size || !bulkZone} onClick={async () => { if (await assign([...picked], bulkZone)) setPicked(new Set()); }}>Assign {picked.size || ""}</Button>
        </div>
        <div className="max-h-[480px] overflow-auto">
          <table className="w-full min-w-[480px] text-sm">
            <thead className="sticky top-0 bg-muted text-left"><tr>
              <th className="w-8 p-2"><input type="checkbox" aria-label="Select all shown" checked={!!search.data?.length && search.data.every((c) => picked.has(c.id))}
                onChange={(e) => setPicked(e.target.checked ? new Set((search.data ?? []).map((c) => c.id)) : new Set())} /></th>
              <th className="p-2">City</th><th className="p-2">District / State</th><th className="p-2">My zone</th></tr></thead>
            <tbody>
              {(search.data ?? []).map((c) => (
                <tr key={c.id} className="border-t">
                  <td className="p-2"><input type="checkbox" aria-label={`Select ${c.name}`} checked={picked.has(c.id)} onChange={(e) => setPicked(toggle(picked, c.id, e.target.checked))} /></td>
                  <td className="p-2">{up(c.name)}{c.source === "user" && <span className="ml-2 text-xs text-muted-foreground">(added by sellers)</span>}</td>
                  <td className="p-2 text-muted-foreground">{place(c)}</td>
                  <td className="p-2">{zoneName(zoneByCity.get(c.id)) ?? <span className="text-muted-foreground">Not set</span>}</td>
                </tr>
              ))}
              {!search.data?.length && <tr><td colSpan={4} className="p-4 text-center text-muted-foreground">No cities found. Add it above.</td></tr>}
            </tbody>
          </table>
        </div>
        <p className="mt-2 text-xs text-muted-foreground">Showing up to 100 cities — search to narrow down.</p>
      </section>

      <CityZoneDialog open={dialog} items={review.data?.unmapped ?? []} zones={zones} onClose={() => setDialog(false)} onSaved={() => { setDialog(false); refresh(); }} />
    </div>
  );
}
