import { createServerFn } from '@tanstack/react-start';
import { z } from 'zod';
import { validateReference } from './image-validation';
import { validatePaymentProofBytes } from './payment-proof-validation';
export const submitPaymentProof = createServerFn({ method: 'POST' })
  .inputValidator((data: FormData) => { if (!(data instanceof FormData)) throw new Error('Invalid upload.'); return data; })
  .handler(async ({ data }) => {
    const { authenticatedClient, dbError } = await import('./external-auth.server');
    const { client, user } = await authenticatedClient(String(data.get('token') || ''));
    const plan = z.enum(['standard', 'unlimited']).parse(data.get('plan'));
    const reference = validateReference(String(data.get('reference') || ''));
    const requestId = z.string().uuid().parse(data.get('requestId'));
    const file = data.get('file');
    if (!(file instanceof File)) throw new Error('Choose a payment screenshot.');
    if (file.size > 5 * 1024 * 1024) throw new Error('Image must be no larger than 5 MB.');
    const incoming = new Uint8Array(await file.arrayBuffer());
    validatePaymentProofBytes(incoming, file.type);
    const started = await client.rpc('begin_manual_payment', { p_plan: plan, p_reference: reference, p_mime: file.type, p_size: file.size, p_request_id: requestId });
    dbError(started.error);
    const row = started.data as { id: string; proof_path: string; submitted_at: string | null };
    if (!row?.id || !row.proof_path) throw new Error('Submission unavailable.');
    if (row.submitted_at) return { id: row.id };
    const upload = await client.storage.from('payment-proofs').upload(row.proof_path, file, { contentType: file.type, upsert: false });
    // A successful upload followed by a lost response is safely completed on retry.
    if (upload.error && !['Duplicate', '409'].includes(String(upload.error.statusCode)) && !/already exists|duplicate/i.test(upload.error.message)) throw new Error('Screenshot upload failed. Check the approved private storage setup and try again.');
    const stored = await client.storage.from('payment-proofs').download(row.proof_path);
    if (stored.error || !stored.data || stored.data.size !== file.size) throw new Error('Stored screenshot could not be verified.');
    const storedBytes = new Uint8Array(await stored.data.arrayBuffer());
    validatePaymentProofBytes(storedBytes, file.type);
    if (storedBytes.length !== incoming.length || storedBytes.some((v,i) => v !== incoming[i])) throw new Error('Retry screenshot differs from the original upload.');
    const key = process.env['EXT_SUPABASE_SECRET_KEY'];
    if (!key) throw new Error('Payment proof completion is not configured.');
    const { SUPABASE_URL } = await import('./supabase');
    const complete = await fetch(`${SUPABASE_URL}/rest/v1/rpc/complete_manual_payment`, { method: 'POST', headers: { apikey: key, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_id: row.id, p_owner_id: user.id }) });
    if (!complete.ok) throw new Error('Could not complete payment submission. Try again.');
    return { id: row.id };
  });
export const paymentProofUrl = createServerFn({ method: 'POST' })
  .inputValidator(z.object({ token: z.string().min(20).max(8000), id: z.string().uuid() }))
  .handler(async ({ data }) => {
    const { authenticatedClient, dbError } = await import('./external-auth.server');
    const { client } = await authenticatedClient(data.token);
    const row = await client.from('payment_submissions').select('proof_path,submitted_at').eq('id', data.id).maybeSingle();
    dbError(row.error);
    if (!row.data?.submitted_at) throw new Error('Payment proof not found.');
    const signed = await client.storage.from('payment-proofs').createSignedUrl(row.data.proof_path, 60);
    if (signed.error || !signed.data) throw new Error('Payment proof unavailable.');
    return { url: signed.data.signedUrl };
  });
export const reviewPaymentProof = createServerFn({ method: 'POST' })
  .inputValidator(z.object({ token: z.string().min(20).max(8000), id: z.string().uuid(), decision: z.enum(['approved','rejected']), reason: z.string().trim().min(3).max(1000) }))
  .handler(async ({ data }) => {
    const { authenticatedClient, dbError } = await import('./external-auth.server');
    const { client } = await authenticatedClient(data.token, true);
    const result = await client.rpc('review_manual_payment', { p_id: data.id, p_decision: data.decision, p_reason: data.reason });
    dbError(result.error); return { ok: true };
  });
