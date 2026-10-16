import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { Trash2 } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { errMsg, useClients } from "@/lib/hooks";
import { up } from "@/lib/text";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

type Series = { id: string; client_id: string | null; prefix: string; start_number: number; digits: number; active: boolean };
type Form = { prefix: string; start: string; digits: string; active: boolean };

const blank: Form = { prefix: "", start: "1", digits: "6", active: true };
const toForm = (s?: Series): Form => (s ? { prefix: s.prefix, start: String(s.start_number), digits: String(s.digits), active: s.active } : blank);

/** Checks the same rules as the awb_series table constraints so errors show before saving. */
export function checkSeries(f: Form): string | null {
  const p = f.prefix.trim().toUpperCase();
  if (!/^[A-Z0-9/-]{0,20}$/.test(p)) return "Prefix can use only letters, numbers, / and - (max 20)";
  const d = Number(f.digits);
  if (!Number.isInteger(d) || d < 1 || d > 18) return "Digits must be 1 to 18";
  if (!/^\d+$/.test(f.start.trim())) return "Start number must be 0 or more";
  if (f.start.trim().replace(/^0+(?=\d)/, "").length > d) return "Start number has more digits than allowed";
  if (p.length + d > 40) return "Prefix + digits must be 40 characters or less";
  return null;
}

export const previewAwb = (f: Form) => f.prefix.trim().toUpperCase() + f.start.trim().replace(/^0+(?=\d)/, "").padStart(Math.max(1, Number(f.digits) || 1), "0");

function Row({ title, series, clientId, onDone }: { title: string; series?: Series; clientId: string | null; onDone: () => void }) {
  const [f, setF] = useState<Form>(toForm(series));
  const [busy, setBusy] = useState(false);
  async function save() {
    const bad = checkSeries(f);
    if (bad) { toast.error(bad); return; }
    setBusy(true);
    const row = { prefix: f.prefix.trim().toUpperCase(), start_number: Number(f.start), digits: Number(f.digits), active: f.active };
    const { error } = series
      ? await supabase.from("awb_series").update(row).eq("id", series.id)
      : await supabase.from("awb_series").insert({ ...row, client_id: clientId });
    setBusy(false);
    if (error) { toast.error(error.code === "23505" ? "A series already exists here" : errMsg(error)); return; }
    toast.success("AWB series saved");
    onDone();
  }
  async function remove() {
    if (!series || !confirm(`Remove the AWB series for ${title}?`)) return;
    const { error } = await supabase.from("awb_series").delete().eq("id", series.id);
    if (error) { toast.error(errMsg(error)); return; }
    toast.success("AWB series removed");
    onDone();
  }
  return (
    <div className="grid items-end gap-3 border-t py-3 sm:grid-cols-[1.4fr_1fr_1fr_0.7fr_auto_auto]">
      <div className="font-medium sm:pb-2">{title}<div className="text-xs font-normal text-muted-foreground">Next example: {previewAwb(f)}</div></div>
      <div><Label>Prefix</Label><Input value={f.prefix} maxLength={20} onChange={(e) => setF({ ...f, prefix: e.target.value.toUpperCase() })} /></div>
      <div><Label>Start number</Label><Input inputMode="numeric" value={f.start} onChange={(e) => setF({ ...f, start: e.target.value.replace(/\D/g, "") })} /></div>
      <div><Label>Digits</Label><Input type="number" min={1} max={18} value={f.digits} onChange={(e) => setF({ ...f, digits: e.target.value })} /></div>
      <label className="flex items-center gap-2 text-sm sm:pb-2"><input type="checkbox" checked={f.active} onChange={(e) => setF({ ...f, active: e.target.checked })} />Active</label>
      <div className="flex gap-2">
        <Button variant="outline" disabled={busy} onClick={save}>{busy ? "Saving…" : "Save"}</Button>
        {series && <Button variant="ghost" size="icon" aria-label="Remove series" onClick={remove}><Trash2 className="h-4 w-4" /></Button>}
      </div>
    </div>
  );
}

export function AwbSeries() {
  const qc = useQueryClient();
  const { data: clients = [] } = useClients();
  const { data: rows = [], isLoading, error } = useQuery({
    queryKey: ["awb_series"], retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.from("awb_series").select("id, client_id, prefix, start_number, digits, active");
      if (error) throw error;
      return data as Series[];
    },
  });
  const [addFor, setAddFor] = useState("");
  const refresh = () => { qc.invalidateQueries({ queryKey: ["awb_series"] }); setAddFor(""); };
  const def = rows.find((r) => !r.client_id);
  const byClient = rows.filter((r) => r.client_id);
  const name = (id: string) => up(clients.find((c) => c.id === id)?.name ?? "Client");
  const free = clients.filter((c) => c.active && !byClient.some((r) => r.client_id === c.id));

  return (
    <div className="mt-6 max-w-4xl rounded-xl border bg-card p-6">
      <h2 className="text-lg font-semibold">AWB numbering</h2>
      <p className="mb-2 text-sm text-muted-foreground">
        Consignment entry suggests the next AWB from these series. A client series is used for that client; otherwise the default series. You can always type a different AWB. Numbers are never reused and a failed save uses nothing.
      </p>
      {error && <p className="text-sm text-destructive">{errMsg(error)}</p>}
      {!isLoading && !error && (
        <>
          <Row key={def?.id ?? "new-default"} title="Default series" series={def} clientId={null} onDone={refresh} />
          {byClient.map((s) => <Row key={s.id} title={name(s.client_id!)} series={s} clientId={s.client_id} onDone={refresh} />)}
          {addFor && <Row key={`new-${addFor}`} title={name(addFor)} clientId={addFor} onDone={refresh} />}
          <div className="flex items-end gap-2 border-t pt-3">
            <div className="flex-1"><Label htmlFor="awb-add">Add a client-specific series</Label>
              <select id="awb-add" className="h-10 w-full rounded-md border bg-background px-3 text-sm" value={addFor} onChange={(e) => setAddFor(e.target.value)}>
                <option value="">Choose client…</option>
                {free.map((c) => <option key={c.id} value={c.id}>{up(c.name)}</option>)}
              </select></div>
          </div>
        </>
      )}
    </div>
  );
}
