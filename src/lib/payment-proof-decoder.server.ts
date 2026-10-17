import { validatePaymentProofBytes } from './payment-proof-validation';

/** Photon has explicit workerd/Node exports and performs real pixel decoding.
 * Only inspect the decoded dimensions; never encode/export replacement proof bytes.
 * Synchronous decode/free means no overlapping decodes within this isolate. */
export async function decodePaymentProof(bytes: Uint8Array, type: string) {
  const expected = validatePaymentProofBytes(bytes, type);
  const { PhotonImage } = await import('@cf-wasm/photon').catch(() => { throw new Error('Screenshot validation is temporarily unavailable.'); });
  let image: InstanceType<typeof PhotonImage> | undefined;
  const originalError = console.error;
  try {
    // Photon panic hooks print codec data. Suppress only during synchronous decode;
    // there is no await here, so another request cannot run in this interval.
    console.error = () => {};
    image = PhotonImage.new_from_byteslice(bytes);
    if (image.get_width() !== expected.width || image.get_height() !== expected.height)
      throw new Error('Decoded dimensions do not match.');
  } catch {
    // WASM panics and codec messages can contain data. Never forward or log them.
    throw new Error('Screenshot pixels could not be decoded safely.');
  } finally { console.error = originalError; image?.free(); }
}
