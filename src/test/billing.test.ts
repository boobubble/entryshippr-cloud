import { describe,it,expect } from 'vitest';
import { PLANS,JOINING_FEE } from '@/lib/supabase';
import { safeEqual,hmacHex } from '@/lib/billing.server';
describe('Existing billing invariants',()=>{
 it('Standard is temporarily 1 rupee per year',()=>expect(PLANS.standard.price).toBe(1));
 it('Unlimited is temporarily 2 rupees per year',()=>expect(PLANS.unlimited.price).toBe(2));
 it('Joining fee is temporarily zero for both plans',()=>expect(JOINING_FEE).toBe(0));
 it('Standard first purchase total is 1 rupee',()=>expect(PLANS.standard.price+JOINING_FEE).toBe(1));
 it('Unlimited first purchase total is 2 rupees',()=>expect(PLANS.unlimited.price+JOINING_FEE).toBe(2));
 it('signature equality rejects mismatches and unequal lengths',()=>{expect(safeEqual('abc','abc')).toBe(true);expect(safeEqual('abc','abd')).toBe(false);expect(safeEqual('abc','ab')).toBe(false);});
 it('HMAC uses known SHA256 vector',async()=>expect(await hmacHex('key','The quick brown fox jumps over the lazy dog')).toBe('f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8'));
});
