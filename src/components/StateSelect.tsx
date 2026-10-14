// Must match public.gst_state_code() in supabase/entrysetu_schema.sql.
export const INDIAN_STATES = [
  "Andaman and Nicobar Islands", "Andhra Pradesh", "Arunachal Pradesh", "Assam", "Bihar", "Chandigarh",
  "Chhattisgarh", "Dadra and Nagar Haveli and Daman and Diu", "Delhi", "Goa", "Gujarat", "Haryana",
  "Himachal Pradesh", "Jammu and Kashmir", "Jharkhand", "Karnataka", "Kerala", "Ladakh", "Lakshadweep",
  "Madhya Pradesh", "Maharashtra", "Manipur", "Meghalaya", "Mizoram", "Nagaland", "Odisha", "Other Territory",
  "Puducherry", "Punjab", "Rajasthan", "Sikkim", "Tamil Nadu", "Telangana", "Tripura", "Uttar Pradesh",
  "Uttarakhand", "West Bengal",
];

export function StateSelect({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const known = INDIAN_STATES.find((s) => s.toLowerCase() === value.trim().toLowerCase());
  return (
    <select
      className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
      value={known ?? ""}
      onChange={(e) => onChange(e.target.value)}
    >
      <option value="">Select state</option>
      {INDIAN_STATES.map((s) => <option key={s} value={s}>{s}</option>)}
    </select>
  );
}
