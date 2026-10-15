import { supabase } from "./supabase";

/** Mirrors public.norm_city() in PostgreSQL. */
export const normCity = (s: unknown) => String(s ?? "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();

export type CityStatus = "mapped" | "unmapped" | "ambiguous" | "invalid";
export type Candidate = { id: string; name: string; state: string | null };
export type CityRes = {
  input: string; status: CityStatus; city_id: string | null; city_name: string | null; state: string | null;
  zone_id: string | null; zone_name: string | null; reason: string | null; candidates: Candidate[] | null;
};

/** Resolves (and, with an active plan, registers) city names for the signed-in seller. */
export async function registerCities(names: string[]): Promise<Map<string, CityRes>> {
  const uniq = [...new Set(names.map((n) => n.trim()).filter(Boolean))];
  const out = new Map<string, CityRes>();
  for (let i = 0; i < uniq.length; i += 1000) {
    const { data, error } = await supabase.rpc("register_cities", { p_names: uniq.slice(i, i + 1000) });
    if (error) throw error;
    for (const r of data as CityRes[]) out.set(normCity(r.input), r);
  }
  return out;
}

export const zoneOf = (r: CityRes | undefined) =>
  r?.status === "mapped" && r.zone_id ? { zone: { id: r.zone_id, name: r.zone_name ?? "" } } : { zone: null, zoneReason: r?.reason ?? "City has no zone" };
