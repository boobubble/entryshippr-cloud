export const IMAGE_LIMIT = 5 * 1024 * 1024;
export const IMAGE_TYPES = ['image/png', 'image/jpeg', 'image/webp'] as const;
export function validateImageMeta(type: string, size: number) {
  if (!IMAGE_TYPES.some(t => t === type)) throw new Error('Choose a PNG, JPG or WebP image.');
  if (!Number.isInteger(size) || size < 12 || size > IMAGE_LIMIT) throw new Error('Image must be no larger than 5 MB.');
}
export function validateImageBytes(bytes: Uint8Array, type: string) {
  validateImageMeta(type, bytes.length);
  const text = (start: number, end: number) => String.fromCharCode(...bytes.slice(start, end));
  const png = [137,80,78,71,13,10,26,10].every((n,i) => bytes[i] === n);
  const jpg = bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255;
  const webp = text(0,4) === 'RIFF' && text(8,12) === 'WEBP';
  if (!(type === 'image/png' ? png : type === 'image/jpeg' ? jpg : webp)) throw new Error('Image contents do not match its format.');
}
export function imageExtension(type: string) { validateImageMeta(type, 12); return type === 'image/png' ? 'png' : type === 'image/jpeg' ? 'jpg' : 'webp'; }
export function validateReference(value: string) {
  const reference = value.trim();
  if (reference.length < 3 || reference.length > 100 || /[\x00-\x1f\x7f]/.test(reference)) throw new Error('Enter a transaction reference / UTR (3–100 characters).');
  return reference;
}
