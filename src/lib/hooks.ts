import { useQuery } from "@tanstack/react-query";
import { supabase } from "./supabase";

export type Profile = {
  id: string; email: string | null; business_name: string | null; phone: string | null; gstin: string | null;
  address: string | null; state: string | null; trial_ends_at: string;
  plan: "standard" | "unlimited" | null; plan_expires_at: string | null; joining_fee_paid: boolean;
};
export type Client = { id: string; name: string; phone: string | null; email: string | null; gstin: string | null; address: string | null; state: string | null; is_gst: boolean; active: boolean };
export type RateCard = { id: string; client_id: string | null; service: string; min_weight: number; max_weight: number; rate: number; extra_per_kg: number };

export function useProfile() {
  return useQuery({
    queryKey: ["profile"],
    queryFn: async () => {
      const { data: u } = await supabase.auth.getUser();
      if (!u.user) throw new Error("Not signed in");
      const { data, error } = await supabase.from("profiles").select("*").eq("id", u.user.id).maybeSingle();
      if (error) throw error;
      const { data: roles } = await supabase.from("user_roles").select("role").eq("user_id", u.user.id);
      return { profile: data as Profile | null, isAdmin: !!roles?.some((r) => r.role === "admin") };
    },
  });
}

export function accessState(p: Profile | null | undefined) {
  if (!p) return { active: false, label: "No profile", paid: false };
  const now = Date.now();
  if (p.plan && p.plan_expires_at && new Date(p.plan_expires_at).getTime() > now)
    return { active: true, paid: true, label: `${p.plan === "unlimited" ? "Standard Unlimited" : "Standard"} · until ${new Date(p.plan_expires_at).toLocaleDateString("en-IN")}` };
  const t = new Date(p.trial_ends_at).getTime();
  if (t > now) return { active: true, paid: false, label: `Free trial · ${Math.ceil((t - now) / 86400000)} day(s) left` };
  return { active: false, paid: false, label: "Trial/plan expired" };
}

export function useClients() {
  return useQuery({
    queryKey: ["clients"],
    queryFn: async () => {
      const { data, error } = await supabase.from("clients").select("*").order("name");
      if (error) throw error;
      return data as Client[];
    },
  });
}

export function useRateCards() {
  return useQuery({
    queryKey: ["rate_cards"],
    queryFn: async () => {
      const { data, error } = await supabase.from("rate_cards").select("*").order("min_weight");
      if (error) throw error;
      return data as RateCard[];
    },
  });
}

export function calcAmount(cards: RateCard[], clientId: string, service: string, weight: number) {
  const s = service.trim().toLowerCase();
  const match = (cid: string | null) =>
    cards.filter((c) => c.client_id === cid && c.service.toLowerCase() === s);
  let pool = match(clientId);
  if (!pool.length) pool = match(null);
  if (!pool.length) return null;
  const inRange = pool.find((c) => weight >= Number(c.min_weight) && weight <= Number(c.max_weight));
  if (inRange) return Number(inRange.rate);
  const top = [...pool].sort((a, b) => Number(b.max_weight) - Number(a.max_weight))[0];
  if (!top) return null;
  if (weight > Number(top.max_weight)) return Number(top.rate) + Math.ceil(weight - Number(top.max_weight)) * Number(top.extra_per_kg);
  return null;
}

export const errMsg = (e: unknown) => (e instanceof Error ? e.message : (e as { message?: string })?.message || "Something went wrong");
