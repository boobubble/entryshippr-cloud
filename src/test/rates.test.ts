import { describe, it, expect } from "vitest";
import { matchRate, validateSlabs, normService, servicesFor, serviceForType, type Slab } from "@/lib/rates";
import { normCity } from "@/lib/cities";

const Z = { z1: { id: "z1", name: "Local" }, z2: { id: "z2", name: "Metro" } };
const s = (p: Partial<Slab>): Slab => ({ client_id: "c1", shipment_type: "DOX", service: "Standard", min_weight: 0, max_weight: 100, rates: {}, sort_order: 0, ...p });
const slabs: Slab[] = [
  s({ min_weight: 0, max_weight: 100, rates: { z1: 20, z2: 35 } }),
  s({ min_weight: 101, max_weight: 250, rates: { z1: 30 } }),
  s({ shipment_type: "NON-DOX", min_weight: 0, max_weight: 0.5, rates: { z1: 60 } }),
  s({ shipment_type: "NON-DOX", min_weight: 0.5, max_weight: 1, rates: { z1: 90 } }),
  s({ client_id: null, service: "Fast", min_weight: 0, max_weight: 500, rates: { z2: 99 } }),
];
const q = { clientId: "c1", type: "DOX" as const, service: "Standard" as const, zone: Z.z1 as { id: string; name: string } | null, weight: 80 };

describe("matchRate", () => {
  it("DOX grams slab + zone", () => expect(matchRate(slabs, q)).toEqual({ ok: true, rate: 20, zone: "Local", slab: "0–100 g" }));
  it("rounds fractional grams up", () => expect(matchRate(slabs, { ...q, weight: 100.4 })).toMatchObject({ ok: true, rate: 30 }));
  it("NON-DOX kg, shared boundary goes to lower slab", () => {
    expect(matchRate(slabs, { ...q, type: "NON-DOX", weight: 0.5 })).toMatchObject({ ok: true, rate: 60 });
    expect(matchRate(slabs, { ...q, type: "NON-DOX", weight: 0.75 })).toMatchObject({ ok: true, rate: 90, slab: "0.5–1 kg" });
  });
  it("falls back to default (all clients) card", () => expect(matchRate(slabs, { ...q, service: "Fast", zone: Z.z2 })).toMatchObject({ ok: true, rate: 99 }));
  it("flags missing zone rate, unknown zone, no slab, no card", () => {
    expect(matchRate(slabs, { ...q, weight: 200, zone: Z.z2 })).toMatchObject({ ok: false });
    expect(matchRate(slabs, { ...q, zone: null, zoneReason: 'City "Pune" has no zone' })).toEqual({ ok: false, reason: 'City "Pune" has no zone' });
    expect(matchRate(slabs, { ...q, weight: 900 })).toMatchObject({ ok: false, reason: "No slab covers 900 g" });
    expect(matchRate(slabs, { ...q, clientId: "c9", service: "Standard", type: "NON-DOX", zone: Z.z2 })).toMatchObject({ ok: false });
  });
});

describe("validateSlabs", () => {
  const e = (min: string, max: string) => ({ key: min, min, max, rates: {} });
  it("accepts examples", () => {
    expect(validateSlabs([e("0", "100"), e("101", "250"), e("251", "500"), e("501", "1000")], "g")).toEqual([]);
    expect(validateSlabs([e("0", "0.5"), e("0.5", "1"), e("1", "2"), e("2", "5")], "kg")).toEqual([]);
  });
  it("rejects overlaps and invalid values", () => {
    expect(validateSlabs([e("0", "100"), e("50", "200")], "g")[0]).toMatch(/overlap/);
    expect(validateSlabs([e("10", "5")], "g")[0]).toMatch(/more than/);
    expect(validateSlabs([e("", "5")], "g")[0]).toMatch(/valid/);
    expect(validateSlabs([{ key: "a", min: "0", max: "1", rates: { z: "-3" } }], "kg")[0]).toMatch(/more than/);
  });
  it("maps Express to Fast without guessing a missing service", () => { expect(normService("Express", "DOX")).toBe("Fast"); expect(normService("", "DOX")).toBeNull(); });
});

