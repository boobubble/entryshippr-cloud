import { createFileRoute, Link } from "@tanstack/react-router";
import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import * as XLSX from "xlsx";
import { supabase, inr } from "@/lib/supabase";
import { useClients, useRateCards, calcAmount, errMsg } from "@/lib/hooks";
import { PageHead, appHead } from "@/components/PageHead";
import { Button } from "@/components/ui/button";
import { Switch } from "@/components/ui/switch";

export const Route = createFileRoute("/_app/import")({
  head: appHead("Excel import", "Upload booking sheets and turn them into shipments."),
  component: ImportPage,
});

const FIELDS = { awb: ["awb", "awb no", "awb number", "consignment", "cn no", "docket"], date: ["date", "booking date", "ship date"], client: ["client", "customer", "party", "consignor", "sender"], destination: ["destination", "dest", "city", "to"], service: ["service", "mode", "product"], weight: ["weight", "wt", "kg", "weight (kg)"], pieces: ["pieces", "pcs", "qty"], amount: ["amount", "charge", "freight", "rate"] } as const;
type Parsed = { awb: string; date: string; client: string; destination: string; service: string; weight: number; pieces: number; amount: number | null; error?: string };

function toISO(v: unknown): string {
  if (v instanceof Date) return v.toISOString().slice(0, 10);
  if (typeof v === "number") { const d = XLSX.SSF.parse_date_code(v); return `${d.y}-${String(d.m).padStart(2, "0")}-${String(d.d).padStart(2, "0")}`; }
  const s = String(v || "").trim();
  const m = s.match(/^(\d{1,2})[-/.](\d{1,2})[-/.](\d{2,4})$/);
  if (m) { const y = m[3].length === 2 ? "20" + m[3] : m[3]; return `${y}-${m[2].padStart(2, "0")}-${m[1].padStart(2, "0")}`; }
  if (/^\d{4}-\d{2}-\d{2}/.test(s)) return s.slice(0, 10);
  return new Date().toISOString().slice(0, 10);
}

