import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { errMsg } from "@/lib/hooks";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

function currentFy() {
  const d = new Date();
  const y = d.getMonth() >= 3 ? d.getFullYear() : d.getFullYear() - 1;
  return `${y}-${String((y + 1) % 100).padStart(2, "0")}`;
}

type Series = { fy: string; kind: "gst" | "nongst"; prefix: string; next_number: number };

export function InvoiceSeries() {
  const qc = useQueryClient();
  const fy = currentFy();
  const { data: rows = [] } = useQuery({
    queryKey: ["invoice_series"],
    queryFn: async () => {
      const { data, error } = await supabase.from("invoice_series").select("*").order("fy", { ascending: false });
      if (error) throw error;
      return data as Series[];
    },
  });
  const [f, setF] = useState<Record<string, { prefix: string; next: string }>>({});
  const get = (kind: "gst" | "nongst") => {
    const row = rows.find((r) => r.fy === fy && r.kind === kind);
    return f[kind] ?? { prefix: row?.prefix ?? (kind === "gst" ? "GST" : "BOS"), next: String(row?.next_number ?? 1) };
  };
  async function save(kind: "gst" | "nongst") {
    const v = get(kind);
    const { error } = await supabase.rpc("set_invoice_series", { p_fy: fy, p_kind: kind, p_prefix: v.prefix.trim(), p_next_number: Number(v.next) });
    if (error) { toast.error(errMsg(error)); return; }
    toast.success("Numbering saved");
    qc.invalidateQueries({ queryKey: ["invoice_series"] });
  }
  return (
    <div className="mt-6 max-w-2xl rounded-xl border bg-card p-6">
      <h2 className="text-lg font-semibold">Invoice numbering · FY {fy}</h2>
      <p className="mb-4 text-sm text-muted-foreground">GST and Non-GST invoices have separate number series that restart each financial year. The next number can only move forward.</p>
      {(["gst", "nongst"] as const).map((k) => (
        <div key={k} className="mb-3 grid items-end gap-3 sm:grid-cols-4">
          <div className="font-medium sm:pb-2">{k === "gst" ? "GST invoices" : "Non-GST bills"}</div>
          <div><Label>Prefix</Label><Input value={get(k).prefix} onChange={(e) => setF({ ...f, [k]: { ...get(k), prefix: e.target.value } })} /></div>
          <div><Label>Next number</Label><Input type="number" min={1} value={get(k).next} onChange={(e) => setF({ ...f, [k]: { ...get(k), next: e.target.value } })} /></div>
          <Button variant="outline" onClick={() => save(k)}>Save</Button>
        </div>
      ))}
      <p className="text-xs text-muted-foreground">Example: {get("gst").prefix}/{fy}/{String(get("gst").next).padStart(4, "0")}</p>
    </div>
  );
}
