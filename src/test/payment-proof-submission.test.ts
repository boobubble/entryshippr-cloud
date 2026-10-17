// @vitest-environment node
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { processPaymentProof, type ProofSubmissionIO } from '@/lib/payment-proof-submission';
import { decodePaymentProof } from '@/lib/payment-proof-decoder.server';
import { png } from './payment-image-fixtures';
const id = '11111111-1111-4111-8111-111111111111', ownerId = '22222222-2222-4222-8222-222222222222';
const bytes = new Uint8Array(Buffer.from(png.base64, 'base64'));
const file = () => new File([bytes], 'proof.png', { type: png.type });
const row = { id, proof_path: `${ownerId}/${id}.png`, submitted_at: null };
let io: ProofSubmissionIO;
const input = () => ({ file: file(), plan: 'standard', reference: 'test-reference', requestId: id, ownerId });
beforeEach(() => { io = { decode: vi.fn(decodePaymentProof), begin: vi.fn().mockResolvedValue({ data: row, error: null }), upload: vi.fn().mockResolvedValue({ error: null }), download: vi.fn().mockResolvedValue({ data: new Blob([bytes]), error: null }), complete: vi.fn().mockResolvedValue(undefined) }; });
describe('Real submission orchestration with local decoder and mocked DEV adapters', () => {
  it.each(['invalid', 'oversized', 'mime'])('rejects %s before begin/upload/completion', async mode => {
    const data = mode === 'oversized' ? new Uint8Array(5 * 1024 * 1024 + 1) : new Uint8Array(20);
    const proof = new File([data], 'bad', { type: mode === 'mime' ? 'text/html' : 'image/png' });
    const read = vi.spyOn(proof, 'arrayBuffer');
    await expect(processPaymentProof({ ...input(), file: proof }, io)).rejects.toThrow();
    if (mode !== 'invalid') expect(read).not.toHaveBeenCalled();
    expect(io.begin).not.toHaveBeenCalled(); expect(io.upload).not.toHaveBeenCalled(); expect(io.complete).not.toHaveBeenCalled();
  });
  it('uploads exact original bytes and completes only after two validations', async () => {
    await expect(processPaymentProof(input(), io)).resolves.toEqual({ id });
    expect(io.decode).toHaveBeenCalledTimes(2);
    const uploaded = vi.mocked(io.upload).mock.calls[0]?.[1];
    expect(uploaded).toBeDefined();
    if (!uploaded) throw new Error('Upload not called');
    expect(new Uint8Array(await uploaded.arrayBuffer())).toEqual(bytes);
    expect(io.complete).toHaveBeenCalledWith(id, ownerId);
  });
  it('rejects a server-returned foreign owner path without upload', async () => {
    vi.mocked(io.begin).mockResolvedValue({ data: { ...row, proof_path: `other/${id}.png` }, error: null });
    await expect(processPaymentProof(input(), io)).rejects.toThrow('ownership'); expect(io.upload).not.toHaveBeenCalled();
  });
  it('does not upload or complete after a failed begin operation', async () => {
    vi.mocked(io.begin).mockResolvedValue({data:null,error:{code:'PGRST202',message:'private details'}});
    await expect(processPaymentProof(input(),io)).rejects.toMatchObject({category:'setup'});
    expect(io.upload).not.toHaveBeenCalled(); expect(io.complete).not.toHaveBeenCalled();
  });
  it('never completes when validation of downloaded bytes fails', async () => {
    vi.mocked(io.decode).mockResolvedValueOnce(undefined).mockRejectedValueOnce(new Error('pixels invalid'));
    await expect(processPaymentProof(input(),io)).rejects.toThrow('pixels invalid'); expect(io.complete).not.toHaveBeenCalled();
  });
  it('rejects stored size mismatch without reading or completing', async () => {
    const stored = new Blob([new Uint8Array(12)]), read = vi.spyOn(stored,'arrayBuffer');
    vi.mocked(io.download).mockResolvedValue({data:stored,error:null});
    await expect(processPaymentProof(input(),io)).rejects.toThrow('verified'); expect(read).not.toHaveBeenCalled(); expect(io.complete).not.toHaveBeenCalled();
  });
  it('rejects oversized declared pixels before beginning a submission', async () => {
    vi.mocked(io.decode).mockRejectedValueOnce(new Error('Screenshot exceeds the safe image dimensions or pixel limit.'));
    await expect(processPaymentProof(input(),io)).rejects.toThrow('pixel limit'); expect(io.begin).not.toHaveBeenCalled(); expect(io.complete).not.toHaveBeenCalled();
  });
  it.each(['upload', 'download', 'mismatch', 'completion'])('handles %s failure without false success', async stage => {
    if (stage === 'upload') vi.mocked(io.upload).mockResolvedValue({ error: { statusCode: '500', message: 'secret duplicate text' } });
    if (stage === 'download') vi.mocked(io.download).mockResolvedValue({ error: { message: 'private details' }, data: null });
    if (stage === 'mismatch') { const other = bytes.slice(); other[40] = (other[40] ?? 0) ^ 1; vi.mocked(io.download).mockResolvedValue({ data: new Blob([other]), error: null }); }
    if (stage === 'completion') vi.mocked(io.complete).mockRejectedValue(new Error('Completion unavailable'));
    await expect(processPaymentProof(input(), io)).rejects.toThrow();
    if (stage !== 'completion') expect(io.complete).not.toHaveBeenCalled();
  });
  it('retries a duplicate upload only after exact stored-byte verification', async () => {
    vi.mocked(io.upload).mockResolvedValue({ error: { statusCode: '409' } });
    await expect(processPaymentProof(input(), io)).resolves.toEqual({ id }); expect(io.complete).toHaveBeenCalledTimes(1);
  });
  it('does not repeat upload or completion for an already completed request ID', async () => {
    vi.mocked(io.begin).mockResolvedValue({ data: { ...row, submitted_at: '2026-10-17T00:00:00Z' }, error: null });
    await processPaymentProof(input(), io); await processPaymentProof(input(), io);
    expect(io.upload).not.toHaveBeenCalled(); expect(io.complete).not.toHaveBeenCalled();
  });
  it('reuses request ID after completion failure and verifies duplicate stored upload', async () => {
    vi.mocked(io.complete).mockRejectedValueOnce(new Error('lost response')).mockResolvedValueOnce(undefined);
    await expect(processPaymentProof(input(), io)).rejects.toThrow();
    vi.mocked(io.upload).mockResolvedValue({ error: { statusCode: '409' } });
    await expect(processPaymentProof(input(), io)).resolves.toEqual({ id });
    expect(vi.mocked(io.begin).mock.calls.map(c => c[0].p_request_id)).toEqual([id, id]);
  });
});
