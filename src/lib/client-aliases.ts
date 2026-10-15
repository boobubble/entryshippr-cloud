import { useQuery } from "@tanstack/react-query";
import { supabase } from "./supabase";
import { nameKey } from "./text";

/** Excel names linked to a client (public.client_name_mappings). */
export type ClientAlias = { alias_norm: string; raw_name: string; client_id: string };

// PostgREST / Postgres codes for "table or column not created yet" (migration not applied).
const MISSING = new Set(["PGRST205", "PGRST204", "42P01", "42703"]);
const isMissing = (e: { code?: string } | null) => !!e && MISSING.has(e.code ?? "");

/**
 * The signed-in seller's Excel-name aliases. `available` is false until the
 * client mapping migration has been applied, so the app keeps working without it.
 */
export function useClientAliases() {
  return useQuery({
    queryKey: ["client_aliases"],
    retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.from("client_name_mappings").select("alias_norm, raw_name, client_id").order("raw_name");
      if (error) { if (isMissing(error)) return { available: false, rows: [] as ClientAlias[] }; throw error; }
      return { available: true, rows: (data ?? []) as ClientAlias[] };
    },
  });
}

/** Whether shipments can store the original Excel client name yet. */
export function useHasSourceClientName() {
  return useQuery({
    queryKey: ["has_source_client_name"],
    retry: false, staleTime: 0, refetchOnMount: "always",
    queryFn: async () => {
      const { error } = await supabase.from("shipments").select("source_client_name").limit(1);
      return !error;
    },
  });
}

export const aliasMap = (rows: ClientAlias[]) => new Map(rows.map((a) => [nameKey(a.raw_name), a.client_id]));

/** Links an Excel name to a client. Returns an error message, or null when saved or already linked to this client. */
export async function addAlias(rawName: string, clientId: string, existing: ClientAlias[]): Promise<string | null> {
  const k = nameKey(rawName);
  if (!k) return "Enter a name";
  const hit = existing.find((a) => nameKey(a.raw_name) === k);
  if (hit) return hit.client_id === clientId ? null : "This Excel name is already linked to another client";
  const { error } = await supabase.from("client_name_mappings").insert({ raw_name: rawName.trim(), client_id: clientId });
  if (!error) return null;
  if (error.code === "23505") return "This Excel name is already linked to another client";
  if (isMissing(error)) return "Excel names need the client mapping database update first";
  return error.message;
}

/** True once the optional receiver columns exist on shipments (migration_2026_10_15_receiver_details.sql). */
export function useHasReceiverFields() {
  return useQuery({
    queryKey: ["has_receiver_fields"],
    retry: false, staleTime: 0, refetchOnMount: "always",
    queryFn: async () => {
      const { error } = await supabase.from("shipments").select("receiver_name, receiver_phone").limit(1);
      return !error;
    },
  });
}
