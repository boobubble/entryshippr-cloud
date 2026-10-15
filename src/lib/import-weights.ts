// Pure helpers for the Excel shipment importer (no React / Supabase here, so they are unit-testable).

export type ShipmentType = "DOX" | "NON-DOX";
export type FieldKey = "awb" | "date" | "client" | "type" | "destination" | "service" | "pieces" | "amount" | "w1" | "w2" | "w3" | "w4";
export type Mapping = Record<FieldKey, number | null> & {
  /** "1308": weight + auditedWeight are grams for every row; NON-DOX rows convert them to kg. */
  format?: "1308" | undefined;
}; // column index (0 = A) or null

export const FIELD_LABELS: Record<FieldKey, string> = {
  awb: "AWB / tracking no.", date: "Shipment date", client: "Client", type: "Shipment type (DOX / NON-DOX)",
  destination: "Destination", service: "Service", pieces: "Pieces", amount: "Sheet amount (compare only)",
  w1: "Weight 1 (col F)", w2: "Weight 2 (col G)", w3: "Weight 3 (col H)", w4: "Weight 4 (col T)",
};
export const REQUIRED: FieldKey[] = ["awb", "client"];

const SYNONYMS: Partial<Record<FieldKey, string[]>> = {
  awb: ["documentno", "document no", "awb", "awb no", "awb no.", "awb number", "awbno", "tracking", "tracking no", "tracking number", "consignment", "consignment no", "cn no", "cnno", "docket", "docket no"],
  date: ["bookingdate", "date", "booking date", "ship date", "shipment date", "bkg date", "book date"],
  client: ["sendername", "sender name", "client", "client name", "customer", "customer name", "party", "party name", "consignor", "sender", "shipper"],
  type: ["shipmenttype", "type", "shipment type", "dox/non dox", "dox / non dox", "doc type", "doc/non doc", "dox", "content type"],
  destination: ["receivercity", "receiver city", "destination", "dest", "city", "to", "dest city", "destination city"],
  service: ["deliverypromise", "delivery promise", "service", "mode", "product", "service type"],
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
  const at = (h: string) => { const i = n.indexOf(h); return i >= 0 ? i : null; };
  if (n.includes("documentno") && n.includes("totalweight")) {
    return {
      awb: find("awb"), date: find("date"), client: find("client"), type: find("type"), destination: find("destination"),
      service: find("service"), pieces: null, amount: null,
      w1: at("weight"), w2: at("volumetricweight"), w3: at("auditedweight"), w4: at("totalweight"), format: "1308",
    };
  }
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
  if (!Number.isFinite(n)) return null;
  const r = Math.round(n * 1000) / 1000; // database stores 3 decimals
  return r > 0 ? r : null;
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

/** Sheet weights in the shipment's own unit. 1308 format: weight/auditedWeight are grams, so NON-DOX divides them by 1000
 *  (volumetricWeight and totalWeight are already kg for NON-DOX). */
export function rowWeights(map: Pick<Mapping, "format">, type: ShipmentType | null, raw: unknown[]): (number | null)[] {
  const w = raw.map(parseWeight);
  if (map.format === "1308" && type === "NON-DOX") {
    for (const i of [0, 2]) if (w[i] != null) w[i] = parseWeight(w[i]! / 1000);
  }
  return w;
}