import { billedWeight } from "@/lib/rates";
describe("billedWeight (matches PostgreSQL)", () => {
  it("rounds up, never down", () => {
    expect(billedWeight("DOX", 100.4)).toBe(101);
    expect(billedWeight("DOX", 100)).toBe(100);
    expect(billedWeight("NON-DOX", 0.5)).toBe(0.5);
    expect(billedWeight("NON-DOX", 0.5001)).toBe(0.501);
    expect(billedWeight("NON-DOX", 0.1 + 0.2)).toBe(0.3);
  });
  it("flags missing card distinctly", () => {
    expect(matchRate([], { clientId: null, type: "DOX", service: "Standard", zone: null, weight: 1 })).toMatchObject({ ok: false, noCard: true });
  });
});
describe("zero rates", () => {
  it("never prices at ₹0", () => {
    const sl = [{ client_id: null, shipment_type: "DOX" as const, service: "Standard" as const, min_weight: 0, max_weight: 10, rates: { z: 0 }, sort_order: 0 }];
    expect(matchRate(sl, { clientId: null, type: "DOX", service: "Standard", zone: { id: "z", name: "Z" }, weight: 5 })).toMatchObject({ ok: false });
    expect(validateSlabs([{ key: "k", min: "0", max: "1", rates: { z: "0" } }], "g")[0]).toMatch(/more than/);
  });
});

describe("normCity (matches PostgreSQL norm_city)", () => {
  it("normalises", () => {
    expect(normCity("  Navi-Mumbai, ")).toBe("navi mumbai");
    expect(normCity("NEW   DELHI")).toBe("new delhi");
    expect(normCity("")).toBe("");
  });
});

describe("Service matrix", () => {
  it("keeps DOX Standard and Fast", () => expect(servicesFor("DOX")).toEqual(["Standard", "Fast"]));
  it("offers NON-DOX Surface, Air and Fast separately", () => expect(servicesFor("NON-DOX")).toEqual(["Surface", "Air", "Fast"]));
  it.each([
    ["Air", "Air"], [" Surface ", "Surface"], ["Ground", "Surface"],
    ["Fast", "Fast"], ["Express", "Fast"], ["Priority", "Fast"],
  ] as const)("maps NON-DOX %s to %s", (raw, expected) => expect(normService(raw, "NON-DOX")).toBe(expected));
  it.each(["", "Unknown", "Air Express", "Standard"])("requires review for NON-DOX %s", (raw) => expect(normService(raw, "NON-DOX")).toBeNull());
  it.each(["Air", "Surface", "Ground"])("does not map DOX %s to another service", (raw) => expect(normService(raw, "DOX")).toBeNull());
  it("preserves DOX Standard mapping", () => expect(normService("standard", "DOX")).toBe("Standard"));
  it("requires a known shipment type", () => expect(normService("Air", null)).toBeNull());
  it("preserves Fast when changing type and resets incompatible choices", () => {
    expect(serviceForType("DOX", "Fast")).toBe("Fast");
    expect(serviceForType("NON-DOX", "Fast")).toBe("Fast");
    expect(serviceForType("DOX", "Air")).toBe("Standard");
    expect(serviceForType("NON-DOX", "Standard")).toBe("Surface");
  });
  const matrixSlabs = [
    s({ shipment_type: "NON-DOX", service: "Surface", max_weight: 1, rates: { z1: 60 } }),
    s({ shipment_type: "NON-DOX", service: "Air", max_weight: 1, rates: { z1: 120 } }),
    s({ shipment_type: "NON-DOX", service: "Fast", max_weight: 1, rates: { z1: 180 } }),
  ];
  it.each([["Surface", 60], ["Air", 120], ["Fast", 180]] as const)("prices NON-DOX %s only from its own card", (service, rate) => {
    expect(matchRate(matrixSlabs, { ...q, type: "NON-DOX", service, weight: 0.5 })).toMatchObject({ ok: true, rate });
  });
  it.each(["Surface", "Air", "Fast"] as const)("missing %s rates return review, not another service rate", (service) => {
    const other = matrixSlabs.filter((slab) => slab.service !== service);
    expect(matchRate(other, { ...q, type: "NON-DOX", service, weight: 0.5 })).toMatchObject({ ok: false, noCard: true });
  });
  it("uses only exact Air defaults, not client Surface or Fast", () => {
    const defaults = [...matrixSlabs.filter((slab) => slab.service !== "Air"), s({ client_id: null, shipment_type: "NON-DOX", service: "Air", max_weight: 1, rates: { z1: 150 } })];
    expect(matchRate(defaults, { ...q, type: "NON-DOX", service: "Air", weight: 0.5 })).toMatchObject({ ok: true, rate: 150 });
  });
  it("does not borrow another seller client's Air rates", () => {
    expect(matchRate([s({ client_id: "c2", shipment_type: "NON-DOX", service: "Air", max_weight: 1, rates: { z1: 120 } })], { ...q, type: "NON-DOX", service: "Air", weight: 0.5 })).toMatchObject({ ok: false, noCard: true });
  });
  it("preserves historical NON-DOX Standard pricing without offering it for new entries", () => {
    expect(matchRate(slabs, { ...q, type: "NON-DOX", weight: 0.5 })).toMatchObject({ ok: true, rate: 60 });
    expect(servicesFor("NON-DOX")).not.toContain("Standard");
  });
});
