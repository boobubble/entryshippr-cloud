import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { InvoiceDocument, type InvoiceDocumentProps } from "@/components/InvoiceDocument";

const invoice: InvoiceDocumentProps["invoice"] = {
  invoice_no: "INV-2026-001", invoice_date: "2026-10-15", period_from: "2026-10-01", period_to: "2026-10-15",
  kind: "gst", status: "issued", subtotal: 100, igst: 18, cgst: 0, sgst: 0, total: 118,
  bill_to_name: "Original billing client", bill_to_state: "Maharashtra", bill_to_gstin: "27AAAAA0000A1Z5", bill_to_address: "Original address",
  clients: { name: "Renamed sender", address: "New address" },
};
const shipment: InvoiceDocumentProps["shipments"][number] = {
  id: "shipment-1", ship_date: "2026-10-10", awb: "AWB-001", destination: "Mumbai", service: "Standard",
  weight: 0.05, billing_weight: 50, weight_unit: "g", shipment_type: "DOX", amount: 100,
};
function documentFor(inv = invoice, ships = [shipment]) {
  const html = renderToStaticMarkup(<InvoiceDocument seller={{ business_name: "Seller business", address: "Seller address" }} invoice={inv} shipments={ships} />);
  return new DOMParser().parseFromString(html, "text/html");
}

describe("Customer invoice layout", () => {
  it("uses exactly the requested shipment columns and no rate details", () => {
    const doc = documentFor();
    expect([...doc.querySelectorAll("thead th")].map((th) => th.textContent)).toEqual(["Date", "AWB", "Receiver Name", "Destination", "Service", "Weight", "Amount"]);
    expect(doc.body.textContent).not.toContain("Rate applied");
    expect(doc.querySelector("header h1")?.textContent).toBe("Seller business");
    expect(doc.querySelector("tbody tr td:nth-child(6)")?.textContent).toBe("50 gDOX");
  });
  it("shows only an actual receiver/consignee name, otherwise a dash", () => {
    expect(documentFor().querySelector("tbody tr td:nth-child(3)")?.textContent).toBe("—");
    expect(documentFor(invoice, [{ ...shipment, receiver_name: "Actual receiver" }]).querySelector("tbody tr td:nth-child(3)")?.textContent).toBe("Actual receiver");
    expect(documentFor(invoice, [{ ...shipment, consignee_name: "Actual consignee" }]).querySelector("tbody tr td:nth-child(3)")?.textContent).toBe("Actual consignee");
  });
  it("keeps billing snapshots and stored totals; shows only applicable taxes", () => {
    const text = documentFor().body.textContent;
    expect(text).toContain("ORIGINAL BILLING CLIENT");
    expect(text).toContain("Original address");
    expect(text).not.toContain("Renamed sender");
    expect(text).toContain("INV-2026-001");
    expect(text).toContain("IGST 18%");
    expect(text).not.toContain("CGST");
    expect(text).toContain("Grand Total₹118.00");
    expect(documentFor({ ...invoice, kind: "nongst" }).body.textContent).not.toContain("IGST");
  });
  it("keeps one totals footer for multi-page shipment tables", () => {
    const doc = documentFor(invoice, Array.from({ length: 100 }, (_, i) => ({ ...shipment, id: `${i}` })));
    expect(doc.querySelectorAll("tbody tr")).toHaveLength(100);
    expect(doc.querySelectorAll("thead")).toHaveLength(1);
    expect(doc.querySelectorAll("footer")).toHaveLength(1);
  });
});