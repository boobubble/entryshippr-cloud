import { createServerFn } from '@tanstack/react-start';
import { setResponseHeader } from '@tanstack/react-start/server';
import { z } from 'zod';
import type { GstinResult } from './gstin';

export const verifyGstin = createServerFn({ method: 'POST' })
  .inputValidator(z.object({ token: z.string().min(20).max(8000), gstin: z.string().trim().max(15) }).strict())
  .handler(async ({ data }): Promise<GstinResult> => {
    setResponseHeader('Cache-Control', 'no-store');
    const { authenticatedClient } = await import('./external-auth.server');
    let client;
    try { client = (await authenticatedClient(data.token)).client; }
    catch { return { ok: false, category: 'authentication', message: 'Unable to verify your session. Please sign in again or retry.', retryable: false }; }
    const { lookupGstin } = await import('./gstin.server');
    return lookupGstin(data.gstin, process.env['GSTINAPI_API_KEY'], process.env['GSTINAPI_SANDBOX_ENABLED'] === 'true', {
      reserve: async () => {
        // Review-only RPC contract: auth.uid() ownership, atomic account/shared limits, no arguments.
        const r = await client.rpc('reserve_gstin_lookup');
        if (r.error || typeof r.data !== 'boolean') throw new Error('Quota unavailable');
        return r.data;
      },
    });
  });