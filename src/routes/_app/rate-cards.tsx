import { up } from "@/lib/text";
import { createFileRoute, Link } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { supabase, inr } from "@/lib/supabase";
import { useClients, useRateCards, useRateSlabs, useZones, errMsg } from "@/lib/hooks";
import { SERVICES, servicesFor, validateSlabs, type EditSlab, type Service, type Zone } from "@/lib/rates";
import type { ShipmentType } from "@/lib/import-weights";
import { PageHead, appHead } from "@/components/PageHead";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

export const Route = createFileRoute("/_app/rate-cards")({
  head: appHead("Rate cards", "Client-wise DOX and NON-DOX weight slabs with zone-wise rates."),
  component: RateCards,
});

const sel = "h-9 rounded-md border bg-background px-2 text-sm";
let keySeq = 0;
const newKey = () => `k${++keySeq}`;

function RateCards() {
  const { data: clients = [] } = useClients();
  const zonesQ = useZones();
  const slabsQ = useRateSlabs();
  const { data: legacy = [] } = useRateCards();
  const qc = useQueryClient();
  const zones = zonesQ.data ?? [];
  const [clientId, setClientId] = useState("");
  const [type, setType] = useState<ShipmentType>("DOX");
  const [draft, setDraft] = useState<Record<Service, EditSlab[]>>({ Standard: [], Surface: [], Air: [], Fast: [] });
  const [dirty, setDirty] = useState(false);
  const [saving, setSaving] = useState(false);
  const [copyTo, setCopyTo] = useState("");
  const unit = type === "DOX" ? "g" : "kg";
  const cid = clientId || null;
  const services = servicesFor(type);

  useEffect(() => {
    const all = slabsQ.data ?? [];
    const d = {} as Record<Service, EditSlab[]>;
    for (const sv of SERVICES)
      d[sv] = all.filter((s) => s.client_id === cid && s.shipment_type === type && s.service === sv)
        .sort((a, b) => a.sort_order - b.sort_order)
        .map((s) => ({ key: newKey(), min: String(s.min_weight), max: String(s.max_weight), rates: Object.fromEntries(Object.entries(s.rates).map(([k, v]) => [k, String(v)])) }));
    setDraft(d); setDirty(false);
  }, [cid, type, slabsQ.dataUpdatedAt]); // eslint-disable-line react-hooks/exhaustive-deps

  const setRows = (sv: Service, rows: EditSlab[]) => { setDraft({ ...draft, [sv]: rows }); setDirty(true); };
  const errors = Object.fromEntries(SERVICES.map((sv) => [sv, validateSlabs(draft[sv], unit)])) as Record<Service, string[]>;
  const hasErrors = services.some((sv) => errors[sv].length);

  function switchTo(fn: () => void) {
    if (dirty && !window.confirm("You have unsaved changes. Discard them?")) return;
    fn();
  }

  async function save() {
    if (hasErrors) { toast.error("Fix the highlighted problems first"); return; }
    setSaving(true);
    try {
      for (const sv of services) {
        const slabs = draft[sv].map((s) => ({
          min_weight: Number(s.min), max_weight: Number(s.max),
          rates: Object.fromEntries(Object.entries(s.rates).filter(([z, v]) => v.trim() !== "" && zones.some((x) => x.id === z)).map(([z, v]) => [z, Number(v)])),
        }));
        const { error } = await supabase.rpc("save_rate_card", { p_client: cid, p_type: type, p_service: sv, p_slabs: slabs });
        if (error) throw error;
      }
      toast.success("Rate card saved");
      await qc.invalidateQueries({ queryKey: ["rate_slabs"] });
    } catch (e) { toast.error(errMsg(e)); } finally { setSaving(false); }
  }

  async function copy() {
    if (dirty) { toast.error("Save your changes before copying"); return; }
    const to = copyTo === "__default" ? null : copyTo;
    const name = to ? clients.find((c) => c.id === to)?.name : "Default (all clients)";
    let { error } = await supabase.rpc("copy_rate_cards", { p_from: cid, p_to: to, p_replace: false });
    if (error?.message?.includes("TARGET_HAS_RATES")) {
      if (!window.confirm(`${name} already has rates. Replace ALL of its DOX and NON-DOX rates with these?`)) return;
      ({ error } = await supabase.rpc("copy_rate_cards", { p_from: cid, p_to: to, p_replace: true }));
    }
    if (error) { toast.error(errMsg(error)); return; }
    toast.success(`Rates copied to ${name}`); setCopyTo("");
    qc.invalidateQueries({ queryKey: ["rate_slabs"] });
  }

  async function delLegacy(id: string) {
    const { error } = await supabase.from("rate_cards").delete().eq("id", id);
    if (error) { toast.error(errMsg(error)); return; }
    qc.invalidateQueries({ queryKey: ["rate_cards"] });
  }

  // Only a genuinely missing table/function counts as "setup needed"; other errors are shown as-is.
  const missing = (e: unknown) => { const x = e as { code?: string; message?: string } | null; return !!x && (x.code === "42P01" || x.code === "PGRST205" || x.code === "PGRST202" || /does not exist|schema cache/i.test(x.message ?? "")); };
  const setupMissing = missing(zonesQ.error) || missing(slabsQ.error);
  const loadError = !setupMissing && (zonesQ.error || slabsQ.error);
  const notReady = zonesQ.isError || slabsQ.isError;

  return (
    <div>
      <PageHead title="Rate cards" />
      {setupMissing && <p className="mb-4 rounded-lg border border-destructive/40 bg-destructive/10 p-3 text-sm text-destructive">Database setup needed: the rate card tables are missing in your Supabase project. Run the rate card and cities database updates in the Supabase SQL Editor, then reload.</p>}
      {loadError && <p className="mb-4 rounded-lg border border-destructive/40 bg-destructive/10 p-3 text-sm text-destructive">Couldn't load rate cards: {errMsg(loadError)}</p>}
      <p className="mb-4 text-sm text-muted-foreground">Zone columns come from your <Link to="/cities" className="text-primary underline">City & Zone Master</Link>. Create, rename or delete zones and assign cities there.</p>

      <section className="rounded-xl border bg-card p-4">
        <div className="mb-4 flex flex-wrap items-center gap-3">
          <select className={`${sel} min-w-52`} value={clientId} onChange={(e) => { const v = e.target.value; switchTo(() => setClientId(v)); }}>
            <option value="">Default (all clients)</option>
            {clients.map((c) => <option key={c.id} value={c.id}>{up(c.name)}</option>)}
          </select>
          <div className="inline-flex rounded-md border p-0.5" role="tablist">
            {(["DOX", "NON-DOX"] as ShipmentType[]).map((t) => (
              <button key={t} role="tab" aria-selected={type === t} onClick={() => switchTo(() => setType(t))}
                className={`rounded px-4 py-1.5 text-sm font-medium ${type === t ? "bg-primary text-primary-foreground" : "text-muted-foreground"}`}>{t} <span className="text-xs opacity-75">({t === "DOX" ? "g" : "kg"})</span></button>
            ))}
          </div>
          <div className="ml-auto flex flex-wrap items-center gap-2">
            <select className={sel} value={copyTo} onChange={(e) => setCopyTo(e.target.value)} disabled={notReady}>
              <option value="">Copy these rates to…</option>
              {clientId && <option value="__default">Default (all clients)</option>}
              {clients.filter((c) => c.id !== clientId).map((c) => <option key={c.id} value={c.id}>{up(c.name)}</option>)}
            </select>
            <Button variant="outline" onClick={copy} disabled={!copyTo || notReady}>Copy</Button>
          </div>
        </div>
        <p className="mb-4 text-sm text-muted-foreground">Client rates are used first; if a client has none for a type and service, the Default card applies. Shipments with no matching slab, zone or rate are flagged for review, never charged ₹0.</p>
        {!zones.length && !notReady && <p className="mb-4 text-sm text-destructive">You have no zones yet. Create them in <Link to="/cities" className="underline">City & Zone Master</Link> to enter rates.</p>}

        {services.map((sv) => <SlabTable key={sv} service={sv} unit={unit} zones={zones} rows={draft[sv]} errors={errors[sv]} onChange={(r) => setRows(sv, r)} />)}
        {type === "NON-DOX" && draft.Standard.length > 0 && <SlabTable service="Standard" unit={unit} zones={zones} rows={draft.Standard} errors={[]} onChange={() => {}} readOnly />}

        <div className="sticky bottom-0 mt-4 flex items-center justify-end gap-3 border-t bg-card pt-3">
          {dirty && <span className="text-sm text-muted-foreground">Unsaved changes</span>}
          <Button onClick={save} disabled={!dirty || saving || hasErrors || notReady}>{saving ? "Saving…" : "Save changes"}</Button>
        </div>
      </section>

      {legacy.length > 0 && (
        <section className="mt-8">
          <h2 className="mb-2 font-semibold">Older slabs (kg, no zones)</h2>
          <p className="mb-3 text-sm text-muted-foreground">Kept for reference only — new shipments are priced from zone-wise cards. You can delete these once your zone-wise cards are set up.</p>
          <div className="overflow-x-auto rounded-xl border bg-card">
            <table className="w-full text-sm">
              <thead className="bg-muted text-left"><tr><th className="p-3">Applies to</th><th className="p-3">Service</th><th className="p-3">Weight (kg)</th><th className="p-3">Rate</th><th className="p-3">Extra/kg</th><th /></tr></thead>
              <tbody>{legacy.map((c) => (
                <tr key={c.id} className="border-t"><td className="p-3">{c.client_id ? clients.find((x) => x.id === c.client_id)?.name : "Default"}</td><td className="p-3">{c.service}</td><td className="p-3">{c.min_weight} – {c.max_weight}</td><td className="p-3">{inr(c.rate)}</td><td className="p-3">{inr(c.extra_per_kg)}</td>
                  <td className="p-3 text-right"><Button size="sm" variant="ghost" onClick={() => delLegacy(c.id)}>Delete</Button></td></tr>
              ))}</tbody>
            </table>
          </div>
        </section>
      )}
    </div>
  );
}

function SlabTable({ service, unit, zones, rows, errors, onChange, readOnly = false }: { service: Service; unit: string; zones: Zone[]; rows: EditSlab[]; errors: string[]; onChange: (r: EditSlab[]) => void; readOnly?: boolean }) {
  const upd = (i: number, p: Partial<EditSlab>) => onChange(rows.map((r, j) => (j === i ? { ...r, ...p } : r)));
  const move = (i: number, d: number) => { const r = [...rows]; const [x] = r.splice(i, 1); r.splice(i + d, 0, x!); onChange(r); };
  const add = () => { const last = rows[rows.length - 1]; onChange([...rows, { key: newKey(), min: last ? last.max : "0", max: "", rates: {} }]); };
  return (
    <div className="mb-6">
      <div className="mb-2 flex items-center justify-between">
        <h3 className="font-semibold">{service}{readOnly ? " (legacy, read-only)" : ""}</h3>
        {!readOnly && <Button size="sm" variant="outline" onClick={add}>+ Add slab</Button>}
      </div>
      <fieldset disabled={readOnly} className="overflow-x-auto rounded-lg border">
        <table className="w-full text-sm">
          <thead className="bg-muted text-left"><tr>
            <th className="p-2">From ({unit})</th><th className="p-2">To ({unit})</th>
            {zones.map((z) => <th key={z.id} className="p-2 whitespace-nowrap">{z.name} ₹</th>)}
            <th className="p-2" />
          </tr></thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={r.key} className="border-t">
                <td className="p-1.5"><Input aria-label="From" type="number" min={0} step="any" className="w-24" value={r.min} onChange={(e) => upd(i, { min: e.target.value })} /></td>
                <td className="p-1.5"><Input aria-label="To" type="number" min={0} step="any" className="w-24" value={r.max} onChange={(e) => upd(i, { max: e.target.value })} /></td>
                {zones.map((z) => <td key={z.id} className="p-1.5"><Input aria-label={`${z.name} rate`} type="number" min={0} step="0.01" className="w-24" placeholder="—" value={r.rates[z.id] ?? ""} onChange={(e) => upd(i, { rates: { ...r.rates, [z.id]: e.target.value } })} /></td>)}
                <td className="whitespace-nowrap p-1.5 text-right">{!readOnly && <>
                  <Button size="sm" variant="ghost" aria-label="Move up" disabled={i === 0} onClick={() => move(i, -1)}>↑</Button>
                  <Button size="sm" variant="ghost" aria-label="Move down" disabled={i === rows.length - 1} onClick={() => move(i, 1)}>↓</Button>
                  <Button size="sm" variant="ghost" onClick={() => onChange([...rows.slice(0, i + 1), { ...r, key: newKey(), rates: { ...r.rates } }, ...rows.slice(i + 1)])}>Duplicate</Button>
                  <Button size="sm" variant="ghost" onClick={() => onChange(rows.filter((_, j) => j !== i))}>Delete</Button>
                </>}</td>
              </tr>
            ))}
            {!rows.length && <tr><td colSpan={zones.length + 3} className="p-4 text-center text-muted-foreground">No slabs. Click "Add slab".</td></tr>}
          </tbody>
        </table>
      </fieldset>
      {errors.length > 0 && <ul className="mt-2 list-disc pl-5 text-sm text-destructive">{errors.map((e) => <li key={e}>{e}</li>)}</ul>}
    </div>
  );
}
