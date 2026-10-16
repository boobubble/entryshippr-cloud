import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useMemo, useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { ChevronLeft, ChevronRight, PanelLeftClose, PanelLeftOpen } from "lucide-react";
import { supabase, inr } from "@/lib/supabase";
import { useClients, useZones, errMsg } from "@/lib/hooks";
import { normCity, registerCities, type CityRes } from "@/lib/cities";
import { billedWeight } from "@/lib/rates";
import { up, upName } from "@/lib/text";
import { CityZoneDialog } from "@/components/CityZoneDialog";
import { appHead } from "@/components/PageHead";
import { Button } from "@/components/ui/button";
import { getSidebarCollapsed, setSidebarCollapsed, useSidebarCollapsed } from "@/lib/sidebar";

export const Route = createFileRoute("/_app/entry")({
  head: appHead("Consignment entry", "Fast keyboard-driven manual consignment entry."),
  component: Entry,
});

type Opt = { key: string; label: string; sub?: string | undefined };
type Saved = { id: string; awb: string; ship_date: string; destination: string | null; service: string; weight: number; amount: number; pricing_status?: string; review_reason?: string | null; shipment_type?: string | null; charge_mode?: string | null; clients: { name: string } | null };
type Draft = { awb: string; client_id: string; date: string; city: string; service: "Standard" | "Fast"; type: "DOX" | "NON-DOX"; weight: string; charge: "auto" | "manual"; manual: string };

const ymd = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
const shift = (s: string, n: number) => { const d = new Date(`${s}T00:00:00`); d.setDate(d.getDate() + n); return ymd(d); };

/** Next AWB = last AWB with its trailing digits +1, keeping leading zeros. Non-numeric endings get no suggestion. */
export function nextAwb(prev: string | null | undefined) {
  const m = prev?.match(/^(.*?)(\d+)$/);
  if (!m) return "";
  const n = (BigInt(m[2]!) + 1n).toString();
  return m[1] + n.padStart(m[2]!.length, "0");
}

const field = "h-12 w-full rounded-md border-2 bg-background px-3 text-lg font-medium uppercase outline-none focus:border-primary focus:ring-2 focus:ring-primary/30";

