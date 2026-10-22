import { isValidGstin } from 'gstinapi';
import { z } from 'zod';

export const SANDBOX_GSTIN = '00AAAAA0000A1ZT';
export const normalizeGstin = (value: string) => value.trim().toUpperCase();
export const validGstin = (value: string) => isValidGstin(normalizeGstin(value));
const text = (max: number) => z.string().trim().max(max).nullable().optional();
export const registrationSchema = z.object({
  gstin: z.string().length(15), legal_name: text(200), trade_name: text(200),
  status: z.string().min(1).max(50), taxpayer_type: text(100),
  registration_date: text(30), cancellation_date: text(30), state_code: text(2),
  address: text(1000), pincode: text(10),
  address_details: z.object({ building_number: text(200), building_name: text(200), floor: text(100),
    street: text(300), locality: text(300), district: text(100), state: text(100),
    landmark: text(200), pincode: text(10) }).nullable().optional(),
});
export type Registration = z.infer<typeof registrationSchema>;
export type GstinResult = { ok: true; registration: Registration; sandbox: boolean } |
  { ok: false; category: string; message: string; retryable: boolean; status?: number };
const states: Record<string, string> = {
  '01':'Jammu and Kashmir','02':'Himachal Pradesh','03':'Punjab','04':'Chandigarh','05':'Uttarakhand',
  '06':'Haryana','07':'Delhi','08':'Rajasthan','09':'Uttar Pradesh','10':'Bihar','11':'Sikkim',
  '12':'Arunachal Pradesh','13':'Nagaland','14':'Manipur','15':'Mizoram','16':'Tripura',
  '17':'Meghalaya','18':'Assam','19':'West Bengal','20':'Jharkhand','21':'Odisha','22':'Chhattisgarh',
  '23':'Madhya Pradesh','24':'Gujarat','26':'Dadra and Nagar Haveli and Daman and Diu','27':'Maharashtra',
  '29':'Karnataka','30':'Goa','31':'Lakshadweep','32':'Kerala','33':'Tamil Nadu','34':'Puducherry',
  '35':'Andaman and Nicobar Islands','36':'Telangana','37':'Andhra Pradesh','38':'Ladakh','97':'Other Territory',
};
export function clientGstinPatch(r: Registration) {
  if (!validGstin(r.gstin)) return {};
  const name = r.trade_name || r.legal_name;
  const state = states[r.gstin.slice(0, 2)];
  return { gstin: r.gstin, ...(name ? { name } : {}), ...(r.address ? { address: r.address } : {}), ...(state ? { state } : {}) };
}

export function registrationState(status: string) {
  const s = status.trim().toLowerCase();
  return s === 'active' ? 'Verified' : s === 'cancelled' ? 'Cancelled registration' :
    s === 'suspended' ? 'Suspended registration' : `Registration status: ${status}`;
}