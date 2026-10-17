// Zone-wise slab pricing (pure; unit-tested). DOX weights in grams, NON-DOX in kilograms.
import type { ShipmentType } from "./import-weights";

export type Service = "Standard" | "Surface" | "Air" | "Fast";
export const SERVICES: Service[] = ["Standard", "Surface", "Air", "Fast"];
const SERVICE_MATRIX: Record<ShipmentType, readonly Service[]> = {
  DOX: ["Standard", "Fast"],
  "NON-DOX": ["Surface", "Air", "Fast"],
};
export const servicesFor = (type: ShipmentType) => SERVICE_MATRIX[type];
export function serviceForType(type: ShipmentType, service: Service): Service {
  return servicesFor(type).includes(service) ? service : type === "DOX" ? "Standard" : "Surface";
}
export type Zone = { id: string; name: string; destinations: string[]; sort_order: number };
export type Slab = {
  id?: string; client_id: string | null; shipment_type: ShipmentType; service: Service;
  min_weight: number; max_weight: number; rates: Record<string, number>; sort_order: number;
};
export type EditSlab = { key: string; min: string; max: string; rates: Record<string, string> };

export function normService(s: unknown, type: ShipmentType | null): Service | null {
  const aliases: Record<string, Service> = { standard: "Standard", air: "Air", surface: "Surface", ground: "Surface", fast: "Fast", express: "Fast", priority: "Fast" };
  const service = aliases[String(s ?? "").trim().toLowerCase()];
  return type && service && servicesFor(type).includes(service) ? service : null;
}

const n = (s: string) => (s.trim() === "" ? NaN : Number(s));

/** Returns one message per problem; empty array = valid. */
export function validateSlabs(slabs: EditSlab[], unit: "g" | "kg"): string[] {
  const errs: string[] = [];
  const parsed = slabs.map((s, i) => ({ i, mn: n(s.min), mx: n(s.max), s }));
  parsed.forEach(({ i, mn, mx, s }) => {
    if (!Number.isFinite(mn) || mn < 0) errs.push(`Slab ${i + 1}: enter a valid "from" weight (0 or more ${unit})`);
    else if (!Number.isFinite(mx)) errs.push(`Slab ${i + 1}: enter a valid "to" weight`);
    else if (mx <= mn) errs.push(`Slab ${i + 1}: "to" must be more than "from"`);
    for (const [, v] of Object.entries(s.rates)) if (v.trim() !== "" && !(Number(v) > 0)) { errs.push(`Slab ${i + 1}: rates must be more than ₹0`); break; }
  });
  const ok = parsed.filter((p) => Number.isFinite(p.mn) && Number.isFinite(p.mx) && p.mx > p.mn).sort((a, b) => a.mn - b.mn);
  for (let k = 1; k < ok.length; k++) {
    const prev = ok[k - 1]; const current = ok[k];
    if (prev && current && current.mn < prev.mx) errs.push(`Slabs ${prev.i + 1} and ${current.i + 1} overlap (${prev.s.min}–${prev.s.max} and ${current.s.min}–${current.s.max} ${unit})`);
  }
  return errs;
}

export type RateResult = { ok: true; rate: number; zone: string; slab: string } | { ok: false; reason: string; noCard?: boolean };

/** Billed weight — must match PostgreSQL shipment_rate(): DOX ceil(grams), NON-DOX ceil to 0.001 kg. */
export function billedWeight(type: ShipmentType, w: number) {
  const r = (x: number) => Math.round(x * 1e6) / 1e6; // strip float noise before ceil
  return type === "DOX" ? Math.ceil(r(w)) : Math.ceil(r(w * 1000)) / 1000;
}

/** weight is the final billing weight in the shipment's own unit. Client slabs first, then default slabs. */
/** zone = the seller's zone for the shipment city (from register_cities), or null with zoneReason. */
export function matchRate(
  slabs: Slab[],
  q: { clientId: string | null; type: ShipmentType; service: Service; zone: { id: string; name: string } | null; zoneReason?: string; weight: number },
): RateResult {
  const unit = q.type === "DOX" ? "g" : "kg";
  const pick = (cid: string | null) => slabs.filter((s) => s.client_id === cid && s.shipment_type === q.type && s.service === q.service);
  let pool = q.clientId ? pick(q.clientId) : [];
  if (!pool.length) pool = pick(null);
  if (!pool.length) return { ok: false, reason: `No ${q.type} ${q.service} rate card`, noCard: true };
  const zone = q.zone;
  if (!zone) return { ok: false, reason: q.zoneReason || "City has no zone" };
  const w = billedWeight(q.type, q.weight);
  const slab = [...pool].sort((a, b) => Number(a.min_weight) - Number(b.min_weight))
    .find((s) => w >= Number(s.min_weight) && w <= Number(s.max_weight));
  const label = (s: Slab) => `${+s.min_weight}–${+s.max_weight} ${unit}`;
  if (!slab) return { ok: false, reason: `No slab covers ${w} ${unit}` };
  const rate = slab.rates[zone.id];
  if (rate == null || !Number.isFinite(Number(rate))) return { ok: false, reason: `No ${zone.name} rate for ${label(slab)}` };
  const r = Math.round(Number(rate) * 100) / 100;
  if (r <= 0) return { ok: false, reason: `${zone.name} rate for ${label(slab)} is ₹0` };
  return { ok: true, rate: r, zone: zone.name, slab: label(slab) };
}