/** Keyboard combobox: arrows move, Enter/Tab pick the highlighted option, Esc closes. */
function Combo({ id, value, onText, options, onPick, placeholder, inputRef, picked }: {
  id: string; value: string; onText: (v: string) => void; options: Opt[]; onPick: (o: Opt) => void; placeholder?: string;
  inputRef?: React.Ref<HTMLInputElement>; picked: boolean;
}) {
  const [open, setOpen] = useState(false);
  const [hi, setHi] = useState(0);
  useEffect(() => setHi(0), [options.length, value]);
  const show = open && !picked && options.length > 0;
  return (
    <div className="relative">
      <input id={id} ref={inputRef} className={field} autoComplete="off" placeholder={placeholder} value={value} role="combobox" aria-expanded={show}
        onChange={(e) => { onText(e.target.value); setOpen(true); }} onFocus={() => setOpen(true)} onBlur={() => setTimeout(() => setOpen(false), 120)}
        onKeyDown={(e) => {
          if (!show) return;
          if (e.key === "ArrowDown") { e.preventDefault(); setHi((h) => Math.min(h + 1, options.length - 1)); }
          else if (e.key === "ArrowUp") { e.preventDefault(); setHi((h) => Math.max(h - 1, 0)); }
          else if (e.key === "Enter") { e.preventDefault(); e.stopPropagation(); onPick(options[hi]!); setOpen(false); }
          else if (e.key === "Tab" && !e.shiftKey) { onPick(options[hi]!); setOpen(false); }
          else if (e.key === "Escape") { e.preventDefault(); setOpen(false); }
        }} />
      {show && (
        <ul role="listbox" className="absolute z-30 mt-1 max-h-72 w-full min-w-64 overflow-auto rounded-md border bg-popover text-popover-foreground shadow-lg">
          {options.map((o, i) => (
            <li key={o.key} role="option" aria-selected={i === hi} onMouseDown={(e) => { e.preventDefault(); onPick(o); setOpen(false); }}
              onMouseEnter={() => setHi(i)} className={`cursor-pointer px-3 py-2 ${i === hi ? "bg-accent text-accent-foreground" : ""}`}>
              <div className="font-semibold">{o.label}</div>{o.sub && <div className="text-xs opacity-70">{o.sub}</div>}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function Entry() {
  const { data: clients = [] } = useClients();
  const { data: zones = [] } = useZones();
  const qc = useQueryClient();
  const collapsed = useSidebarCollapsed();
  const [d, setD] = useState<Draft>({ awb: "", client_id: "", date: ymd(new Date()), city: "", service: "Standard", type: "NON-DOX", weight: "", charge: "auto", manual: "" });
  const [clientText, setClientText] = useState("");
  const [cityPicked, setCityPicked] = useState<{ name: string; state: string | null } | null>(null);
  const [busy, setBusy] = useState(false);
  const [pending, setPendingS] = useState<{ d: Draft; city: CityRes } | null>(null);
  const pendingRef = useRef(false);
  const setPending = (v: { d: Draft; city: CityRes } | null) => { pendingRef.current = !!v; setPendingS(v); };
  const [lastCharge, setLastCharge] = useState<string>("");
  const awbRef = useRef<HTMLInputElement>(null);
  const lock = useRef(false); // set synchronously so repeated Enter/F2/clicks cannot start a second save
  const cityRef = useRef<HTMLInputElement>(null);

  // Collapse the desktop sidebar while on this page; restore the earlier state on leave.
  useEffect(() => { const prev = getSidebarCollapsed(); setSidebarCollapsed(true); return () => setSidebarCollapsed(prev); }, []);
  useEffect(() => { awbRef.current?.focus(); }, []);

  const active = clients.filter((c) => c.active);
  const clientOpts: Opt[] = useMemo(() => {
    const q = clientText.trim().toLowerCase();
    return active.filter((c) => !q || c.name.toLowerCase().includes(q))
      .sort((a, b) => Number(!b.name.toLowerCase().startsWith(q)) - Number(!a.name.toLowerCase().startsWith(q)) || a.name.localeCompare(b.name))
      .slice(0, 12).map((c) => ({ key: c.id, label: up(c.name), sub: [c.state && up(c.state), c.gstin, c.phone].filter(Boolean).join(" · ") || undefined }));
  }, [active, clientText]);

  const cq = normCity(d.city);
  const { data: cityOpts = [] } = useQuery({
    queryKey: ["entry_city", cq], enabled: cq.length >= 2 && !cityPicked, staleTime: 60_000, retry: false,
    queryFn: async () => {
      const safe = cq.replace(/[%_]/g, "");
      const { data, error } = await supabase.from("cities").select("id, name, state, district, name_norm").ilike("name_norm", `%${safe}%`).limit(30);
      if (error) throw error;
      return (data ?? []).sort((a, b) => Number(!b.name_norm.startsWith(safe)) - Number(!a.name_norm.startsWith(safe)) || a.name.localeCompare(b.name))
        .slice(0, 12).map((c) => ({ key: c.id as string, label: up(c.name), sub: [c.district && up(c.district), c.state && up(c.state)].filter(Boolean).join(", ") || undefined, name: c.name as string, state: c.state as string | null }));
    },
  });

  const { data: rows = [] } = useQuery({
    queryKey: ["entry_rows", d.date],
    queryFn: async () => {
      const { data, error } = await supabase.from("shipments").select("id, awb, ship_date, destination, service, weight, amount, pricing_status, review_reason, shipment_type, charge_mode, clients(name)")
        .eq("ship_date", d.date).order("created_at", { ascending: false }).limit(300);
      if (error) throw error;
      return data as unknown as Saved[];
    },
  });

  /** Suggest from the seller's AWB series (client series first, then default); with no series, last AWB + 1. */
  async function suggestFor(clientId: string, last?: string) {
    const { data, error } = await supabase.rpc("next_awb", { p_client_id: clientId });
    if (error) { toast.error(errMsg(error)); return ""; }
    const hit = (data as { awb: string }[] | null)?.[0]?.awb;
    if (hit) return hit;
    if (last) return nextAwb(last);
    const { data: prev } = await supabase.from("shipments").select("awb").eq("client_id", clientId).order("created_at", { ascending: false }).limit(1).maybeSingle();
    return nextAwb(prev?.awb);
  }

  async function insert(x: Draft) {
    const w = +x.weight;
    const g = x.type === "DOX" ? w * 1000 : w;
    const { data, error } = await supabase.from("shipments").insert({
      awb: x.awb.trim(), client_id: x.client_id, ship_date: x.date, destination: upName(x.city), service: x.service, pieces: 1,
      shipment_type: x.type, weight_f: g, weight: x.type === "DOX" ? billedWeight("DOX", g) / 1000 : billedWeight("NON-DOX", w), amount: 0,
      charge_mode: x.charge, manual_amount: x.charge === "manual" ? Number(x.manual) : null,
    }).select("awb, amount, pricing_status, review_reason").single();
    if (error) { toast.error(error.code === "23505" ? `AWB ${x.awb} already exists` : errMsg(error)); awbRef.current?.focus(); return; }
    if (data.pricing_status === "needs_review") { toast.warning(`Saved as Needs Review: ${data.review_reason}`); setLastCharge("Needs review"); }
    else { toast.success(`${data.awb} saved · ${inr(data.amount)}`); setLastCharge(inr(data.amount)); }
    setD({ ...x, awb: "", city: "", weight: "", charge: "auto", manual: "" });
    suggestFor(x.client_id, data.awb).then((s) => s && setD((p) => (p.awb ? p : { ...p, awb: s })));
    setCityPicked(null);
    qc.invalidateQueries({ queryKey: ["entry_rows"] });
    qc.invalidateQueries({ queryKey: ["shipments"] });
    awbRef.current?.focus();
  }

  async function save() {
    if (lock.current) return;
    if (!d.awb.trim()) { toast.error("Enter the AWB number"); awbRef.current?.focus(); return; }
    if (!d.client_id) { toast.error("Choose a client from the list"); return; }
    if (!cityPicked) { toast.error("Choose the city from the suggestions"); cityRef.current?.focus(); return; }
    if (!(+d.weight > 0)) { toast.error("Enter a weight above 0"); return; }
    if (d.charge === "manual" && !(+d.manual > 0 && +d.manual <= 10000000)) { toast.error("Enter a manual charge above ₹0"); return; }
    lock.current = true; setBusy(true);
    try {
      const res = (await registerCities([d.city])).values().next().value as CityRes | undefined;
      if (!res || res.status === "invalid") { toast.error(res?.reason ?? "Enter a valid city"); return; }
      if (res.status === "ambiguous" || (res.status === "unmapped" && res.city_id)) { setPending({ d, city: res }); return; } // lock stays until the popup closes
      await insert(d);
    } catch (e) { toast.error(errMsg(e)); } finally { if (!pendingRef.current) { lock.current = false; } setBusy(false); }
  }

  async function runLocked(x: Draft) {
    lock.current = true; setBusy(true);
    try { await insert(x); } catch (e) { toast.error(errMsg(e)); } finally { lock.current = false; setBusy(false); }
  }

  useEffect(() => {
    const k = (e: KeyboardEvent) => { if (e.key === "F2") { e.preventDefault(); if (!e.repeat) save(); } };
    window.addEventListener("keydown", k);
    return () => window.removeEventListener("keydown", k);
  });

  const label = "mb-1 block text-xs font-semibold uppercase tracking-wide text-muted-foreground";
  return (
    <div>
      <div className="no-print mb-3 flex flex-wrap items-center justify-between gap-2">
        <h1 className="text-xl font-bold tracking-widest">CONSIGNMENT ENTRY</h1>
        <span className="text-xs text-muted-foreground">F2 or Enter in Charges = Save</span>
      </div>

      <form onSubmit={(e) => { e.preventDefault(); save(); }} className="mb-4 space-y-3 rounded-xl border bg-card p-3">
        <div className="grid grid-cols-1 items-end gap-2 sm:grid-cols-[auto_minmax(0,1fr)]">
          <div><label className={label} htmlFor="e-date">Date</label>
            <div className="flex items-center gap-1">
              <Button type="button" variant="outline" size="icon" className="h-12 w-10 shrink-0" aria-label="Previous day" onClick={() => setD({ ...d, date: shift(d.date, -1) })}><ChevronLeft /></Button>
              <input id="e-date" type="date" className="h-12 min-w-0 rounded-md border-2 bg-background px-3 text-lg font-bold" value={d.date}
                onChange={(e) => e.target.value && setD({ ...d, date: e.target.value })} />
              <Button type="button" variant="outline" size="icon" className="h-12 w-10 shrink-0" aria-label="Next day" onClick={() => setD({ ...d, date: shift(d.date, 1) })}><ChevronRight /></Button>
            </div></div>
          <div className="min-w-0 sm:max-w-xl"><label className={label} htmlFor="e-client">Client / Party</label>
            <Combo id="e-client" value={clientText} picked={!!d.client_id} options={clientOpts} placeholder="Type to search"
              onText={(v) => { setClientText(v); setD({ ...d, client_id: "" }); }}
              onPick={async (o) => {
                setClientText(o.label); const next = { ...d, client_id: o.key }; setD(next);
                if (!d.awb.trim()) { const s = await suggestFor(o.key); if (s) setD((p) => (p.awb ? p : { ...p, awb: s })); }
              }} /></div>
        </div>
        <div className="grid grid-cols-2 items-end gap-2 sm:grid-cols-4 xl:grid-cols-[1.3fr_1.8fr_0.9fr_1fr_0.9fr_0.9fr_1.1fr_auto]">
          <div className="min-w-0"><label className={label} htmlFor="e-awb">AWB Number</label>
            <input id="e-awb" ref={awbRef} className={field} autoComplete="off" maxLength={40} value={d.awb} onChange={(e) => setD({ ...d, awb: e.target.value })} /></div>
          <div className="min-w-0"><label className={label} htmlFor="e-city">Destination City</label>
            <Combo id="e-city" inputRef={cityRef} value={d.city} picked={!!cityPicked} options={cityOpts} placeholder="e.g. MUM"
              onText={(v) => { setD({ ...d, city: v }); setCityPicked(null); }}
              onPick={(o) => { const c = cityOpts.find((x) => x.key === o.key)!; setD({ ...d, city: up(c.name) }); setCityPicked({ name: c.name, state: c.state }); }} /></div>
          <div className="min-w-0"><label className={label} htmlFor="e-type">Type</label>
            <select id="e-type" className={field} value={d.type} onChange={(e) => setD({ ...d, type: e.target.value as Draft["type"] })}><option>DOX</option><option>NON-DOX</option></select></div>
          <div className="min-w-0"><label className={label} htmlFor="e-svc">Service</label>
            <select id="e-svc" className={field} value={d.service} onChange={(e) => setD({ ...d, service: e.target.value as Draft["service"] })}><option>Standard</option><option>Fast</option></select></div>
          <div className="min-w-0"><label className={label} htmlFor="e-wt">Wt. (Kg)</label>
            <input id="e-wt" type="number" step="0.001" min="0.001" className={field} value={d.weight} onChange={(e) => setD({ ...d, weight: e.target.value })} /></div>
          <div className="min-w-0"><label className={label} htmlFor="e-mode">Charge</label>
            <select id="e-mode" className={field} value={d.charge} onChange={(e) => setD({ ...d, charge: e.target.value as Draft["charge"], manual: "" })}><option value="auto">Auto</option><option value="manual">Manual</option></select></div>
          <div className="min-w-0"><label className={label} htmlFor="e-chg">Charges (₹)</label>
            {d.charge === "manual"
              ? <input id="e-chg" type="number" step="0.01" min="0.01" className={field} value={d.manual} placeholder="Amount" onChange={(e) => setD({ ...d, manual: e.target.value })}
                  onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); if (!e.repeat) save(); } }} />
              : <input id="e-chg" readOnly className={`${field} bg-muted`} value={lastCharge ? `Last: ${lastCharge}` : "Auto"} title="Worked out from the city's zone and the client's rate card"
                  onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); if (!e.repeat) save(); } }} />}</div>
          <Button type="submit" disabled={busy} className="col-span-2 h-12 px-6 text-lg font-bold sm:col-span-4 xl:col-span-1">{busy ? "Saving…" : "Add Shipment"}</Button>
        </div>
      </form>

      <div className="overflow-x-auto rounded-xl border bg-card">
        <table className="w-full text-sm">
          <thead className="bg-muted text-left"><tr><th className="p-2">#</th><th className="p-2">AWB</th><th className="p-2">Client</th><th className="p-2">City</th><th className="p-2">Type</th><th className="p-2">Service</th><th className="p-2">Wt (kg)</th><th className="p-2 text-right">Charges</th></tr></thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={r.id} className="border-t"><td className="p-2">{rows.length - i}</td><td className="p-2 font-mono">{r.awb}</td><td className="p-2">{up(r.clients?.name)}</td><td className="p-2">{up(r.destination)}</td><td className="p-2">{r.shipment_type ?? ""}</td><td className="p-2">{r.service}</td><td className="p-2">{+Number(r.weight).toFixed(3)}</td>
                <td className="p-2 text-right">{r.pricing_status === "needs_review" ? <span className="text-destructive">Needs review</span> : <>{inr(r.amount)}{r.charge_mode === "manual" && <span className="ml-1 rounded bg-muted px-1 text-xs">Manual</span>}</>}</td></tr>
            ))}
            {!rows.length && <tr><td colSpan={8} className="p-6 text-center text-muted-foreground">No consignments on this date yet.</td></tr>}
          </tbody>
        </table>
      </div>

      <CityZoneDialog open={!!pending} items={pending ? [pending.city] : []} zones={zones}
        onClose={() => { const p = pending; setPending(null); if (p) runLocked(p.d); else lock.current = false; }}
        onSaved={() => { const p = pending; setPending(null); qc.invalidateQueries({ queryKey: ["zones"] }); if (p) runLocked(p.d); else lock.current = false; }} />
    </div>
  );
}
