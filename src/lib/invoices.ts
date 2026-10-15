import { supabase } from "./supabase";

export type InvoiceLine = {
  id: string; shipment_id: string | null; position: number; ship_date: string; awb: string;
  receiver_name: string | null; destination: string | null; service: string | null; shipment_type: string | null;
  weight: number; rate: number; amount: number; declared_value: number | null;
  original_weight: number; original_rate: number | null; original_amount: number;
};
export type InvoiceCharge = { id: string; position: number; code: string; label: string; mode: "fixed" | "percent"; base: "none" | "subtotal" | "declared_value"; value: number; amount: number };

/** Reads an invoice with its stored lines and charges (read-only; all writes go through RPCs). */
export async function loadInvoice(id: string) {
  const { data: inv, error } = await supabase.from("invoices").select("*, clients(*)").eq("id", id).single();
  if (error) throw error;
  const [{ data: lines, error: e1 }, { data: charges, error: e2 }] = await Promise.all([
    supabase.from("invoice_lines").select("*").eq("invoice_id", id).order("position"),
    supabase.from("invoice_charges").select("*").eq("invoice_id", id).order("position"),
  ]);
  if (e1) throw e1;
  if (e2) throw e2;
  let ships: Record<string, unknown>[] = [];
  if (!lines?.length) {
    // Legacy invoices (created before the editor) have no lines: show their linked shipments.
    const { data } = await supabase.from("shipments").select("*").eq("invoice_id", id).order("ship_date");
    ships = data || [];
  }
  return { inv, lines: (lines || []) as InvoiceLine[], charges: (charges || []) as InvoiceCharge[], ships };
}

/** Map stored invoice lines to the shape the invoice document prints. */
export const linesForDocument = (lines: InvoiceLine[]) =>
  lines.map((l) => ({
    id: l.id, ship_date: l.ship_date, awb: l.awb, receiver_name: l.receiver_name, destination: l.destination,
    service: l.service ?? "", weight: l.weight, shipment_type: l.shipment_type, amount: l.amount,
  }));
