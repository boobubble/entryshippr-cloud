import { inr } from "@/lib/supabase";
import { up } from "@/lib/text";

type BusinessDetails = {
  business_name?: string | null;
  address?: string | null;
  state?: string | null;
  gstin?: string | null;
  phone?: string | null;
  email?: string | null;
};

type ClientDetails = Omit<BusinessDetails, "business_name"> & { name?: string | null };
type Money = number | string;

export type InvoiceDocumentProps = {
  seller?: BusinessDetails | null | undefined;
  invoice: {
    invoice_no: string;
    invoice_date: string;
    period_from: string;
    period_to: string;
    kind: string;
    status: string;
    bill_to_name?: string | null;
    bill_to_gstin?: string | null;
    bill_to_state?: string | null;
    bill_to_address?: string | null;
    clients?: ClientDetails | null;
    subtotal: Money;
    igst: Money;
    cgst: Money;
    sgst: Money;
    total: Money;
  };
  shipments: {
    id: string;
    ship_date: string;
    awb: string;
    receiver_name?: string | null;
    consignee_name?: string | null;
    receiver_phone?: string | null;
    destination?: string | null;
    service: string;
    billing_weight?: Money | null;
    weight_unit?: string | null;
    weight: Money;
    shipment_type?: string | null;
    amount: Money;
  }[];
};

/** Invoice dates are shown as DD/MM/YY (e.g. 2026-10-15 -> 15/10/26). */
export const invDate = (d?: string | null) => {
  const m = String(d ?? "").match(/^(\d{4})-(\d{2})-(\d{2})/);
  return m ? `${m[3]}/${m[2]}/${m[1]!.slice(2)}` : (d ?? "");
};
// A value made only of digits/phone symbols is a number, never a receiver name.
const receiverOf = (s: { receiver_name?: string | null; consignee_name?: string | null }) => {
  const n = s.receiver_name?.trim() || s.consignee_name?.trim() || "";
  return n && !isPhone(n) ? n : "—";
};
const isPhone = (v: string) => /^[+\d\s()-]{6,}$/.test(v);

export function InvoiceDocument({ seller, invoice: inv, shipments }: InvoiceDocumentProps) {
  const client = inv.clients;
  // Keep the existing snapshot fallback: a layout change must not alter billed details.
  const billTo = inv.bill_to_name
    ? { name: inv.bill_to_name, gstin: inv.bill_to_gstin, state: inv.bill_to_state, address: inv.bill_to_address }
    : client;

  return (
    <article className="invoice-document border bg-card text-card-foreground" aria-label={`Invoice ${inv.invoice_no}`}>
      <header className="invoice-business border-b pb-5 text-center">
        <h1 className="text-2xl font-bold">{seller?.business_name}</h1>
        {seller?.address && <p className="mt-2 whitespace-pre-line">{seller.address}</p>}
        {seller?.state && <p>{up(seller.state)}</p>}
        <div className="mt-2 flex flex-wrap justify-center gap-x-5 gap-y-1">
          {seller?.gstin && <span>GSTIN: {seller.gstin}</span>}
          {seller?.phone && <span>Ph: {seller.phone}</span>}
          {seller?.email && <span>{seller.email}</span>}
        </div>
      </header>

      <section className="invoice-parties grid grid-cols-2 gap-8 py-6">
        <div>
          <h2 className="mb-2 text-xs font-bold">BILL TO</h2>
          <p className="font-bold">{up(billTo?.name)}</p>
          {billTo?.address && <p className="mt-1 whitespace-pre-line">{billTo.address}</p>}
          {billTo?.state && <p>{up(billTo.state)}</p>}
          {billTo?.gstin && <p className="mt-1">GSTIN: {billTo.gstin}</p>}
          {client?.phone && <p>Ph: {client.phone}</p>}
          {client?.email && <p>{client.email}</p>}
        </div>
        <div className="text-right">
          <h2 className="mb-2 text-base font-bold">{inv.kind === "gst" ? "TAX INVOICE" : "INVOICE"}</h2>
          {inv.status === "cancelled" && <p className="mb-2 font-bold text-destructive">CANCELLED</p>}
          <p><span className="font-semibold">Invoice number:</span> {inv.invoice_no}</p>
          <p><span className="font-semibold">Invoice date:</span> {invDate(inv.invoice_date)}</p>
          <p className="mt-2 font-semibold">Billing period</p>
          <p>{invDate(inv.period_from)} to {invDate(inv.period_to)}</p>
        </div>
      </section>

      <table className="invoice-shipments w-full table-fixed text-left">
        <colgroup><col className="invoice-date-column" /><col className="invoice-awb-column" /><col /><col /><col className="invoice-service-column" /><col className="invoice-weight-column" /><col className="invoice-amount-column" /></colgroup>
        <thead className="border-y bg-muted">
          <tr><th>Date</th><th>AWB</th><th>Receiver Name</th><th>Destination</th><th>Service</th><th>Weight</th><th className="text-right">Amount</th></tr>
        </thead>
        <tbody>
          {shipments.map((s) => (
            <tr key={s.id} className="border-b align-top">
              <td>{invDate(s.ship_date)}</td>
              <td className="font-mono">{s.awb}</td>
              <td>{receiverOf(s)}{s.receiver_phone?.trim() && <span className="mt-1 block text-xs">Ph: {s.receiver_phone.trim()}</span>}</td>
              <td>{up(s.destination)}</td>
              <td>{s.service}</td>
              <td>{s.billing_weight != null && s.weight_unit ? `${+s.billing_weight} ${s.weight_unit}` : `${s.weight} kg`}{s.shipment_type && <span className="mt-1 block text-xs">{s.shipment_type}</span>}</td>
              <td className="text-right tabular-nums">{inr(Number(s.amount))}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <footer className="invoice-footer pt-5">
        <dl className="ml-auto w-64 space-y-2 tabular-nums">
          <div className="flex justify-between gap-4"><dt>Subtotal</dt><dd>{inr(Number(inv.subtotal))}</dd></div>
          {inv.kind === "gst" && Number(inv.igst) > 0 && <div className="flex justify-between gap-4"><dt>IGST 18%</dt><dd>{inr(Number(inv.igst))}</dd></div>}
          {inv.kind === "gst" && Number(inv.cgst) > 0 && <div className="flex justify-between gap-4"><dt>CGST 9%</dt><dd>{inr(Number(inv.cgst))}</dd></div>}
          {inv.kind === "gst" && Number(inv.sgst) > 0 && <div className="flex justify-between gap-4"><dt>SGST 9%</dt><dd>{inr(Number(inv.sgst))}</dd></div>}
          <div className="flex justify-between gap-4 border-t pt-3 text-base font-bold"><dt>Grand Total</dt><dd>{inr(Number(inv.total))}</dd></div>
        </dl>
        <p className="mt-10 border-t pt-4 text-xs text-muted-foreground">SAC 996812 · Courier services. This is a computer-generated invoice.</p>
      </footer>
    </article>
  );
}