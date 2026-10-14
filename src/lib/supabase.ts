import { createClient } from "@supabase/supabase-js";

export const SUPABASE_URL = "https://zfvnqcyqxxipjaugkmvf.supabase.co";
export const SUPABASE_PUBLISHABLE_KEY = "sb_publishable_YN1n6XqxiNb5_osRp3-Qcg_3riV7sYJ";

export const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
  auth: {
    persistSession: typeof window !== "undefined",
    autoRefreshToken: typeof window !== "undefined",
    storage: typeof window !== "undefined" ? window.localStorage : undefined,
  },
});

export async function accessToken() {
  const { data } = await supabase.auth.getSession();
  const t = data.session?.access_token;
  if (!t) throw new Error("Please sign in again");
  return t;
}

export const PLANS = {
  standard: { name: "Standard", price: 1200, limit: "Up to 50 active clients" },
  unlimited: { name: "Standard Unlimited", price: 1800, limit: "Unlimited active clients" },
} as const;
export const JOINING_FEE = 3000;

export const inr = (n: number) =>
  "₹" + Number(n || 0).toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
