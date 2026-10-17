import { imageExtension, validateImageMeta, validateReference } from './image-validation';
import { providerError } from './provider-errors';

type ProviderFailure = { code?: string | undefined; status?: number | undefined; statusCode?: string | number | undefined; message?: string | undefined };
type Attempt = { id: string; proof_path: string; submitted_at: string | null };
export type ProofSubmissionIO = {
  decode: (bytes: Uint8Array, type: string) => Promise<void>;
  begin: (args: { p_plan: string; p_reference: string; p_mime: string; p_size: number; p_request_id: string }) => Promise<{ data: unknown; error: ProviderFailure | null }>;
  upload: (path: string, file: File) => Promise<{ error: ProviderFailure | null }>;
  download: (path: string) => Promise<{ data: Blob | null; error: ProviderFailure | null }>;
  complete: (id: string, ownerId: string) => Promise<void>;
};

/** The actual handler delegates here so failure/retry ordering is testable without live writes. */
export async function processPaymentProof(input: { file: File; plan: string; reference: string; requestId: string; ownerId: string }, io: ProofSubmissionIO) {
  const { file, ownerId } = input;
  validateImageMeta(file.type, file.size);
  const reference = validateReference(input.reference);
  const incoming = new Uint8Array(await file.arrayBuffer());
  await io.decode(incoming, file.type);
  const started = await io.begin({ p_plan: input.plan, p_reference: reference, p_mime: file.type, p_size: file.size, p_request_id: input.requestId });
  if (started.error) throw providerError(started.error, 'Payment submission');
  const row = started.data as Attempt | null;
  if (!row || typeof row.id !== 'string' || !/^[0-9a-f-]{36}$/i.test(row.id) ||
      row.proof_path !== `${ownerId}/${row.id}.${imageExtension(file.type)}`) throw new Error('Submission ownership could not be verified.');
  if (row.submitted_at) return { id: row.id };
  const upload = await io.upload(row.proof_path, file);
  // Only an explicit duplicate status permits retry verification; provider text is never trusted.
  if (upload.error && !['409', 'Duplicate'].includes(String(upload.error.statusCode ?? upload.error.status)))
    throw providerError({ status: upload.error.status, code: upload.error.code }, 'Screenshot upload');
  const stored = await io.download(row.proof_path);
  if (stored.error || !stored.data || stored.data.size !== file.size) throw new Error('Stored screenshot could not be verified.');
  const storedBytes = new Uint8Array(await stored.data.arrayBuffer());
  if (storedBytes.length !== incoming.length || storedBytes.some((v, i) => v !== incoming[i])) throw new Error('Retry screenshot differs from the original upload.');
  await io.decode(storedBytes, file.type);
  await io.complete(row.id, ownerId);
  return { id: row.id };
}