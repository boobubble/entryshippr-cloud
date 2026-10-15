import { describe, it, expect } from "vitest";
import { billingWeight, parseType, parseWeight, toKg, fmtWeight, detectMapping, colLetter } from "@/lib/import-weights";

describe("weights", () => {
  it("DOX: max of grams, ignores empty/zero/invalid", () => {
    const w = billingWeight(["250", "", 0, "abc", 480, null])!;
    expect(w).toBe(480);
    expect(fmtWeight("DOX", w)).toBe("480 g");
    expect(toKg("DOX", w)).toBe(0.48);
  });
  it("NON-DOX: max of kilograms", () => {
    const w = billingWeight([2.5, "3.25", "1,0", 0])!;
    expect(w).toBe(10); // "1,0" -> 10 after removing thousands separators
    expect(billingWeight([2.5, "3.25", 0, ""])).toBe(3.25);
    expect(toKg("NON-DOX", 3.25)).toBe(3.25);
    expect(fmtWeight("NON-DOX", 3.25)).toBe("3.25 kg");
  });
  it("no valid weights -> null", () => {
    expect(billingWeight(["", 0, -1, "x"])).toBeNull();
    expect(parseWeight("-2")).toBeNull();
  });
  it("detects type", () => {
    expect(parseType("DOX")).toBe("DOX");
    expect(parseType("Non-Dox")).toBe("NON-DOX");
    expect(parseType("NON DOX")).toBe("NON-DOX");
    expect(parseType("")).toBeNull();
    expect(parseType("express")).toBeNull();
  });
  it("default mapping uses F,G,H,T for weights", () => {
    const h = Array.from({ length: 20 }, (_, i) => `c${i}`); h[0] = "AWB No"; h[2] = "Party Name";
    const m = detectMapping(h);
    expect(m.awb).toBe(0); expect(m.client).toBe(2);
    expect([m.w1, m.w2, m.w3, m.w4].map((i) => colLetter(i!))).toEqual(["F", "G", "H", "T"]);
  });
});
