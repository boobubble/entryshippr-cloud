import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { supabase, inr } from "@/lib/supabase";
import { useProfile, errMsg } from "@/lib/hooks";
import { up } from "@/lib/text";
import { loadInvoice, linesForDocument, type InvoiceLine } from "@/lib/invoices";
import { appHead } from "@/components/PageHead";
import { InvoiceDocument, invDate } from "@/components/InvoiceDocument";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { ArrowLeft, Eye, Plus, Trash2, X } from "lucide-react";

export const Route = createFileRoute("/_app/invoices/edit/$id")({
  head: appHead("Edit invoice draft", "Edit invoice lines, charges and taxes before finalizing."),
  component: Editor,
});

type Line = Pick<InvoiceLine, "shipment_id" | "ship_date" | "awb" | "receiver_name" | "destination" | "shipment_type" | "original_weight" | "original_amount"> & { weight: string; rate: string; amount: string; declared_value: string };
type Charge = { code: string; label: string; mode: "fixed" | "percent"; base: "subtotal" | "declared_value"; value: string };
type Header = { invoice_date: string; period_from: string; period_to: string; kind: "gst" | "nongst"; gst_rate: string; round_off: string; notes: string; numbering: "auto" | "manual"; requested_invoice_no: string };

const PRESETS: [string, string][] = [["fuel", "Fuel Surcharge"], ["fov", "FOV"], ["packing", "Packing"], ["pickup", "Pickup"], ["handling", "Handling"], ["delivery", "Delivery"], ["extra", "Extra Charges"], ["custom", "Custom"]];
const sel = "h-9 w-full rounded-md border bg-background px-2 text-sm";
const s = (v: unknown) => (v == null ? "" : String(v));

