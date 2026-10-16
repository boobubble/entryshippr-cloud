import { describe, expect, it } from "vitest";
import { checkSeries, previewAwb } from "@/components/AwbSeries";
import { nextAwb } from "@/routes/_app/entry";

const f = (prefix: string, start: string, digits: string) => ({ prefix, start, digits, active: true });

describe("AWB series rules", () => {
  it("keeps leading zeros to the digit width", () => expect(previewAwb(f("del/", "7", "6"))).toBe("DEL/000007"));
  it("rejects start numbers longer than the digit width", () => expect(checkSeries(f("A", "1234567", "6"))).not.toBeNull());
  it("rejects more than 18 digits", () => expect(checkSeries(f("A", "1", "19"))).not.toBeNull());
  it("rejects prefix characters outside A-Z 0-9 / -", () => expect(checkSeries(f("A_B", "1", "6"))).not.toBeNull());
  it("accepts a valid series", () => expect(checkSeries(f("DEL-", "1", "6"))).toBeNull());
  it("fallback suggestion keeps leading zeros", () => expect(nextAwb("X0099")).toBe("X0100"));
});
