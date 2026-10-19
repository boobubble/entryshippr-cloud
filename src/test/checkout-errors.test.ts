// @vitest-environment node
import { describe, expect, it, vi, afterEach } from 'vitest';
import { providerError, logPaymentFailure, paymentStage } from '@/lib/provider-errors';
import { getUser, rest } from '@/lib/billing.server';

afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); vi.unstubAllEnvs(); });

describe('Subscribe checkout error categories', () => {
  it('rejected user session token asks the user to sign in again', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('{}', { status: 403 })));
    await expect(getUser('expired-token')).rejects.toMatchObject({ category: 'authentication', message: 'Please sign in again.' });
  });

  it('sign-in service network failure is not reported as sign in again', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('network down')));
    await expect(getUser('token')).rejects.toMatchObject({ category: 'unavailable' });
    await expect(getUser('token')).rejects.not.toThrow('Please sign in again.');
  });

  it('sign-in service outage (5xx) is not reported as sign in again', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('{}', { status: 503 })));
    await expect(getUser('token')).rejects.toMatchObject({ category: 'unavailable' });
  });

  it('Razorpay credential rejection (401) is a configuration error, not sign in again', () => {
    const e = providerError({ status: 401 }, 'Payment checkout', 'server');
    expect(e.category).toBe('configuration');
    expect(e.message).not.toContain('sign in');
  });

  it('server database key rejection is a configuration error, not sign in again', async () => {
    vi.stubEnv('EXT_SUPABASE_SECRET_KEY', 'test-only-secret');
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('{}', { status: 401 })));
    await expect(rest('profiles')).rejects.toMatchObject({ category: 'configuration', status: 401 });
  });

  it('missing server database key is a configuration error', async () => {
    vi.stubEnv('EXT_SUPABASE_SECRET_KEY', '');
    await expect(rest('profiles')).rejects.toMatchObject({ category: 'configuration' });
  });

  it('stage logs contain only operation, stage, status and category', async () => {
    const log = vi.spyOn(console, 'error').mockImplementation(() => {});
    const err = Object.assign(providerError({ status: 401 }, 'Payment checkout', 'server'), { token: 'test-token', headers: { Authorization: 'Bearer x' } });
    await expect(paymentStage('checkout', 'gateway-order', async () => { throw err; })).rejects.toBe(err);
    expect(log).toHaveBeenCalledExactlyOnceWith('Payment operation failed', { operation: 'checkout', stage: 'gateway-order', status: 401, category: 'configuration' });
  });

  it('drops invalid stage names and statuses from logs', () => {
    const log = vi.spyOn(console, 'error').mockImplementation(() => {});
    logPaymentFailure('checkout', { category: 'authentication', status: 'Bearer x' }, 'Bearer secret!');
    expect(log).toHaveBeenCalledExactlyOnceWith('Payment operation failed', { operation: 'checkout', category: 'authentication' });
  });
});
