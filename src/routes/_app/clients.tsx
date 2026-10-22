import { up, upName, nameKey, clientDetails, groupClients, isDupClientError } from "@/lib/text";
import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { useClients, errMsg, type Client } from "@/lib/hooks";
import { PageHead, appHead } from "@/components/PageHead";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { StateSelect } from "@/components/StateSelect";
import { addAlias, useClientAliases } from "@/lib/client-aliases";
import { GstinVerification } from "@/components/GstinVerification";

export const Route = createFileRoute("/_app/clients")({
  head: appHead("Clients", "Manage your GST and non-GST courier clients."),
  component: Clients,
});

const empty = { name: "", phone: "", email: "", gstin: "", address: "", state: "", is_gst: true, active: true };

function Clients() {
  const { data: clients = [] } = useClients();
  const qc = useQueryClient();
  const [edit, setEdit] = useState<(typeof empty & { id?: string }) | null>(null);
  const [q, setQ] = useState("");
  const { data: aliasData } = useClientAliases();
  const aliases = aliasData?.rows ?? [];
  const [newAlias, setNewAlias] = useState("");

  async function save(e: React.FormEvent) {
    e.preventDefault();
    if (!edit) return;
    const { id, ...form } = edit;
    const before = id ? clients.find((c) => c.id === id) : undefined;
    const renamed = !before || nameKey(before.name) !== nameKey(form.name);
    // Only new or renamed clients are checked; editing other details of an existing (even duplicate-name) record is allowed.
    const twin = renamed ? clients.find((c) => c.id !== id && nameKey(c.name) === nameKey(form.name)) : undefined;
    if (twin) { toast.error(`Client already exists: ${up(twin.name)}. Open it below instead.`); return; }
    const aliasOf = renamed ? aliases.find((a) => nameKey(a.raw_name) === nameKey(form.name) && a.client_id !== id) : undefined;
    if (aliasOf) {
      const owner = clients.find((c) => c.id === aliasOf.client_id);
      toast.error(`${up(form.name)} is an Excel name of ${up(owner?.name ?? "another client")}. Open that client instead.`); return;
    }
    // Existing names are kept exactly as stored unless the seller changes them.
    const row = { ...form, name: renamed ? upName(form.name) : before!.name, state: form.state || null, gstin: form.gstin.trim().toUpperCase() || null };
    const res = id ? await supabase.from("clients").update(row).eq("id", id) : await supabase.from("clients").insert(row);
    if (res.error) {
      if (isDupClientError(res.error)) {
        await qc.invalidateQueries({ queryKey: ["clients"] });
        toast.error("Client already exists. The list was refreshed — open the existing client shown under the name.");
        return;
      }
      toast.error(errMsg(res.error)); return;
    }
    // Rename: keep the old name as an Excel name so future imports still find this client.
    if (before && renamed && aliasData?.available) {
      const err = await addAlias(before.name, before.id, aliases);
      if (err) toast.warning(`Renamed, but the old name couldn't be kept for imports: ${err}`);
      else toast.success(`Future Excel files with "${up(before.name)}" will go to ${upName(form.name)}`);
      qc.invalidateQueries({ queryKey: ["client_aliases"] });
    }
    toast.success("Client saved");
    setEdit(null);
    qc.invalidateQueries({ queryKey: ["clients"] });
  }
  async function toggle(c: Client) {
    const { error } = await supabase.from("clients").update({ active: !c.active }).eq("id", c.id);
    if (error) { toast.error(errMsg(error)); return; }
    qc.invalidateQueries({ queryKey: ["clients"] });
  }
  async function remove(c: Client) {
    if (!confirm(`Delete ${c.name}? This also deletes their shipments.`)) return;
    const { error } = await supabase.from("clients").delete().eq("id", c.id);
    if (error) { toast.error("Cannot delete a client that has invoices. Mark inactive instead."); return; }
    qc.invalidateQueries({ queryKey: ["clients"] });
  }
  const list = clients.filter((c) => c.name.toLowerCase().includes(q.toLowerCase()));
  const activeCount = clients.filter((c) => c.active).length;
  const dupGroups = [...groupClients(clients).values()].filter((g) => g.length > 1);

  return (
    <div>
      <PageHead title={`Clients (${activeCount} active)`}>
        <Input placeholder="Search" value={q} onChange={(e) => setQ(e.target.value)} className="w-48" />
        <Button onClick={() => setEdit({ ...empty })}>Add client</Button>
      </PageHead>
      {dupGroups.length > 0 && (
        <div className="mb-4 rounded-xl border border-destructive/50 bg-card p-4 text-sm">
          <p className="font-medium">Some clients share the same name. They are kept as separate records — check you bill the right one.</p>
          {dupGroups.map((g) => (
            <ul key={g[0]!.id} className="mt-2 space-y-1">
              {g.map((c) => (
                <li key={c.id} className="flex flex-wrap items-center gap-2">
                  <span className="font-medium">{up(c.name)}</span><span className="text-muted-foreground">{clientDetails(c) || "No details"}</span>
                  <Button size="sm" variant="outline" onClick={() => setEdit({ id: c.id, name: c.name, phone: c.phone ?? "", email: c.email ?? "", gstin: c.gstin ?? "", address: c.address ?? "", state: c.state ?? "", is_gst: c.is_gst, active: c.active })}>Open</Button>
                </li>
              ))}
            </ul>
          ))}
        </div>
      )}
      <div className="overflow-x-auto rounded-xl border bg-card">
        <table className="w-full text-sm">
          <thead className="bg-muted text-left"><tr><th className="p-3">Name</th><th className="p-3">Phone</th><th className="p-3">GSTIN</th><th className="p-3">State</th><th className="p-3">Type</th><th className="p-3">Active</th><th className="p-3" /></tr></thead>
          <tbody>
            {list.map((c) => (
              <tr key={c.id} className="border-t">
                <td className="p-3 font-medium">{up(c.name)}</td><td className="p-3">{c.phone}</td><td className="p-3">{c.gstin}</td><td className="p-3">{up(c.state)}</td>
                <td className="p-3">{c.is_gst ? "GST" : "Non-GST"}</td>
                <td className="p-3"><Switch checked={c.active} onCheckedChange={() => toggle(c)} /></td>
                <td className="p-3 text-right whitespace-nowrap">
                  <Button size="sm" variant="ghost" onClick={() => setEdit({ ...empty, ...Object.fromEntries(Object.entries(c).map(([k, v]) => [k, v ?? ""])), is_gst: c.is_gst, active: c.active } as typeof empty & { id: string })}>Edit</Button>
                  <Button size="sm" variant="ghost" onClick={() => remove(c)}>Delete</Button>
                </td>
              </tr>
            ))}
            {!list.length && <tr><td colSpan={7} className="p-6 text-center text-muted-foreground">No clients yet.</td></tr>}
          </tbody>
        </table>
      </div>
      <Dialog open={!!edit} onOpenChange={(o) => !o && setEdit(null)}>
        <DialogContent>
          <DialogHeader><DialogTitle>{edit?.id ? "Edit client" : "Add client"}</DialogTitle></DialogHeader>
          {edit && (
            <form onSubmit={save} className="grid gap-3 sm:grid-cols-2">
              {(["name", "phone", "email", "gstin", "state", "address"] as const).map((f) => (
                <div key={f} className={f === "address" ? "sm:col-span-2" : ""}>
                  <Label className="capitalize">{f === "gstin" ? "GSTIN" : f}</Label>
                    {f === "gstin"
                      ? <GstinVerification key={edit.id || "new-client"} value={edit.gstin} onChange={(v) => setEdit({ ...edit, gstin: v })} onApply={(patch) => setEdit((current) => current ? { ...current, ...patch } : null)} />
                      : f === "state"
                    ? <StateSelect value={edit.state} onChange={(v) => setEdit({ ...edit, state: v })} />
                    : <Input required={f === "name"} className={f === "name" ? "uppercase" : undefined} value={edit[f]} onChange={(e) => setEdit({ ...edit, [f]: e.target.value })} />}
                  {f === "name" && (() => {
                    const k = nameKey(edit.name);
                    const orig = edit.id ? clients.find((c) => c.id === edit.id) : undefined;
                    const twins = clients.filter((c) => c.id !== edit.id && nameKey(c.name) === k);
                    const twin = orig && nameKey(orig.name) === k ? undefined : twins[0];
                    const like = k.length >= 2 ? clients.filter((c) => c.id !== edit.id && c !== twin && nameKey(c.name).includes(k)).slice(0, 5) : [];
                    if (!twin && !like.length) return null;
                    const open = (c: Client) => setEdit({ id: c.id, name: c.name, phone: c.phone ?? "", email: c.email ?? "", gstin: c.gstin ?? "", address: c.address ?? "", state: c.state ?? "", is_gst: c.is_gst, active: c.active });
                    return (
                      <div className="mt-1 space-y-1 text-xs">
                        {twin && <p className="text-destructive">{up(twin.name)} already exists — it can't be added again.</p>}
                        <div className="flex flex-wrap gap-1">
                          {[...(twin ? [twin] : []), ...like].map((c) => (
                            <button type="button" key={c.id} className="rounded-full border px-2 py-0.5 hover:bg-muted" onClick={() => open(c)}>Open {up(c.name)} ({clientDetails(c)})</button>
                          ))}
                        </div>
                      </div>
                    );
                  })()}
                </div>
              ))}
              {edit.id && aliasData?.available && (
                <div className="sm:col-span-2 rounded-lg border p-2 text-sm">
                  <Label>Excel names for this client</Label>
                  <p className="text-xs text-muted-foreground">Rows in your Excel files with these names are added to this client. Old names are kept automatically when you rename.</p>
                  <div className="mt-2 flex flex-wrap gap-1">
                    {aliases.filter((a) => a.client_id === edit.id).map((a) => (
                      <span key={a.alias_norm} className="inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-xs uppercase">
                        {a.raw_name}
                        <button type="button" aria-label={`Remove ${a.raw_name}`} className="text-muted-foreground hover:text-destructive" onClick={async () => {
                          if (!confirm(`Stop matching "${up(a.raw_name)}" to this client in future imports?`)) return;
                          const { error } = await supabase.from("client_name_mappings").delete().eq("alias_norm", a.alias_norm);
                          if (error) toast.error(errMsg(error)); else qc.invalidateQueries({ queryKey: ["client_aliases"] });
                        }}>×</button>
                      </span>
                    ))}
                  </div>
                  <div className="mt-2 flex gap-2">
                    <Input className="uppercase" placeholder="Add Excel name, e.g. ABC TRADERS" value={newAlias} maxLength={200} onChange={(e) => setNewAlias(e.target.value)} />
                    <Button type="button" variant="outline" disabled={!newAlias.trim()} onClick={async () => {
                      const other = clients.find((c) => c.id !== edit.id && nameKey(c.name) === nameKey(newAlias));
                      if (other) { toast.error(`${up(other.name)} is a separate client with this name`); return; }
                      const err = await addAlias(newAlias, edit.id!, aliases);
                      if (err) { toast.error(err); return; }
                      setNewAlias(""); qc.invalidateQueries({ queryKey: ["client_aliases"] });
                    }}>Add</Button>
                  </div>
                </div>
              )}
              <label className="flex items-center gap-2 text-sm"><Switch checked={edit.is_gst} onCheckedChange={(v) => setEdit({ ...edit, is_gst: v })} />Charge GST</label>
              <label className="flex items-center gap-2 text-sm"><Switch checked={edit.active} onCheckedChange={(v) => setEdit({ ...edit, active: v })} />Active</label>
              <Button className="sm:col-span-2">Save</Button>
            </form>
          )}
        </DialogContent>
      </Dialog>
    </div>
  );
}
