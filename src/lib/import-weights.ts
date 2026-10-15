// Pure helpers for the Excel shipment importer (no React / Supabase here, so they are unit-testable).

export type ShipmentType = "DOX" | "NON-DOX";
export type FieldKey = "awb" | "date" | "client" | "type" | "destination" | "service" | "pieces" | "amount" | "w1" | "w2" | "w3" | "w4";
export type Mapping = Record<FieldKey, number | null>; // column index (0 = A) or null

export const FIELD_LABELS: Record<FieldKey, string> = {
  awb: "AWB / tracking no.", date: "Shipment date", client: "Client", type: "Shipment type (DOX / NON-DOX)",
  destination: "Destination", service: "Service", pieces: "Pieces", amount: "Amount (optional)",
  w1: "Weight 1 (col F)", w2: "Weight 2 (col G)", w3: "Weight 3 (col H)", w4: "Weight 4 (col T)",
};
export const REQUIRED: FieldKey[] = ["awb", "client"];

const SYNONYMS: Partial<Record<FieldKey, string[]>> = {
  awb: ["awb", "awb no", "awb no.", "awb number", "awbno", "tracking", "tracking no", "tracking number", "consignment", "consignment no", "cn no", "cnno", "docket", "docket no"],
  date: ["date", "booking date", "ship date", "shipment date", "bkg date", "book date"],
  client: ["client", "client name", "customer", "customer name", "party", "party name", "consignor", "sender", "shipper"],
  type: ["type", "shipment type", "dox/non dox", "dox / non dox", "doc type", "doc/non doc", "dox", "content type"],
  destination: ["destination", "dest", "city", "to", "dest city", "destination city"],
  service: ["service", "mode", "product", "service type"],
  pieces: ["pieces", "pcs", "qty", "no of pcs", "nop"],
  amount: ["amount", "charge", "freight", "rate", "total"],
};

export const colLetter = (i: number) => {
  let s = ""; i += 1;
  while (i > 0) { const m = (i - 1) % 26; s = String.fromCharCode(65 + m) + s; i = Math.floor((i - 1) / 26); }
  return s;
};

const norm = (h: unknown) => String(h ?? "").trim().toLowerCase().replace(/\s+/g, " ");

/** Guess a mapping from header names; weights default to columns F, G, H, T. */
export function detectMapping(headers: unknown[]): Mapping {
  const n = headers.map(norm);
  const find = (k: FieldKey) => { const syn = SYNONYMS[k] ?? []; const i = n.findIndex((h) => h && syn.includes(h)); return i >= 0 ? i : null; };
  const has = (i: number) => i < headers.length;
  return {
    awb: find("awb"), date: find("date"), client: find("client"), type: find("type"), destination: find("destination"),
    service: find("service"), pieces: find("pieces"), amount: find("amount"),
    w1: has(5) ? 5 : null, w2: has(6) ? 6 : null, w3: has(7) ? 7 : null, w4: has(19) ? 19 : null,
  };
}

export function parseType(v: unknown): ShipmentType | null {
  const s = norm(v).replace(/[^a-z]/g, "");
  if (!s) return null;
  if (s.startsWith("non") || s === "ndox" || s === "spx" || s === "parcel") return "NON-DOX";
  if (s === "dox" || s === "doc" || s === "docs" || s === "document" || s === "documents" || s === "d") return "DOX";
  return null;
}

/** Positive finite number or null (empty, invalid, zero and negative values are ignored). */
export function parseWeight(v: unknown): number | null {
  if (v === null || v === undefined || v === "") return null;
  const n = typeof v === "number" ? v : Number(String(v).replace(/,/g, "").trim());
  return Number.isFinite(n) && n > 0 ? n : null;
}

/** Billing weight = MAX of valid weights, in the shipment's own unit (g for DOX, kg for NON-DOX). */
export function billingWeight(values: unknown[]): number | null {
  const ok = values.map(parseWeight).filter((x): x is number => x !== null);
  return ok.length ? Math.max(...ok) : null;
}

export const unitOf = (t: ShipmentType) => (t === "DOX" ? "g" : "kg");
/** Kilograms for rate-card matching (rate cards are in kg). */
export const toKg = (t: ShipmentType, w: number) => (t === "DOX" ? w / 1000 : w);
export const fmtWeight = (t: ShipmentType, w: number) => `${+w.toFixed(3)} ${unitOf(t)}`;
