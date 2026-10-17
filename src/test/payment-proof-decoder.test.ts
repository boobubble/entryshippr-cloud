// @vitest-environment node
import { describe, expect, it, vi } from 'vitest';
import { decodePaymentProof } from '@/lib/payment-proof-decoder.server';
import { validatePaymentProofBytes, validateProofDimensions, PROOF_LIMITS } from '@/lib/payment-proof-validation';
import { png, jpeg, progressive, webp, lossless, animated, apng } from './payment-image-fixtures';
const bytes = (f: { base64: string }) => new Uint8Array(Buffer.from(f.base64, 'base64'));
function crcChunk(data: Uint8Array, offset: number) {
  const v = new DataView(data.buffer); const end = offset + 12 + v.getUint32(offset); let crc = 0xffffffff;
  for (let i = offset + 4; i < end - 4; i++) { crc ^= v.getUint8(i); for (let b = 0; b < 8; b++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0); }
  v.setUint32(end - 4, (crc ^ 0xffffffff) >>> 0);
}
describe('Actual WASM pixel decode and pre-allocation limits', () => {
  it.each([png,jpeg,progressive,webp,lossless])('decodes real $type pixels without modifying evidence', async f => {
    const data = bytes(f), original = data.slice(); await decodePaymentProof(data, f.type); expect(data).toEqual(original);
  });
  it.each([animated,apng])('rejects animated $type before decoding', async f => { await expect(decodePaymentProof(bytes(f), f.type)).rejects.toThrow('single still'); });
  it.each([18,19,20])('rejects invalid PNG IHDR field at %s even with correct CRC', index => {
    const data = bytes(png); data[index] = 3; crcChunk(data,8); expect(() => validatePaymentProofBytes(data,png.type)).toThrow();
  });
  it('rejects corrupted PNG IDAT with valid container CRC during actual decoding', async () => {
    const data = bytes(png); data[43] = 0; crcChunk(data,33);
    expect(() => validatePaymentProofBytes(data,png.type)).not.toThrow();
    const log = vi.spyOn(console,'error').mockImplementation(() => {});
    try { await expect(decodePaymentProof(data,png.type)).rejects.toThrow('pixels'); } finally { log.mockRestore(); }
  });
  it('rejects zero JPEG SOF height', () => {
    const data = bytes(jpeg); const i = Buffer.from(data).indexOf(Buffer.from([255,192])); const v = new DataView(data.buffer); v.setUint16(i+5,0);
    expect(() => validatePaymentProofBytes(data,jpeg.type)).toThrow();
  });
  it.each([0xdb,0xc4])('rejects JPEG missing coding table %s', marker => {
    const data = bytes(jpeg), output: number[] = [255,216]; let i = 2;
    while (i < data.length) { if (data[i] !== 255) break; const m = data[i+1]; if (m === 0xda) { output.push(...data.subarray(i)); break; } const n = new DataView(data.buffer).getUint16(i+2); if (m !== marker) output.push(...data.subarray(i,i+2+n)); i += 2+n; }
    expect(() => validatePaymentProofBytes(new Uint8Array(output),jpeg.type)).toThrow();
  });
  it('rejects invalid baseline scan parameters', () => {
    const data = bytes(jpeg), i = Buffer.from(data).indexOf(Buffer.from([255,218])); const n = new DataView(data.buffer).getUint16(i+2); data[i+2+n-2] = 64;
    expect(() => validatePaymentProofBytes(data,jpeg.type)).toThrow();
  });
  it('rejects WebP lossless version', () => { const data = bytes(lossless); data[24] = (data[24] ?? 0) | 0xe0; expect(() => validatePaymentProofBytes(data,lossless.type)).toThrow(); });
  it.each([1,64,128])('rejects reserved VP8X flag %s', flag => { const data = bytes(webp); data[20] = (data[20] ?? 0) | flag; expect(() => validatePaymentProofBytes(data,webp.type)).toThrow(); });
  it.each([[4097,1],[1,4097],[2000,1001],[0,1]])('rejects resource dimensions %s x %s', (w,h) => { expect(() => validateProofDimensions(w,h)).toThrow(); });
  it('documents exact maximum output and one-frame budget', () => {
    expect(PROOF_LIMITS).toEqual({ width:4096,height:4096,pixels:2_000_000,rgbaBytes:8_000_000,frames:1 });
    expect(validateProofDimensions(2000,1000)).toEqual({width:2000,height:1000});
  });
  it('rejects an enormous CRC-correct PNG before decode', async () => { const data = bytes(png); new DataView(data.buffer).setUint32(16,0x7fffffff); crcChunk(data,8); await expect(decodePaymentProof(data,png.type)).rejects.toThrow('limit'); });
  it.each([png,jpeg,webp,lossless])('rejects all cross-format MIME mismatches for $type', async f => { for (const type of ['image/png','image/jpeg','image/webp'].filter(t=>t!==f.type)) await expect(decodePaymentProof(bytes(f),type)).rejects.toThrow(); });
});