function Editor() {
  const { id } = Route.useParams();
  const nav = useNavigate();
  const qc = useQueryClient();
  const { data: me } = useProfile();
  const { data, error, refetch } = useQuery({ queryKey: ["invoice", id], queryFn: () => loadInvoice(id) });
  const [h, setH] = useState<Header | null>(null);
  const [lines, setLines] = useState<Line[]>([]);
  const [charges, setCharges] = useState<Charge[]>([]);
  const [dirty, setDirty] = useState(false);
  const [busy, setBusy] = useState(false);
  const [preview, setPreview] = useState(false);

  // Load server state into the form (also after every save, so totals shown are the server's).
  useEffect(() => {
    if (!data) return;
    const i = data.inv;
    setH({ invoice_date: i.invoice_date, period_from: i.period_from, period_to: i.period_to, kind: i.kind, gst_rate: s(Number(i.gst_rate) || 18), round_off: s(Number(i.round_off ?? 0)), notes: s(i.notes), numbering: i.numbering ?? "auto", requested_invoice_no: s(i.requested_invoice_no) });
    setLines(data.lines.map((l) => ({ ...l, weight: s(l.weight), rate: s(l.rate), amount: s(l.amount), declared_value: s(l.declared_value) })));
    setCharges(data.charges.map((c) => ({ code: c.code, label: c.label, mode: c.mode, base: c.base === "declared_value" ? "declared_value" : "subtotal", value: s(c.value) })));
    setDirty(false);
  }, [data]);

  const inv = data?.inv;
  const { data: available = [] } = useQuery({
    queryKey: ["draft-available", id, inv?.client_id, h?.period_from, h?.period_to],
    enabled: !!inv && !!h,
    queryFn: async () => {
      const { data, error } = await supabase.from("shipments").select("id, ship_date, awb, receiver_name, destination, shipment_type, weight, rate_applied, amount, pricing_status")
        .eq("client_id", inv.client_id).is("invoice_id", null).is("draft_invoice_id", null)
        .gte("ship_date", h!.period_from).lte("ship_date", h!.period_to).order("ship_date");
      if (error) throw error;
      return data as { id: string; ship_date: string; awb: string; receiver_name: string | null; destination: string | null; shipment_type: string | null; weight: number; rate_applied: number | null; amount: number; pricing_status: string | null }[];
    },
  });

  if (error) return <p className="text-destructive">{error.message}</p>;
  if (!data || !h || !inv) return <p className="text-muted-foreground">Loading…</p>;
  if (inv.status !== "draft") return <div className="space-y-3"><p>This invoice is {inv.status} and can no longer be edited.</p><Button asChild><Link to="/invoices/$id" params={{ id }}>View invoice</Link></Button></div>;

  const upd = (fn: () => void) => { fn(); setDirty(true); };
  const setLine = (i: number, k: keyof Line, v: string) => upd(() => setLines(lines.map((l, j) => (j === i ? { ...l, [k]: v } : l))));
  const setCharge = (i: number, patch: Partial<Charge>) => upd(() => setCharges(charges.map((c, j) => (j === i ? { ...c, ...patch } : c))));
  const inList = new Set(lines.map((l) => l.shipment_id));
  const addable = available.filter((a) => !inList.has(a.id));

  async function save(): Promise<boolean> {
    setBusy(true);
    try {
      const header = { ...h!, gst_rate: Number(h!.gst_rate), round_off: Number(h!.round_off || 0), requested_invoice_no: h!.numbering === "manual" ? h!.requested_invoice_no : null };
      const pl = lines.map((l) => ({ shipment_id: l.shipment_id, weight: Number(l.weight), rate: Number(l.rate), amount: Number(l.amount), declared_value: l.declared_value === "" ? null : Number(l.declared_value) }));
      const pc = charges.map((c) => ({ code: c.code, label: c.label, mode: c.mode, base: c.mode === "fixed" ? "none" : c.base, value: Number(c.value || 0) }));
      const { error } = await supabase.rpc("save_invoice_draft", { p_invoice_id: id, p_header: header, p_lines: pl, p_charges: pc });
      if (error) throw error;
      await refetch();
      qc.invalidateQueries({ queryKey: ["invoices"] });
      qc.invalidateQueries({ queryKey: ["draft-available"] });
      return true;
    } catch (e) { toast.error(errMsg(e)); return false; } finally { setBusy(false); }
  }

  async function finalize() {
    if (!(await save())) return;
    if (!confirm("Finalize this invoice? It gets its invoice number and can no longer be edited. Corrections need cancel + reissue.")) return;
    setBusy(true);
    const { error } = await supabase.rpc("finalize_invoice", { p_invoice_id: id });
    setBusy(false);
    if (error) { toast.error(errMsg(error)); return; }
    qc.invalidateQueries();
    toast.success("Invoice issued");
    nav({ to: "/invoices/$id", params: { id } });
  }

  async function discard() {
    if (!confirm("Discard this draft? Its shipments become unbilled again. No invoice number is used.")) return;
    const { error } = await supabase.rpc("discard_invoice_draft", { p_invoice_id: id });
    if (error) { toast.error(errMsg(error)); return; }
    qc.invalidateQueries();
    toast.success("Draft discarded");
    nav({ to: "/invoices" });
  }

  const autoRound = () => {
    const pre = Number(inv.total) - Number(inv.round_off ?? 0);
    upd(() => setH({ ...h, round_off: (Math.round(pre) - pre).toFixed(2) }));
  };

  if (preview) return (
    <div className="invoice-page">
      <div className="no-print mb-4 flex gap-2"><Button variant="outline" onClick={() => setPreview(false)}><ArrowLeft />Back to editor</Button></div>
      <div className="invoice-scroll overflow-x-auto"><InvoiceDocument seller={me?.profile} invoice={inv} shipments={linesForDocument(data.lines)} charges={data.charges} /></div>
    </div>
  );

  const T = ({ k, v, b }: { k: string; v: number; b?: boolean }) => <div className={`flex justify-between gap-4 ${b ? "border-t pt-2 font-bold" : ""}`}><span>{k}</span><span className="tabular-nums">{inr(v)}</span></div>;
  const rate = Number(inv.gst_rate) || 0;

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-center gap-2">
        <Button variant="outline" asChild><Link to="/invoices"><ArrowLeft />Invoices</Link></Button>
        <h1 className="mr-auto text-xl font-semibold">Draft invoice · {up(inv.bill_to_name ?? inv.clients?.name)}{inv.reissue_of ? " (reissue)" : ""}</h1>
        <Button variant="ghost" onClick={discard} disabled={busy}><Trash2 />Discard</Button>
        <Button variant="outline" onClick={async () => { if (!dirty || (await save())) setPreview(true); }} disabled={busy}><Eye />Preview</Button>
        <Button variant="outline" onClick={async () => { if (await save()) toast.success("Draft saved"); }} disabled={busy}>Save draft</Button>
        <Button onClick={finalize} disabled={busy}>Finalize</Button>
      </div>

      <section className="grid gap-3 rounded-xl border bg-card p-4 sm:grid-cols-2 lg:grid-cols-4">
        <div><Label>Invoice date</Label><Input type="date" value={h.invoice_date} onChange={(e) => upd(() => setH({ ...h, invoice_date: e.target.value }))} /></div>
        <div><Label>Period from</Label><Input type="date" value={h.period_from} onChange={(e) => upd(() => setH({ ...h, period_from: e.target.value }))} /></div>
        <div><Label>Period to</Label><Input type="date" value={h.period_to} onChange={(e) => upd(() => setH({ ...h, period_to: e.target.value }))} /></div>
        <div><Label>Invoice type</Label>
          <select className={sel} value={h.kind} onChange={(e) => upd(() => setH({ ...h, kind: e.target.value as Header["kind"] }))}><option value="gst">GST invoice</option><option value="nongst">Non-GST bill</option></select></div>
        <div><Label>GST rate</Label>
          <select className={sel} disabled={h.kind !== "gst"} value={h.gst_rate} onChange={(e) => upd(() => setH({ ...h, gst_rate: e.target.value }))}>{[5, 12, 18, 28].map((r) => <option key={r} value={r}>{r}%</option>)}</select></div>
        <div><Label>Invoice number</Label>
          <select className={sel} value={h.numbering} onChange={(e) => upd(() => setH({ ...h, numbering: e.target.value as Header["numbering"] }))}><option value="auto">Automatic (on finalize)</option><option value="manual">Manual</option></select></div>
        {h.numbering === "manual" && <div><Label>Manual number</Label><Input value={h.requested_invoice_no} maxLength={40} onChange={(e) => upd(() => setH({ ...h, requested_invoice_no: e.target.value }))} /></div>}
        <div className="sm:col-span-2 lg:col-span-4"><Label>Notes</Label><Input value={h.notes} maxLength={500} onChange={(e) => upd(() => setH({ ...h, notes: e.target.value }))} /></div>
      </section>

      <section className="overflow-x-auto rounded-xl border bg-card">
        <table className="w-full text-sm">
          <thead className="bg-muted text-left"><tr><th className="p-2">Date</th><th className="p-2">AWB</th><th className="p-2">Receiver</th><th className="p-2">Destination</th><th className="p-2">Weight (kg)</th><th className="p-2">Rate</th><th className="p-2">Amount</th><th className="p-2">Declared value</th><th /></tr></thead>
          <tbody>
            {lines.map((l, i) => (
              <tr key={l.shipment_id ?? i} className="border-t align-top">
                <td className="p-2 whitespace-nowrap">{invDate(l.ship_date)}</td><td className="p-2 font-mono">{l.awb}</td>
                <td className="p-2">{l.receiver_name || "—"}</td><td className="p-2">{up(l.destination)} <span className="text-muted-foreground">{l.shipment_type}</span></td>
                <td className="p-2"><Input className="w-24" type="number" step="0.001" min={0} value={l.weight} onChange={(e) => setLine(i, "weight", e.target.value)} />
                  {Number(l.weight) !== Number(l.original_weight) && <div className="text-xs text-muted-foreground">was {+l.original_weight}</div>}</td>
                <td className="p-2"><Input className="w-24" type="number" step="0.01" min={0} value={l.rate} onChange={(e) => setLine(i, "rate", e.target.value)} /></td>
                <td className="p-2"><Input className="w-28" type="number" step="0.01" min={0.01} value={l.amount} onChange={(e) => setLine(i, "amount", e.target.value)} />
                  {Number(l.amount) !== Number(l.original_amount) && <div className="text-xs text-muted-foreground">was {inr(l.original_amount)}</div>}</td>
                <td className="p-2"><Input className="w-28" type="number" step="0.01" min={0} value={l.declared_value} onChange={(e) => setLine(i, "declared_value", e.target.value)} /></td>
                <td className="p-2"><Button size="icon" variant="ghost" aria-label={`Remove ${l.awb}`} disabled={lines.length === 1} onClick={() => upd(() => setLines(lines.filter((_, j) => j !== i)))}><X /></Button></td>
              </tr>
            ))}
          </tbody>
        </table>
        {addable.length > 0 && (
          <div className="border-t p-3">
            <p className="mb-2 text-sm font-medium">Add unbilled shipments from this period</p>
            <div className="flex flex-wrap gap-2">
              {addable.map((a) => {
                const ok = a.pricing_status !== "needs_review" && Number(a.amount) > 0;
                return <Button key={a.id} size="sm" variant="outline" disabled={!ok} title={ok ? "" : "Needs review"}
                  onClick={() => upd(() => setLines([...lines, { shipment_id: a.id, ship_date: a.ship_date, awb: a.awb, receiver_name: a.receiver_name, destination: a.destination, shipment_type: a.shipment_type, original_weight: a.weight, original_amount: a.amount, weight: s(a.weight), rate: s(a.rate_applied ?? a.amount), amount: s(a.amount), declared_value: "" }]))}>
                  <Plus />{a.awb} · {invDate(a.ship_date)}{ok ? ` · ${inr(a.amount)}` : " · needs review"}</Button>;
              })}
            </div>
          </div>
        )}
      </section>

      <div className="grid gap-5 lg:grid-cols-[1fr_320px]">
        <section className="rounded-xl border bg-card p-4">
          <div className="mb-3 flex items-center justify-between"><h2 className="font-semibold">Charges</h2>
            <Button size="sm" variant="outline" disabled={charges.length >= 20} onClick={() => upd(() => setCharges([...charges, { code: "fuel", label: "Fuel Surcharge", mode: "percent", base: "subtotal", value: "" }]))}><Plus />Add charge</Button></div>
          {!charges.length && <p className="text-sm text-muted-foreground">No extra charges.</p>}
          <div className="space-y-3">
            {charges.map((c, i) => (
              <div key={i} className="grid items-end gap-2 sm:grid-cols-[1fr_1fr_110px_1fr_100px_auto]">
                <div><Label>Charge</Label><select className={sel} value={c.code} onChange={(e) => { const p = PRESETS.find((x) => x[0] === e.target.value)!; setCharge(i, { code: p[0], label: p[0] === "custom" ? "" : p[1], base: p[0] === "fov" ? c.base : "subtotal" }); }}>{PRESETS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></div>
                <div><Label>Name</Label><Input value={c.label} maxLength={60} onChange={(e) => setCharge(i, { label: e.target.value })} /></div>
                <div><Label>Type</Label><select className={sel} value={c.mode} onChange={(e) => setCharge(i, { mode: e.target.value as Charge["mode"] })}><option value="fixed">Fixed ₹</option><option value="percent">%</option></select></div>
                <div><Label>Base</Label>{c.mode === "fixed" ? <p className="h-9 py-2 text-sm text-muted-foreground">—</p> :
                  <select className={sel} value={c.base} onChange={(e) => setCharge(i, { base: e.target.value as Charge["base"] })}><option value="subtotal">Line subtotal</option>{c.code === "fov" && <option value="declared_value">Declared value</option>}</select>}</div>
                <div><Label>{c.mode === "fixed" ? "₹" : "%"}</Label><Input type="number" step="0.01" min={0} max={c.mode === "percent" ? 100 : undefined} value={c.value} onChange={(e) => setCharge(i, { value: e.target.value })} /></div>
                <Button size="icon" variant="ghost" aria-label="Remove charge" onClick={() => upd(() => setCharges(charges.filter((_, j) => j !== i)))}><X /></Button>
              </div>
            ))}
          </div>
          <div className="mt-5 flex flex-wrap items-end gap-2">
            <div><Label>Round off (−1 to +1)</Label><Input className="w-32" type="number" step="0.01" min={-1} max={1} value={h.round_off} onChange={(e) => upd(() => setH({ ...h, round_off: e.target.value }))} /></div>
            <Button variant="outline" size="sm" onClick={autoRound} disabled={dirty} title={dirty ? "Save first" : ""}>Auto round</Button>
          </div>
        </section>

        <aside className="h-fit space-y-2 rounded-xl border bg-card p-4 text-sm">
          <h2 className="font-semibold">Totals (saved)</h2>
          <T k="Line subtotal" v={Number(inv.subtotal)} />
          {data.charges.map((c) => <T key={c.id} k={c.label} v={Number(c.amount)} />)}
          <T k="Taxable value" v={Number(inv.taxable_value ?? inv.subtotal)} b />
          {inv.kind === "gst" && inv.tax_mode === "intra" && <><T k={`CGST ${rate / 2}%`} v={Number(inv.cgst)} /><T k={`SGST ${rate / 2}%`} v={Number(inv.sgst)} /></>}
          {inv.kind === "gst" && inv.tax_mode === "inter" && <T k={`IGST ${rate}%`} v={Number(inv.igst)} />}
          {inv.kind !== "gst" && <p className="text-muted-foreground">Non-GST bill · no tax</p>}
          <T k="Round off" v={Number(inv.round_off ?? 0)} />
          <T k="Grand total" v={Number(inv.total)} b />
          {dirty && <p className="rounded bg-muted p-2 text-xs">You have unsaved changes. Save the draft to recalculate totals.</p>}
        </aside>
      </div>
    </div>
  );
}
