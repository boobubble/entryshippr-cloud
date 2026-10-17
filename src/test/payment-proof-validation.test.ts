import { describe, it, expect } from 'vitest';
import { validatePaymentProofBytes } from '@/lib/payment-proof-validation';
import { png, jpeg, progressive, webp, lossless, animated, apng } from './payment-image-fixtures';

const bytes = (base64: string) => new Uint8Array(Buffer.from(base64, 'base64'));
describe('Payment proof container validation', () => {
  it.each([png, jpeg, progressive, webp, lossless])('accepts a genuinely encoded $type without changing stored bytes', fixture => {
    const data = bytes(fixture.base64);
    const original = data.slice();
    expect(() => validatePaymentProofBytes(data, fixture.type)).not.toThrow();
    expect(data).toEqual(original);
  });
  it.each([animated, apng])('rejects animation $type', fixture => {
    expect(() => validatePaymentProofBytes(bytes(fixture.base64), fixture.type)).toThrow('single still image');
  });
  it.each([png, jpeg, progressive, webp, lossless, animated, apng])('rejects truncated $type', fixture => {
    const data = bytes(fixture.base64);
    expect(() => validatePaymentProofBytes(data.subarray(0, 12), fixture.type)).toThrow();
    expect(() => validatePaymentProofBytes(data.subarray(0, data.length - 2), fixture.type)).toThrow();
  });
  it('rejects PNG chunk overruns and invalid CRC', () => {
    const data = bytes(png.base64);
    const view = new DataView(data.buffer);
    view.setUint8(16, view.getUint8(16) ^ 1);
    expect(() => validatePaymentProofBytes(data, png.type)).toThrow();
    new DataView(data.buffer).setUint32(8, 0xffffffff);
    expect(() => validatePaymentProofBytes(data, png.type)).toThrow();
  });
  it('rejects JPEG segment overruns and missing scan data', () => {
    const data = bytes(jpeg.base64);
    data[4] = 255; data[5] = 255;
    expect(() => validatePaymentProofBytes(data, jpeg.type)).toThrow();
    const noScan = new Uint8Array([255,216,255,254,0,6,1,2,3,4,255,217]);
    expect(() => validatePaymentProofBytes(noScan, jpeg.type)).toThrow();
  });
  it.each([webp, lossless, animated])('rejects mismatched RIFF size and chunk overruns in $type', fixture => {
    const data = bytes(fixture.base64);
    const view = new DataView(data.buffer);
    view.setUint32(4, data.length - 7, true);
    expect(() => validatePaymentProofBytes(data, fixture.type)).toThrow();
    view.setUint32(4, data.length - 8, true);
    view.setUint32(16, 0xffffffff, true);
    expect(() => validatePaymentProofBytes(data, fixture.type)).toThrow();
  });
  it('rejects a real PNG mislabeled as JPEG', () => {
    expect(() => validatePaymentProofBytes(bytes(png.base64), 'image/jpeg')).toThrow();
  });
});