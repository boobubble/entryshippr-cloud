import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { useProfile, errMsg } from "@/lib/hooks";
import { PageHead, appHead } from "@/components/PageHead";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { InvoiceSeries } from "@/components/InvoiceSeries";
import { StateSelect } from "@/components/StateSelect";

export const Route = createFileRoute("/_app/settings")({
  head: appHead("Business settings", "Your business details printed on invoices."),
  component: Settings,
});

const FIELDS = [["business_name", "Business name"], ["phone", "Phone"], ["gstin", "GSTIN"], ["state", "State"], ["address", "Address"]] as const;

function Settings() {
  const { data } = useProfile();
  const qc = useQueryClient();
  const [f, setF] = useState<Record<string, string>>({});
  useEffect(() => {
    if (data?.profile) setF(Object.fromEntries(FIELDS.map(([k]) => [k, (data.profile![k] as string) || ""])));
  }, [data]);
  async function save(e: React.FormEvent) {
    e.preventDefault();
    const row = { ...f, state: f["state"] || null, gstin: (f["gstin"] || "").trim().toUpperCase() || null };
    const { error } = await supabase.from("profiles").update(row).eq("id", data!.profile!.id);
    if (error) { toast.error(errMsg(error)); return; }
    toast.success("Saved");
    qc.invalidateQueries({ queryKey: ["profile"] });
  }
  return (
    <div>
      <PageHead title="Business settings" />
      <form onSubmit={save} className="grid max-w-2xl gap-4 rounded-xl border bg-card p-6 sm:grid-cols-2">
        {FIELDS.map(([k, l]) => (
          <div key={k} className={k === "address" ? "sm:col-span-2" : ""}><Label>{l}</Label>
            {k === "state"
              ? <StateSelect value={f[k] || ""} onChange={(v) => setF({ ...f, [k]: v })} />
              : <Input value={f[k] || ""} onChange={(e) => setF({ ...f, [k]: e.target.value })} />}
          </div>
        ))}
        <p className="text-xs text-muted-foreground sm:col-span-2">State decides CGST+SGST (same state as client) or IGST (different state) on GST invoices.</p>
        <Button className="sm:col-span-2" disabled={!data?.profile}>Save</Button>
      </form>
      <InvoiceSeries />
    </div>
  );
}
