import { up, upName, nameKey } from "@/lib/text";
import { createFileRoute, Link } from "@tanstack/react-router";
import { useEffect, useMemo, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import * as XLSX from "xlsx";
import { supabase, inr } from "@/lib/supabase";
import { useClients, useRateSlabs, useZones, errMsg } from "@/lib/hooks";
import { matchRate, normService, billedWeight } from "@/lib/rates";
import { normCity, registerCities, zoneOf, type CityRes } from "@/lib/cities";
import { CityZoneDialog } from "@/components/CityZoneDialog";
import { PageHead, appHead } from "@/components/PageHead";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import {
  FIELD_LABELS, REQUIRED, billingWeight, colLetter, detectMapping, fmtWeight, parseType, parseWeight, toKg, unitOf,
  type FieldKey, type Mapping, type ShipmentType,
} from "@/lib/import-weights";

export const Route = createFileRoute("/_app/import")({
  head: appHead("Excel import", "Upload courier booking sheets, map columns and turn them into shipments."),
  component: ImportPage,
});

type Row = {
  line: number; awb: string; date: string; client: string; destination: string; service: string; pieces: number;
  type: ShipmentType | null; weights: (number | null)[]; billing: number | null; amount: number | null; error?: string; dup?: "file" | "saved";
  priced?: { rate: number; zone: string | null; slab: string }; review?: string;
};
type SavedMap = { id: string; name: string; mapping: Mapping };

function toISO(v: unknown): string | null {
  if (v instanceof Date && !isNaN(+v)) return new Date(v.getTime() - v.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
  if (typeof v === "number") { const d = XLSX.SSF.parse_date_code(v); if (d) return `${d.y}-${String(d.m).padStart(2, "0")}-${String(d.d).padStart(2, "0")}`; }
  const s = String(v ?? "").trim();
  const m = s.match(/^(\d{1,2})[-/.](\d{1,2})[-/.](\d{2,4})$/);
  if (m) { const y = m[3]!.length === 2 ? "20" + m[3] : m[3]; return `${y}-${m[2]!.padStart(2, "0")}-${m[1]!.padStart(2, "0")}`; }
  if (/^\d{4}-\d{2}-\d{2}/.test(s)) return s.slice(0, 10);
  return null;
}

function ImportPage() {
  const { data: clients = [] } = useClients();
  const { data: slabs = [] } = useRateSlabs();
  const { data: zones = [] } = useZones();
  const qc = useQueryClient();
  const [sheet, setSheet] = useState<unknown[][] | null>(null);
  const [headerRow, setHeaderRow] = useState(0);
  const [map, setMap] = useState<Mapping | null>(null);
  const [existing, setExisting] = useState<Set<string>>(new Set());
  const [createClients, setCreateClients] = useState(true);
  const [busy, setBusy] = useState(false);
  const [mapName, setMapName] = useState("");
  const [cityMap, setCityMap] = useState<Map<string, CityRes> | null>(null);
  const [cityTick, setCityTick] = useState(0);
  const [dialog, setDialog] = useState(false);
  const [autoOpened, setAutoOpened] = useState(false);
  const [skipped, setSkipped] = useState(false);

  const saved = useQuery({
    queryKey: ["import_mappings"],
    queryFn: async () => {
      const { data, error } = await supabase.from("import_mappings").select("id, name, mapping").order("name");
      if (error) throw error;
      return data as SavedMap[];
    },
    retry: false,
  });

  const headers = sheet?.[headerRow] ?? [];
  const width = Math.max(0, ...(sheet ?? []).slice(0, 50).map((r) => r.length));

  async function onFile(file: File) {
    try {
      const wb = XLSX.read(await file.arrayBuffer(), { cellDates: true });
      const aoa = XLSX.utils.sheet_to_json<unknown[]>(wb.Sheets[wb.SheetNames[0]!]!, { header: 1, defval: "", blankrows: false });
      if (aoa.length < 2) { toast.error("Sheet has no data rows"); return; }
      // header row = first row (within 10) with at least 3 text cells
      const hr = Math.max(0, aoa.slice(0, 10).findIndex((r) => r.filter((c) => typeof c === "string" && c.trim()).length >= 3));
      setSheet(aoa); setHeaderRow(hr); setMap(detectMapping(aoa[hr] ?? []));
      // existing AWBs for this tenant (RLS limits to own rows)
      const awbs = new Set<string>();
      for (let from = 0; ; from += 1000) {
        const { data, error } = await supabase.from("shipments").select("awb").range(from, from + 999);
        if (error) throw error;
        data.forEach((d) => awbs.add(String(d.awb).trim().toLowerCase()));
        if (data.length < 1000) break;
      }
      setExisting(awbs);
    } catch (e) { toast.error(errMsg(e)); }
  }

  const destKey = useMemo(() => {
    if (!sheet || !map || map.destination == null) return "";
    return [...new Set(sheet.slice(headerRow + 1).map((r) => String(r[map.destination!] ?? "").trim()).filter(Boolean))].join("\n");
  }, [sheet, map, headerRow]);
  useEffect(() => {
    setSkipped(false);
    if (!destKey) { setCityMap(new Map()); return; }
    let live = true;
    setCityMap(null);
    registerCities(destKey.split("\n")).then((m) => live && setCityMap(m)).catch((e) => { toast.error(errMsg(e)); if (live) setCityMap(new Map()); });
    return () => { live = false; };
  }, [destKey, cityTick]);
  const unmapped = useMemo(() => [...(cityMap?.values() ?? [])].filter((r) => (r.status === "unmapped" && r.city_id) || r.status === "ambiguous"), [cityMap]);
  useEffect(() => { if (unmapped.length && !autoOpened) { setDialog(true); setAutoOpened(true); } }, [unmapped, autoOpened]);

  const clientIds = useMemo(() => new Map(clients.map((c) => [nameKey(c.name), c.id])), [clients]);
  const rows: Row[] = useMemo(() => {
    if (!sheet || !map) return [];
    const get = (r: unknown[], k: FieldKey) => (map[k] == null ? "" : r[map[k]!]);
    const seen = new Set<string>();
    const out: Row[] = [];
    sheet.slice(headerRow + 1).forEach((r, i) => {
      if (!r.some((c) => String(c ?? "").trim())) return;
      const awb = String(get(r, "awb") ?? "").trim();
      const client = String(get(r, "client") ?? "").trim();
      const type = parseType(get(r, "type"));
      const weights = (["w1", "w2", "w3", "w4"] as FieldKey[]).map((k) => parseWeight(get(r, k)));
      const billing = billingWeight(weights);
      const date = map.date == null ? null : toISO(get(r, "date"));
      const amtRaw = get(r, "amount");
      const row: Row = {
        line: headerRow + i + 2, awb, client, type, weights, billing, date: date ?? "",
        destination: String(get(r, "destination") ?? "").trim(),
        service: normService(get(r, "service")),
        pieces: Math.max(1, Math.round(Number(get(r, "pieces")) || 1)),
        amount: amtRaw !== "" && amtRaw != null && Number.isFinite(Number(amtRaw)) ? Number(amtRaw) : null,
      };
      if (!awb) row.error = "Missing AWB";
      else if (!client) row.error = "Missing client";
      else if (!type) row.error = "Unknown shipment type (need DOX or NON-DOX)";
      else if (billing == null) row.error = "No valid weight in mapped weight columns";
      else if (!date) row.error = map.date == null ? "Map a shipment date column" : "Invalid date";
      const key = awb.toLowerCase();
      if (awb) {
        if (existing.has(key)) row.dup = "saved";
        else if (seen.has(key)) row.dup = "file";
        seen.add(key);
      }
      if (!row.error && !row.dup) {
        const clientId = clientIds.get(nameKey(client)) ?? null;
        const city = cityMap?.get(normCity(row.destination));
        const z = !row.destination ? { zone: null, zoneReason: "No destination city" } : cityMap ? zoneOf(city) : { zone: null, zoneReason: "Checking city…" };
        const res = matchRate(slabs, { clientId, type: type!, service: row.service as "Standard" | "Fast", ...z, weight: billing! });
        if (res.ok) row.priced = { rate: res.rate, zone: res.zone, slab: res.slab };
        else row.review = res.reason;   // no zone-less fallback for typed shipments (mirrors shipment_rate)
      }
      out.push(row);
    });
    return out;
  }, [sheet, map, headerRow, existing, slabs, clientIds, cityMap]);

  const importable = rows.filter((r) => !r.error && !r.dup);
  const valid = importable.filter((r) => !r.review);
  const review = rows.filter((r) => r.review).length;
  const dups = rows.filter((r) => r.dup).length;
  const errors = rows.filter((r) => r.error).length;
  const dox = valid.filter((r) => r.type === "DOX").length;
  const missingReq = REQUIRED.filter((k) => map?.[k] == null);

  async function saveMapping() {
    if (!map || !mapName.trim()) { toast.error("Enter a name for this mapping"); return; }
    const { error } = await supabase.from("import_mappings").upsert({ name: mapName.trim(), mapping: map, updated_at: new Date().toISOString() }, { onConflict: "owner_id,name" });
    if (error) { toast.error(errMsg(error)); return; }
    toast.success("Mapping saved"); saved.refetch();
  }

  async function process() {
    // Unassigned cities must be assigned or explicitly skipped before importing.
    if (unmapped.length && !skipped) { setDialog(true); return; }
    setBusy(true);
    try {
      // Existing clients are matched ignoring case/spacing and their IDs reused; new ones are saved in UPPERCASE.
      const byName = new Map(clients.map((c) => [nameKey(c.name), c.id]));
      const missing = [...new Map(importable.filter((r) => !byName.has(nameKey(r.client))).map((r) => [nameKey(r.client), upName(r.client)])).values()];
      if (missing.length) {
        if (!createClients) throw new Error(`Unknown clients: ${missing.slice(0, 5).join(", ")}${missing.length > 5 ? "…" : ""}`);
        const { data, error } = await supabase.from("clients").insert(missing.map((name) => ({ name }))).select("id, name");
        if (error) throw error;
        data!.forEach((c) => byName.set(nameKey(c.name), c.id));
      }
      const out = [];
      for (const r of importable) {
        const t = r.type!; const kg = toKg(t, billedWeight(t, r.billing!));
        const cid = byName.get(nameKey(r.client))!;
        const amount = r.priced?.rate ?? 0; // the database re-prices (or flags Needs Review) and overrides this
        const [f, g, h, tt] = r.weights;
        out.push({
          awb: r.awb, client_id: cid, ship_date: r.date, destination: r.destination ? upName(r.destination) : null, service: r.service, pieces: r.pieces, amount,
          weight: +kg.toFixed(3), shipment_type: t, // weight_unit + billing_weight are generated by the database
          weight_f: f, weight_g: g, weight_h: h, weight_t: tt,
                  });
      }
      let inserted = 0;
      for (let i = 0; i < out.length; i += 500) {
        const { data, error } = await supabase.from("shipments").upsert(out.slice(i, i + 500), { onConflict: "owner_id,awb", ignoreDuplicates: true }).select("id");
        if (error) throw error;
        inserted += data?.length || 0;
      }
      toast.success(`${inserted} shipments added${review ? ` (${review} marked Needs Review)` : ""}. Skipped: ${dups + out.length - inserted} duplicates, ${errors} invalid rows.`);
      setSheet(null); setMap(null); setAutoOpened(false); setSkipped(false);
      qc.invalidateQueries();
    } catch (e) {
      toast.error(errMsg(e));
    } finally { setBusy(false); }
  }

  function template() {
    const head = Array.from({ length: 20 }, () => "");
    ["AWB", "Date", "Client", "Type", "Destination", "Weight 1", "Weight 2", "Weight 3", "Service", "Pieces"].forEach((h, i) => (head[i] = h));
    head[19] = "Weight 4";
    const ws = XLSX.utils.aoa_to_sheet([head]);
    const wb = XLSX.utils.book_new(); XLSX.utils.book_append_sheet(wb, ws, "Bookings");
    XLSX.writeFile(wb, "entrysetu-template.xlsx");
  }

  const colOptions = Array.from({ length: width }, (_, i) => ({ i, label: `${colLetter(i)} · ${String(headers[i] ?? "").trim() || "(no header)"}` }));
  const total = valid.reduce((a, r) => a + (r.priced?.rate ?? 0), 0);

  return (
    <div>
      <PageHead title="Excel import"><Button variant="outline" onClick={template}>Download template</Button></PageHead>
      <div className="rounded-xl border-2 border-dashed bg-card p-8 text-center">
        <p className="mb-3 text-sm text-muted-foreground">Upload any courier .xlsx, .xls or .csv sheet. You can match its columns below. Weights are read from columns F, G, H and T by default: grams for DOX, kilograms for NON-DOX. The highest one is the billing weight. Prices come from your <Link to="/rate-cards" className="text-primary underline">rate cards</Link> using the zone you set for each destination city.</p>
        <input type="file" accept=".xlsx,.xls,.csv" onChange={(e) => { const f = e.target.files?.[0]; if (f) onFile(f); e.target.value = ""; }} className="mx-auto block text-sm" />
      </div>

      {sheet && map && (
        <div className="mt-6 space-y-6">
          <section className="rounded-xl border bg-card p-4">
            <div className="mb-3 flex flex-wrap items-end gap-3">
              <h2 className="mr-auto font-semibold">Column mapping</h2>
              <label className="text-sm">Header row
                <Input type="number" min={1} max={20} className="ml-2 inline-block w-20" value={headerRow + 1} onChange={(e) => { const v = Math.max(0, Math.min(sheet.length - 2, (+e.target.value || 1) - 1)); setHeaderRow(v); }} />
              </label>
              {saved.data && saved.data.length > 0 && (
                <select className="h-9 rounded-md border bg-background px-2 text-sm" defaultValue="" onChange={(e) => { const s = saved.data!.find((m) => m.id === e.target.value); if (s) { setMap({ ...detectMapping([]), ...s.mapping }); setMapName(s.name); } }}>
                  <option value="">Load saved mapping…</option>{saved.data.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}
                </select>
              )}
              <Input placeholder="Mapping name" className="w-44" value={mapName} onChange={(e) => setMapName(e.target.value)} />
              <Button variant="outline" onClick={saveMapping} disabled={saved.isError}>Save mapping</Button>
            </div>
            {saved.isError && <p className="mb-3 text-sm text-destructive">Saved mappings aren't available yet. Run the database update for import weights first.</p>}
            <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
              {(Object.keys(FIELD_LABELS) as FieldKey[]).map((k) => (
                <label key={k} className="text-sm">
                  <span className="mb-1 block">{FIELD_LABELS[k]}{REQUIRED.includes(k) && " *"}</span>
                  <select className="h-9 w-full rounded-md border bg-background px-2 text-sm" value={map[k] ?? ""} onChange={(e) => setMap({ ...map, [k]: e.target.value === "" ? null : +e.target.value })}>
                    <option value="">— not in sheet —</option>
                    {colOptions.map((o) => <option key={o.i} value={o.i}>{o.label}</option>)}
                  </select>
                </label>
              ))}
            </div>
          </section>

          <section>
            <div className="mb-3 grid grid-cols-2 gap-3 text-sm sm:grid-cols-3 lg:grid-cols-6">
              {[["Total rows", rows.length], ["Priced (new)", valid.length], ["Duplicate AWBs", dups], ["Rows with errors", errors], ["Will import as Needs Review", review], ["DOX / NON-DOX", `${dox} / ${valid.length - dox}`]].map(([l, v]) => (
                <div key={l} className="rounded-lg border bg-card p-3"><div className="text-muted-foreground">{l}</div><div className="text-lg font-semibold">{v}</div></div>
              ))}
            </div>
            <div className="mb-3 flex flex-wrap items-center justify-between gap-3">
              <div className="text-sm">Total for valid rows: {inr(total)}</div>
              <label className="flex items-center gap-2 text-sm"><Switch checked={createClients} onCheckedChange={setCreateClients} />Create new clients from sheet names</label>
              {unmapped.length > 0 && <Button variant="outline" onClick={() => setDialog(true)}>Assign zones ({unmapped.length} {unmapped.length === 1 ? "city" : "cities"})</Button>}
              <Button onClick={process} disabled={busy || !importable.length || missingReq.length > 0 || cityMap === null}>{busy ? "Importing…" : cityMap === null ? "Checking cities…" : `Import ${importable.length} shipments`}</Button>
            </div>
            {missingReq.length > 0 && <p className="mb-3 text-sm text-destructive">Map these columns first: {missingReq.map((k) => FIELD_LABELS[k]).join(", ")}</p>}
            <div className="max-h-[520px] overflow-auto rounded-xl border bg-card">
              <table className="w-full text-sm">
                <thead className="sticky top-0 bg-muted text-left"><tr>
                  {["Row", "AWB", "Date", "Client", "Type", "F", "G", "H", "T", "Billing wt", "Service", "Dest.", "Rate applied", "Status"].map((h) => <th key={h} className="p-2">{h}</th>)}
                </tr></thead>
                <tbody>{rows.slice(0, 500).map((r) => (
                  <tr key={r.line} className="border-t">
                    <td className="p-2 text-muted-foreground">{r.line}</td><td className="p-2 font-mono">{r.awb}</td><td className="p-2">{r.date}</td><td className="p-2">{r.client}</td>
                    <td className="p-2">{r.type ?? "—"}</td>
                    {r.weights.map((w, j) => <td key={j} className="p-2">{w ?? ""}</td>)}
                    <td className="p-2 font-medium">{r.type && r.billing != null ? fmtWeight(r.type, r.billing) : "—"}</td>
                    <td className="p-2">{r.service}</td><td className="p-2">{up(r.destination)}</td>
                    <td className="p-2 whitespace-nowrap">{r.priced ? `${inr(r.priced.rate)} · ${[r.priced.zone, r.priced.slab].filter(Boolean).join(" · ")}` : "—"}{r.amount != null && r.priced && r.amount !== r.priced.rate ? <span className="block text-xs text-muted-foreground">sheet: {inr(r.amount)}</span> : null}</td>
                    <td className="p-2">{r.error ? <span className="text-destructive">{r.error}</span> : r.review ? <span className="text-destructive">Needs review: {r.review}</span> : r.dup ? <span className="text-muted-foreground">{r.dup === "saved" ? "Duplicate (already imported)" : "Duplicate in file"}</span> : "OK"}</td>
                  </tr>
                ))}</tbody>
              </table>
              {rows.length > 500 && <p className="p-2 text-center text-xs text-muted-foreground">Showing first 500 of {rows.length} rows; all rows will be imported.</p>}
            </div>
          </section>
        </div>
      )}
      <CityZoneDialog open={dialog} items={unmapped} zones={zones} onClose={() => setDialog(false)}
        onSkip={() => { setSkipped(true); setDialog(false); toast.info(`${unmapped.length} ${unmapped.length === 1 ? "city" : "cities"} skipped — those shipments will import as Needs Review at ₹0.`); }}
        onSaved={() => { setDialog(false); setCityTick((t) => t + 1); qc.invalidateQueries({ queryKey: ["zones"] }); }} />
    </div>
  );
}
