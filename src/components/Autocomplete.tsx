import { useEffect, useId, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/lib/supabase";
import { normCity } from "@/lib/cities";
import { clientDetails, groupClients, nameKey, up } from "@/lib/text";
import { Input } from "@/components/ui/input";

const useDebounced = (v: string, ms = 200) => {
  const [d, setD] = useState(v);
  useEffect(() => { const t = setTimeout(() => setD(v), ms); return () => clearTimeout(t); }, [v, ms]);
  return d;
};

/** City name input with suggestions from the shared city registry and its aliases (e.g. MUM → MUMBAI). */
export function CityInput({ value, onChange, required, placeholder, id }: {
  value: string; onChange: (v: string) => void; required?: boolean; placeholder?: string; id?: string;
}) {
  const listId = useId();
  const q = normCity(useDebounced(value));
  const { data = [] } = useQuery({
    queryKey: ["city_suggest", q], enabled: q.length >= 2, staleTime: 60_000, retry: false,
    queryFn: async () => {
      const like = `%${q.replace(/[%_]/g, "")}%`;
      const [byName, byAlias] = await Promise.all([
        supabase.from("cities").select("name, state").ilike("name_norm", like).order("name").limit(12),
        supabase.from("city_aliases").select("alias_norm, cities(name, state)").ilike("alias_norm", like).limit(8),
      ]);
      const out = new Map<string, string>();
      for (const c of byName.data ?? []) out.set(`${c.name}|${c.state ?? ""}`, c.state ? `${up(c.state)}` : "");
      for (const a of (byAlias.data ?? []) as unknown as { alias_norm: string; cities: { name: string; state: string | null } | null }[])
        if (a.cities) out.set(`${a.cities.name}|${a.cities.state ?? ""}`, `${a.cities.state ? up(a.cities.state) + " · " : ""}also "${up(a.alias_norm)}"`);
      // Starts-with matches first.
      return [...out].map(([k, label]) => ({ name: k.split("|")[0]!, label }))
        .sort((a, b) => Number(!normCity(b.name).startsWith(q)) - Number(!normCity(a.name).startsWith(q)) || a.name.localeCompare(b.name));
    },
  });
  return (
    <>
      <Input id={id} list={listId} className="uppercase" autoComplete="off" required={required} placeholder={placeholder} maxLength={80}
        value={value} onChange={(e) => onChange(e.target.value)} />
      <datalist id={listId}>
        {data.map((c, i) => <option key={i} value={up(c.name)}>{c.label}</option>)}
      </datalist>
    </>
  );
}

type ClientLite = { id: string; name: string; is_gst?: boolean; gstin?: string | null; state?: string | null; phone?: string | null };

/** Client picker with type-ahead over the signed-in seller's own clients (the list is already scoped by RLS). */
export function ClientInput({ clients, value, onChange, required }: {
  clients: ClientLite[]; value: string; onChange: (id: string) => void; required?: boolean;
}) {
  const listId = useId();
  const groups = groupClients(clients);
  // Same-name clients get their billing details in the label so the seller picks the exact record.
  const label = (c: ClientLite) => ((groups.get(nameKey(c.name))?.length ?? 0) > 1 ? `${up(c.name)} — ${clientDetails(c)}` : up(c.name));
  const resolve = (t: string) => {
    const exact = clients.find((c) => nameKey(label(c)) === nameKey(t));
    if (exact) return exact;
    const g = groups.get(nameKey(t));
    return g?.length === 1 ? g[0] : undefined;
  };
  const current = clients.find((c) => c.id === value);
  const [text, setText] = useState(current ? label(current) : "");
  useEffect(() => { if (current) setText(label(current)); }, [value, current?.id]); // eslint-disable-line react-hooks/exhaustive-deps
  const several = !current && (groups.get(nameKey(text))?.length ?? 0) > 1;
  return (
    <>
      <Input list={listId} className="uppercase" autoComplete="off" required={required} placeholder="Type to search…" value={text}
        onChange={(e) => {
          setText(e.target.value);
          onChange(resolve(e.target.value)?.id ?? "");
        }}
        onBlur={() => { if (!resolve(text) && !several) setText(current ? label(current) : ""); }} />
      <datalist id={listId}>{clients.map((c) => <option key={c.id} value={label(c)} />)}</datalist>
      {several && <p className="mt-1 text-xs text-destructive">Several clients are named {up(text)} — choose the exact one from the list.</p>}
    </>
  );
}
