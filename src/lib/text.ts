/** Display form for client, city and state names: always UPPERCASE. */
export const up = (s: string | null | undefined) => (s ?? "").toUpperCase();

/** Normalises a typed or imported name before saving: trims, collapses spaces, UPPERCASE. */
export const upName = (s: unknown) => String(s ?? "").trim().replace(/\s+/g, " ").toUpperCase();

/** Case- and spacing-insensitive key used to detect case-only duplicates. */
export const nameKey = (s: unknown) => String(s ?? "").trim().replace(/\s+/g, " ").toLowerCase();
