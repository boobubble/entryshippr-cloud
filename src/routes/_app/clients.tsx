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

  async function save(e: React.FormEvent) {
    e.preventDefault();
    if (!edit) return;
    const { id, ...form } = edit;
    const row = { ...form, state: form.state || null, gstin: form.gstin.trim().toUpperCase() || null };
    const res = id ? await supabase.from("clients").update(row).eq("id", id) : await supabase.from("clients").insert(row);
    if (res.error) { toast.error(errMsg(res.error)); return; }
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

  return (
    <div>
      <PageHead title={`Clients (${activeCount} active)`}>
        <Input placeholder="Search" value={q} onChange={(e) => setQ(e.target.value)} className="w-48" />
        <Button onClick={() => setEdit({ ...empty })}>Add client</Button>
      </PageHead>
      <div className="overflow-x-auto rounded-xl border bg-card">
        <table className="w-full text-sm">
          <thead className="bg-muted text-left"><tr><th className="p-3">Name</th><th className="p-3">Phone</th><th className="p-3">GSTIN</th><th className="p-3">State</th><th className="p-3">Type</th><th className="p-3">Active</th><th className="p-3" /></tr></thead>
          <tbody>
            {list.map((c) => (
              <tr key={c.id} className="border-t">
                <td className="p-3 font-medium">{c.name}</td><td className="p-3">{c.phone}</td><td className="p-3">{c.gstin}</td><td className="p-3">{c.state}</td>
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
                  {f === "state"
                    ? <StateSelect value={edit.state} onChange={(v) => setEdit({ ...edit, state: v })} />
                    : <Input required={f === "name"} value={edit[f]} onChange={(e) => setEdit({ ...edit, [f]: e.target.value })} />}
                </div>
              ))}
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
