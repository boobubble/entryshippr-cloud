// @vitest-environment node
import { describe, expect, it, vi, afterEach } from 'vitest';
import { providerError, logPaymentFailure } from '@/lib/provider-errors';
import { dbError } from '@/lib/external-auth.server';
import { rest } from '@/lib/billing.server';
vi.mock('@tanstack/react-start/server', () => ({ setResponseHeader: vi.fn() }));
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); vi.unstubAllEnvs(); });
describe('Provider error and credential safety', () => {
  it.each([['42P01','setup'],['42501','permission'],['PGRST301','authentication'],['23505','conflict'],['unknown','unavailable']])('maps code %s to a stable category', (code, category) => {
    expect(providerError({code}).category).toBe(category);
  });
  it('does not forward raw database messages', () => {
    try { dbError({code:'XX000',message:'Bearer test-credential; signedUrl=https://private/proof'}); throw new Error('Expected error'); }
    catch (error) { expect(String(error)).not.toMatch(/test-credential|signedUrl|private\/proof/); expect(String(error)).toContain('could not be completed'); }
  });
  it('logs only an allowlisted category, dropping nested credentials, headers and proof data', () => {
    const log = vi.spyOn(console,'error').mockImplementation(() => {});
    logPaymentFailure('webhook-activation', {category:'secret',token:'test-token',headers:{Authorization:'Bearer test-token'},body:'proof content',signedUrl:'https://private'});
    expect(log).toHaveBeenCalledExactlyOnceWith('Payment operation failed', {operation:'webhook-activation',category:'unavailable'});
  });
  it('does not forward sensitive provider response bodies', async () => {
    vi.stubEnv('EXT_SUPABASE_SECRET_KEY','test-only-secret');
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify({code:'42P01',message:'test-only-secret',details:'private payment'}), {status:400})));
    await expect(rest('test')).rejects.toMatchObject({category:'setup'});
    await expect(rest('test')).rejects.not.toThrow('test-only-secret');
  });
  it('sanitizes fetch exceptions instead of propagating request URLs/headers', async () => {
    vi.stubEnv('EXT_SUPABASE_SECRET_KEY','test-only-secret');
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('Authorization Bearer test-only-secret')));
    await expect(rest('test')).rejects.toMatchObject({category:'unavailable'});
  });
});