/** Display form for client, city and state names: always UPPERCASE. */
export const up = (s: string | null | undefined) => (s ?? "").toUpperCase();

/** Normalises a typed or imported name before saving: trims, collapses spaces, UPPERCASE. */
export const upName = (s: unknown) => String(s ?? "").trim().replace(/\s+/g, " ").toUpperCase();

/** Case- and spacing-insensitive key used to detect case-only duplicates. */
export const nameKey = (s: unknown) => String(s ?? "").trim().replace(/\s+/g, " ").toLowerCase();

type ClientInfo = { id: string; name: string; is_gst?: boolean; gstin?: string | null; state?: string | null; phone?: string | null; active?: boolean };

/** Identifying details shown when several clients share the same name. */
export const clientDetails = (c: ClientInfo) =>
  [c.is_gst == null ? null : c.is_gst ? "GST" : "NON-GST", c.gstin, c.state ? up(c.state) : null, c.phone, c.active === false ? "INACTIVE" : null].filter(Boolean).join(" · ");

/** Groups clients by normalised name; each group with more than one entry is a duplicate-name set. */
export function groupClients<T extends ClientInfo>(clients: T[]) {
  const m = new Map<string, T[]>();
  for (const c of clients) { const k = nameKey(c.name); m.set(k, [...(m.get(k) ?? []), c]); }
  return m;
}

/** Friendly message for the clients (owner_id, name) unique constraint. */
export const isDupClientError = (e: unknown) => (e as { code?: string } | null)?.code === "23505";
