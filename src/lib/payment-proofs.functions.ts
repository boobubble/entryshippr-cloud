import { createServerFn } from '@tanstack/react-start';
import { z } from 'zod';
import { processPaymentProof } from './payment-proof-submission';
import { providerError } from './provider-errors';
export const submitPaymentProof = createServerFn({ method: 'POST' })
  .inputValidator((data: FormData) => { if (!(data instanceof FormData)) throw new Error('Invalid upload.'); return data; })
  .handler(async ({ data }) => {
    const { authenticatedClient } = await import('./external-auth.server');
    const { decodePaymentProof } = await import('./payment-proof-decoder.server');
    const { client, user } = await authenticatedClient(String(data.get('token') || ''));
    const plan = z.enum(['standard', 'unlimited']).parse(data.get('plan'));
    const requestId = z.string().uuid().parse(data.get('requestId'));
    const file = data.get('file');
    if (!(file instanceof File)) throw new Error('Choose a payment screenshot.');
    const storage = client.storage.from('payment-proofs');
    return processPaymentProof({ file, plan, reference: String(data.get('reference') || ''), requestId, ownerId: user.id }, {
      decode: decodePaymentProof,
      begin: async args => {
        try { return await client.rpc('begin_manual_payment', args); }
        catch { throw providerError({}, 'Payment submission'); }
      },
      upload: async (path, proof) => {
        try { return await storage.upload(path, proof, { contentType: proof.type, upsert: false }); }
        catch { throw providerError({}, 'Screenshot upload'); }
      },
      download: async path => {
        try { return await storage.download(path); }
        catch { throw providerError({}, 'Screenshot download'); }
      },
      complete: async (id, ownerId) => {
        const key = process.env['EXT_SUPABASE_SECRET_KEY'];
        if (!key) throw new Error('Payment proof completion is not configured.');
        const { SUPABASE_URL } = await import('./supabase');
        let complete: Response;
        try {
          complete = await fetch(`${SUPABASE_URL}/rest/v1/rpc/complete_manual_payment`, { method: 'POST', headers: { apikey: key, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_id: id, p_owner_id: ownerId }) });
        } catch { throw providerError({}, 'Payment submission completion'); }
        if (!complete.ok) throw providerError({ status: complete.status }, 'Payment submission completion');
      },
    });
  });
export const paymentProofUrl = createServerFn({ method: 'POST' })
  .inputValidator(z.object({ token: z.string().min(20).max(8000), id: z.string().uuid() }))
  .handler(async ({ data }) => {
    const { authenticatedClient, dbError } = await import('./external-auth.server');
    const { client } = await authenticatedClient(data.token);
    const row = await client.from('payment_submissions').select('proof_path,submitted_at').eq('id', data.id).maybeSingle().then(result => result, () => { throw providerError({}, 'Payment proof lookup'); });
    dbError(row.error);
    if (!row.data?.submitted_at) throw new Error('Payment proof not found.');
    const signed = await client.storage.from('payment-proofs').createSignedUrl(row.data.proof_path, 60).catch(() => { throw providerError({}, 'Payment proof viewing'); });
    if (signed.error || !signed.data) throw new Error('Payment proof unavailable.');
    return { url: signed.data.signedUrl };
  });
export const reviewPaymentProof = createServerFn({ method: 'POST' })
  .inputValidator(z.object({ token: z.string().min(20).max(8000), id: z.string().uuid(), decision: z.enum(['approved','rejected']), reason: z.string().trim().min(3).max(1000) }))
  .handler(async ({ data }) => {
    const { authenticatedClient, dbError } = await import('./external-auth.server');
    const { client } = await authenticatedClient(data.token, true);
    const result = await client.rpc('review_manual_payment', { p_id: data.id, p_decision: data.decision, p_reason: data.reason }).then(result => result, () => { throw providerError({}, 'Payment proof review'); });
    dbError(result.error); return { ok: true };
  });
