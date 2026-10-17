import { validatePaymentProofBytes } from './payment-proof-validation';

/** Photon has explicit workerd/Node exports and performs real pixel decoding.
 * Only inspect the decoded dimensions; never encode/export replacement proof bytes.
 * Synchronous decode/free means no overlapping decodes within this isolate. */
export async function decodePaymentProof(bytes: Uint8Array, type: string) {
  const expected = validatePaymentProofBytes(bytes, type);
  const { PhotonImage } = await import('@cf-wasm/photon');
  let image: InstanceType<typeof PhotonImage> | undefined;
  try {
    image = PhotonImage.new_from_byteslice(bytes);
    if (image.get_width() !== expected.width || image.get_height() !== expected.height)
      throw new Error('Decoded dimensions do not match.');
  } catch {
    // WASM panics and codec messages can contain data. Never forward or log them.
    throw new Error('Screenshot pixels could not be decoded safely.');
  } finally { image?.free(); }
}
