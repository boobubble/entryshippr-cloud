import { up } from "@/lib/text";
import { useEffect, useState } from "react";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { errMsg } from "@/lib/hooks";
import { normCity, type CityRes } from "@/lib/cities";
import type { Zone } from "@/lib/rates";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

const sel = "h-9 w-full rounded-md border bg-background px-2 text-sm";
const NEW = "__new";

type Choice = { city: string; zone: string };

/** One dialog for one or many cities without a zone (or with an ambiguous name). */
export function CityZoneDialog({ open, items, zones, onClose, onSaved, onSkip }: {
  open: boolean; items: CityRes[]; zones: Zone[]; onClose: () => void; onSaved: () => void; onSkip?: () => void;
}) {
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const [choice, setChoice] = useState<Record<string, Choice>>({});
  const [newZone, setNewZone] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (open) setPicked(new Set());
    if (open) setChoice(Object.fromEntries(items.map((r) => [r.input, { city: r.status === "ambiguous" ? "" : r.city_id ?? "", zone: "" }])));
  }, [open, items]);

  const set = (k: string, p: Partial<Choice>) => setChoice((c) => ({ ...c, [k]: { ...c[k]!, ...p } }));
  // Applies a zone to the ticked cities, or to every city when none are ticked.
  const setAll = (zone: string) => setChoice((c) => Object.fromEntries(Object.entries(c).map(([k, v]) => [k, picked.size && !picked.has(k) ? v : { ...v, zone }])));
  const toggle = (k: string) => setPicked((p) => { const n = new Set(p); if (n.has(k)) n.delete(k); else n.add(k); return n; });
  const ready = items.filter((r) => choice[r.input]?.city && choice[r.input]?.zone);

  async function save() {
    if (!ready.length) { toast.error("Choose a zone for at least one city"); return; }
    if (ready.some((r) => choice[r.input]!.zone === NEW) && !newZone.trim()) { toast.error("Enter the new zone name"); return; }
    setBusy(true);
    try {
      let newId = "";
      if (ready.some((r) => choice[r.input]!.zone === NEW)) {
        const { data, error } = await supabase.from("zones").insert({ name: newZone.trim(), sort_order: zones.length }).select("id").single();
        if (error) throw error.code === "23505" ? new Error("A zone with this name already exists") : error;
        newId = data.id;
      }
      const aliases = ready.filter((r) => r.status === "ambiguous").map((r) => ({ alias_norm: normCity(r.input), city_id: choice[r.input]!.city }));
      if (aliases.length) {
        const { error } = await supabase.from("seller_city_aliases").upsert(aliases, { onConflict: "owner_id,alias_norm" });
        if (error) throw error;
      }
      const byCity = new Map(ready.map((r) => { const c = choice[r.input]!; return [c.city, c.zone === NEW ? newId : c.zone]; }));
      const { error } = await supabase.from("seller_city_zones")
        .upsert([...byCity].map(([city_id, zone_id]) => ({ city_id, zone_id, updated_at: new Date().toISOString() })), { onConflict: "owner_id,city_id" });
      if (error) throw error;
      toast.success(`Zones saved for ${byCity.size} ${byCity.size === 1 ? "city" : "cities"}`);
      setNewZone("");
      onSaved();
    } catch (e) { toast.error(errMsg(e)); } finally { setBusy(false); }
  }

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-3xl">
        <DialogHeader>
          <DialogTitle>Assign zone{items.length > 1 ? `s for ${items.length} cities` : ""}</DialogTitle>
          <DialogDescription>Pick the zone you use for each city. Where a name matches more than one city, confirm which one you mean. Your choices apply only to your account.</DialogDescription>
        </DialogHeader>
        {items.length > 1 && (
          <div className="flex flex-wrap items-center gap-2 text-sm">
            <span>{picked.size ? `Set ${picked.size} ticked to` : "Set all to"}</span>
            <select className={`${sel} w-48`} value="" onChange={(e) => e.target.value && setAll(e.target.value)}>
              <option value="">Choose zone…</option>
              {zones.map((z) => <option key={z.id} value={z.id}>{z.name}</option>)}
              <option value={NEW}>+ New zone</option>
            </select>
          </div>
        )}
        <div className="space-y-2">
          {items.map((r) => {
            const c = choice[r.input] ?? { city: "", zone: "" };
            return (
              <div key={r.input} className="grid gap-2 rounded-lg border p-2 sm:grid-cols-[1fr_1fr_1fr] sm:items-center">
                <div className="flex items-start gap-2 text-sm font-medium uppercase"><input type="checkbox" className="mt-1" aria-label={`Select ${r.input}`} checked={picked.has(r.input)} onChange={() => toggle(r.input)} /><div>{r.input}{r.status === "unmapped" && r.city_name && normCity(r.city_name) !== normCity(r.input) && <span className="block text-xs text-muted-foreground">= {r.city_name}</span>}</div></div>
                {r.status === "ambiguous" ? (
                  <select aria-label={`Which ${r.input}`} className={sel} value={c.city} onChange={(e) => set(r.input, { city: e.target.value })}>
                    <option value="">Which one?</option>
                    {(r.candidates ?? []).map((k) => <option key={k.id} value={k.id}>{up(k.name)}{k.district ? `, ${up(k.district)}` : ""}{k.state ? `, ${up(k.state)}` : " (state unknown)"}</option>)}
                  </select>
                ) : r.city_id ? <div className="text-xs text-muted-foreground">{r.state ? up(r.state) : "State not set"}</div>
                  : <div className="text-xs text-destructive">{r.reason ?? "Can't be registered"}</div>}
                <select aria-label={`Zone for ${r.input}`} className={sel} value={c.zone} disabled={!c.city} onChange={(e) => set(r.input, { zone: e.target.value })}>
                  <option value="">Choose zone…</option>
                  {zones.map((z) => <option key={z.id} value={z.id}>{z.name}</option>)}
                  <option value={NEW}>+ New zone</option>
                </select>
              </div>
            );
          })}
        </div>
        {Object.values(choice).some((c) => c.zone === NEW) && (
          <Input placeholder="New zone name" value={newZone} onChange={(e) => setNewZone(e.target.value)} />
        )}
        <DialogFooter>
          {onSkip ? <Button variant="outline" onClick={onSkip}>Skip — keep as Needs Review (₹0)</Button> : <Button variant="outline" onClick={onClose}>Later</Button>}
          <Button onClick={save} disabled={busy || !ready.length}>{busy ? "Saving…" : `Save ${ready.length || ""}`}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
