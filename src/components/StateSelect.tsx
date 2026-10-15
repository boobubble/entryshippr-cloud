import { useEffect, useId, useState } from "react";
import { Input } from "@/components/ui/input";
// Must match public.gst_state_code() in supabase/entrysetu_schema.sql.
export const INDIAN_STATES = [
  "Andaman and Nicobar Islands", "Andhra Pradesh", "Arunachal Pradesh", "Assam", "Bihar", "Chandigarh",
  "Chhattisgarh", "Dadra and Nagar Haveli and Daman and Diu", "Delhi", "Goa", "Gujarat", "Haryana",
  "Himachal Pradesh", "Jammu and Kashmir", "Jharkhand", "Karnataka", "Kerala", "Ladakh", "Lakshadweep",
  "Madhya Pradesh", "Maharashtra", "Manipur", "Meghalaya", "Mizoram", "Nagaland", "Odisha", "Other Territory",
  "Puducherry", "Punjab", "Rajasthan", "Sikkim", "Tamil Nadu", "Telangana", "Tripura", "Uttar Pradesh",
  "Uttarakhand", "West Bengal",
];

/** Searchable state field (MAH → MAHARASHTRA). Shows UPPERCASE; passes the exact state name the database expects. */
export function StateSelect({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const listId = useId();
  const find = (t: string) => INDIAN_STATES.find((s) => s.toLowerCase() === t.trim().toLowerCase());
  const [text, setText] = useState(value ? value.toUpperCase() : "");
  useEffect(() => { const k = find(value); if (k) setText(k.toUpperCase()); else if (!value) setText((t) => (find(t) ? "" : t)); }, [value]);
  return (
    <>
      <Input list={listId} className="uppercase" autoComplete="off" placeholder="Type state, e.g. MAH" value={text}
        onChange={(e) => { setText(e.target.value); onChange(find(e.target.value) ?? ""); }}
        onBlur={() => { if (!find(text)) setText(""); }} />
      <datalist id={listId}>{INDIAN_STATES.map((s) => <option key={s} value={s.toUpperCase()} />)}</datalist>
    </>
  );
}