function ImportPage() {
  const { data: clients = [] } = useClients();
  const { data: cards = [] } = useRateCards();
  const qc = useQueryClient();
  const [rows, setRows] = useState<Parsed[]>([]);
  const [createClients, setCreateClients] = useState(true);
  const [busy, setBusy] = useState(false);

  async function onFile(file: File) {
    const wb = XLSX.read(await file.arrayBuffer(), { cellDates: true });
    const json = XLSX.utils.sheet_to_json<Record<string, unknown>>(wb.Sheets[wb.SheetNames[0]], { defval: "" });
    if (!json.length) return toast.error("Sheet is empty");
    const headers = Object.keys(json[0]);
    const col = (k: keyof typeof FIELDS) => headers.find((h) => (FIELDS[k] as readonly string[]).includes(h.trim().toLowerCase()));
    const c = Object.fromEntries((Object.keys(FIELDS) as (keyof typeof FIELDS)[]).map((k) => [k, col(k)]));
    if (!c.awb || !c.client || !c.weight) return toast.error("Sheet needs columns: AWB, Client, Weight (also optional: Date, Destination, Service, Pieces, Amount)");
    setRows(json.map((r) => {
      const p: Parsed = { awb: String(r[c.awb!]).trim(), date: toISO(c.date ? r[c.date] : ""), client: String(r[c.client!]).trim(), destination: c.destination ? String(r[c.destination]) : "", service: c.service && r[c.service] ? String(r[c.service]).trim() : "Standard", weight: Number(r[c.weight!]) || 0, pieces: c.pieces ? Number(r[c.pieces]) || 1 : 1, amount: c.amount && r[c.amount] !== "" ? Number(r[c.amount]) : null };
      if (!p.awb) p.error = "Missing AWB"; else if (!p.client) p.error = "Missing client";
      return p;
    }).filter((p) => p.awb || p.client));
  }

  async function process() {
    setBusy(true);
    try {
      const map = new Map(clients.map((c) => [c.name.toLowerCase(), c.id]));
      const missing = [...new Set(rows.filter((r) => !r.error && !map.has(r.client.toLowerCase())).map((r) => r.client))];
      if (missing.length) {
        if (!createClients) throw new Error(`Unknown clients: ${missing.slice(0, 5).join(", ")}`);
        const { data, error } = await supabase.from("clients").insert(missing.map((name) => ({ name }))).select("id, name");
        if (error) throw error;
        data!.forEach((c) => map.set(c.name.toLowerCase(), c.id));
      }
      const out = []; const skipped: string[] = [];
      for (const r of rows) {
        if (r.error) { skipped.push(`${r.awb || "?"}: ${r.error}`); continue; }
        const cid = map.get(r.client.toLowerCase())!;
        const amount = r.amount ?? calcAmount(cards, cid, r.service, r.weight);
        if (amount == null) { skipped.push(`${r.awb}: no rate card for ${r.service}`); continue; }
        out.push({ awb: r.awb, client_id: cid, ship_date: r.date, destination: r.destination, service: r.service, weight: r.weight, pieces: r.pieces, amount });
      }
      let inserted = 0;
      for (let i = 0; i < out.length; i += 500) {
        const { data, error } = await supabase.from("shipments").upsert(out.slice(i, i + 500), { onConflict: "owner_id,awb", ignoreDuplicates: true }).select("id");
        if (error) throw error;
        inserted += data?.length || 0;
      }
      toast.success(`${inserted} shipments added. ${out.length - inserted} duplicates and ${skipped.length} problem rows skipped.`);
      if (skipped.length) console.warn("Skipped rows", skipped);
      setRows([]);
      qc.invalidateQueries();
    } catch (e) {
      toast.error(errMsg(e));
    } finally { setBusy(false); }
  }

  function template() {
    const ws = XLSX.utils.aoa_to_sheet([["AWB", "Date", "Client", "Destination", "Service", "Weight", "Pieces", "Amount"]]);
    const wb = XLSX.utils.book_new(); XLSX.utils.book_append_sheet(wb, ws, "Bookings");
    XLSX.writeFile(wb, "entrysetu-template.xlsx");
  }

  const total = rows.reduce((a, r) => a + (r.amount ?? 0), 0);
  return (
    <div>
      <PageHead title="Excel import"><Button variant="outline" onClick={template}>Download template</Button></PageHead>
      <div className="rounded-xl border-2 border-dashed bg-card p-8 text-center">
        <p className="mb-3 text-sm text-muted-foreground">Upload .xlsx, .xls or .csv. Required columns: AWB, Client, Weight. Amounts are taken from the sheet, or worked out from your <Link to="/rate-cards" className="text-primary underline">rate cards</Link>.</p>
        <input type="file" accept=".xlsx,.xls,.csv" onChange={(e) => e.target.files?.[0] && onFile(e.target.files[0])} className="mx-auto block text-sm" />
      </div>
      {rows.length > 0 && (
        <div className="mt-6">
          <div className="mb-3 flex flex-wrap items-center justify-between gap-3">
            <div className="text-sm">{rows.length} rows · sheet amounts {inr(total)}</div>
            <label className="flex items-center gap-2 text-sm"><Switch checked={createClients} onCheckedChange={setCreateClients} />Create new clients automatically</label>
            <Button onClick={process} disabled={busy}>{busy ? "Processing…" : "Import shipments"}</Button>
          </div>
          <div className="max-h-[480px] overflow-auto rounded-xl border bg-card">
            <table className="w-full text-sm">
              <thead className="sticky top-0 bg-muted text-left"><tr><th className="p-2">AWB</th><th className="p-2">Date</th><th className="p-2">Client</th><th className="p-2">Dest.</th><th className="p-2">Service</th><th className="p-2">Kg</th><th className="p-2">Amount</th><th className="p-2">Status</th></tr></thead>
              <tbody>{rows.slice(0, 300).map((r, i) => (
                <tr key={i} className="border-t"><td className="p-2 font-mono">{r.awb}</td><td className="p-2">{r.date}</td><td className="p-2">{r.client}</td><td className="p-2">{r.destination}</td><td className="p-2">{r.service}</td><td className="p-2">{r.weight}</td><td className="p-2">{r.amount ?? "rate card"}</td><td className="p-2 text-destructive">{r.error}</td></tr>
              ))}</tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
}
