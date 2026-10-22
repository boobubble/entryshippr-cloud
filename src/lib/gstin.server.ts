import { GstinApi } from 'gstinapi';
import { normalizeGstin, validGstin, SANDBOX_GSTIN, registrationSchema, type GstinResult } from './gstin';

export function gstinFailure(status?: number, code?: string): GstinResult {
  const known: Record<number, [string, string]> = {
    400: ['invalid', 'Enter a valid 15-character GSTIN.'],
    401: ['configuration', 'GSTIN verification credentials are not configured correctly.'],
    402: ['credits', 'GSTIN verification credits are exhausted.'],
    403: ['deactivated', 'The GSTIN verification provider account is deactivated.'],
    404: ['not-found', 'GSTIN not found.'],
    429: ['limited', 'GSTIN verification limit reached. Please try again later.'],
    502: ['unavailable', 'GSTIN verification is temporarily unavailable.'],
  };
  const [category, message] = (status && known[status]) ||
    (code === 'TIMEOUT' ? ['timeout', 'GSTIN verification timed out. Please try again.'] :
      ['unavailable', 'GSTIN verification could not be completed. Please try again.']);
  return { ok: false, category, message, retryable: status === 429 || status === 502 || !status,
    ...(status && known[status] ? { status } : {}) };
}

type Dependencies = { reserve: () => Promise<boolean>; sleep?: (ms: number) => Promise<void> };
/** No arbitrary upstream URL and no raw SDK/provider errors escape this boundary. */
export async function lookupGstin(input: string, apiKey: string | undefined, sandboxEnabled: boolean, deps: Dependencies): Promise<GstinResult> {
  const gstin = normalizeGstin(input);
  const sandbox = sandboxEnabled && gstin === SANDBOX_GSTIN;
  if (!validGstin(gstin) && !sandbox) return gstinFailure(400);
  if (!apiKey) return { ok: false, category: 'setup', message: 'GSTIN verification is awaiting server configuration.', retryable: false };
  const sdk = new GstinApi({ apiKey, timeout: 8000, retries: 0, validateChecksum: !sandbox });
  const sleep = deps.sleep ?? ((ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms)));
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      if (!await deps.reserve()) return gstinFailure(429);
    } catch {
      return { ok: false, category: 'setup', message: 'GSTIN verification is awaiting the reviewed DEV usage-protection setup.', retryable: false };
    }
    try {
      const raw: unknown = await sdk.lookup(gstin);
      const envelope = raw && typeof raw === 'object' ? raw as Record<string, unknown> : {};
      if (typeof envelope['credits_remaining'] === 'number' && Number.isFinite(envelope['credits_remaining']) && envelope['credits_remaining'] >= 0) {
        console.info('GSTIN provider usage', { credits_remaining: envelope['credits_remaining'] });
      }
      const parsed = registrationSchema.safeParse(envelope['data']);
      if (envelope['success'] !== true || envelope['gstin'] !== gstin || !parsed.success || parsed.data.gstin !== gstin ||
        (parsed.data.state_code && parsed.data.state_code !== gstin.slice(0, 2))) return gstinFailure(502);
      return { ok: true, registration: parsed.data, sandbox };
    } catch (error) {
      const e = error && typeof error === 'object' ? error as { status?: unknown; code?: unknown } : {};
      const status = typeof e.status === 'number' ? e.status : undefined;
      if ((status === 429 || status === 502) && attempt < 2) { await sleep(500 * 2 ** attempt); continue; }
      const result = gstinFailure(status, e.code === 'TIMEOUT' ? 'TIMEOUT' : undefined);
      console.warn('GSTIN verification failed', { category: result.ok ? 'unavailable' : result.category, ...(status && [400,401,402,403,404,429,502].includes(status) ? { status } : {}) });
      return result;
    }
  }
  return gstinFailure(502);
}