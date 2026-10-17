import { validateImageBytes } from './image-validation';

/** Proofs are still images: bounded RGBA output, original bytes never rewritten.
 * Decoder scratch/WASM heap is additional memory, not covered by RGBA_BYTES. */
export const PROOF_LIMITS = { width: 4096, height: 4096, pixels: 2_000_000, rgbaBytes: 8_000_000, frames: 1 } as const;
export function validateProofDimensions(width: number, height: number) {
  if (!Number.isInteger(width) || !Number.isInteger(height) || width < 1 || height < 1 ||
      width > PROOF_LIMITS.width || height > PROOF_LIMITS.height || width * height > PROOF_LIMITS.pixels || width * height * 4 > PROOF_LIMITS.rgbaBytes)
    throw new Error('Screenshot exceeds the safe image dimensions or pixel limit.');
  return { width, height };
}

/** Strict container preflight. Pixel decoding is additionally required on the server. */
export function validatePaymentProofBytes(bytes: Uint8Array, type: string): { width: number; height: number } {
  validateImageBytes(bytes, type);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const invalid = (): never => { throw new Error('Screenshot is incomplete or has an invalid image structure.'); };
  const animation = (): never => { throw new Error('Payment screenshots must be a single still image, not an animation.'); };
  const text = (o: number, n: number) => String.fromCharCode(...bytes.subarray(o, o + n));
  if (type === 'image/png') {
    let offset = 8, imageData = false, endedData = false, header = false, palette = false;
    let dimensions = { width: 0, height: 0 }, color = 0;
    while (offset + 12 <= bytes.length) {
      const length = view.getUint32(offset), chunk = text(offset + 4, 4), end = offset + 12 + length;
      if (end > bytes.length || !/^[A-Za-z]{4}$/.test(chunk) || (bytes[offset + 6] & 32)) invalid();
      if (!header) {
        if (chunk !== 'IHDR' || length !== 13) invalid();
        dimensions = validateProofDimensions(view.getUint32(offset + 8), view.getUint32(offset + 12));
        const depth = bytes[offset + 16]; color = bytes[offset + 17];
        const depths: Record<number, number[]> = { 0: [1,2,4,8,16], 2: [8,16], 3: [1,2,4,8], 4: [8,16], 6: [8,16] };
        if (!depths[color]?.includes(depth) || bytes[offset + 18] !== 0 || bytes[offset + 19] !== 0 || bytes[offset + 20] > 1) invalid();
        header = true;
      } else if (chunk === 'IHDR') invalid();
      let crc = 0xffffffff;
      for (let i = offset + 4; i < end - 4; i++) {
        crc ^= bytes[i];
        for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
      }
      if (((crc ^ 0xffffffff) >>> 0) !== view.getUint32(end - 4)) invalid();
      if (['acTL','fcTL','fdAT'].includes(chunk)) animation();
      if (chunk === 'PLTE') {
        if (palette || imageData || length < 3 || length > 768 || length % 3 || [0,4].includes(color)) invalid();
        palette = true;
      }
      if (chunk === 'IDAT') {
        if (endedData || (color === 3 && !palette)) invalid();
        if (length > 0) imageData = true;
      } else if (imageData) endedData = true;
      if (!(bytes[offset + 4] & 32) && !['IHDR','PLTE','IDAT','IEND'].includes(chunk)) invalid();
      if (chunk === 'IEND') {
        if (length !== 0 || !imageData || end !== bytes.length) invalid();
        return dimensions;
      }
      offset = end;
    }
    return invalid();
  }
  if (type === 'image/jpeg') {
    let offset = 2, frame = 0, scan = false;
    let dimensions = { width: 0, height: 0 };
    const components = new Map<number, number>(), quant = new Set<number>(), huffman = new Set<number>();
    while (offset < bytes.length) {
      if (bytes[offset++] !== 0xff) invalid();
      while (bytes[offset] === 0xff) offset++;
      if (offset >= bytes.length) invalid();
      const marker = bytes[offset++];
      if (marker === 0xd9) {
        if (!frame || !scan || offset !== bytes.length) invalid();
        return dimensions;
      }
      if (marker === 0 || marker === 0xd8 || (marker >= 0xd0 && marker <= 0xd7)) invalid();
      if (offset + 2 > bytes.length) invalid();
      const length = view.getUint16(offset), end = offset + length;
      if (length < 2 || end > bytes.length) invalid();
      if ((marker >= 0xc0 && marker <= 0xcf) && ![0xc4,0xc8,0xcc].includes(marker)) {
        if (frame || ![0xc0,0xc2].includes(marker) || length < 8 || bytes[offset + 2] !== 8) invalid();
        dimensions = validateProofDimensions(view.getUint16(offset + 5), view.getUint16(offset + 3));
        const count = bytes[offset + 7];
        if (![1,3,4].includes(count) || length !== 8 + 3 * count) invalid();
        for (let i = offset + 8; i < end; i += 3) {
          const id = bytes[i], sampling = bytes[i + 1], q = bytes[i + 2];
          if (components.has(id) || (sampling >> 4) < 1 || (sampling >> 4) > 4 || (sampling & 15) < 1 || (sampling & 15) > 4 || q > 3) invalid();
          components.set(id, q);
        }
        frame = marker;
      } else if (marker === 0xdb) {
        let i = offset + 2;
        while (i < end) {
          const table = bytes[i++], precision = table >> 4;
          if (precision > 1 || (table & 15) > 3 || i + 64 * (precision + 1) > end) invalid();
          quant.add(table & 15); i += 64 * (precision + 1);
        }
        if (i !== end) invalid();
      } else if (marker === 0xc4) {
        let i = offset + 2;
        while (i < end) {
          const table = bytes[i++];
          if ((table >> 4) > 1 || (table & 15) > 3 || i + 16 > end) invalid();
          let count = 0, available = 1;
          for (let n = 0; n < 16; n++) { const size = bytes[i++]; count += size; available = available * 2 - size; if (available < 0) invalid(); }
          if (!count || count > 256 || i + count > end) invalid();
          huffman.add(table); i += count;
        }
        if (i !== end) invalid();
      } else if (marker === 0xda) {
        if (!frame || length < 6) invalid();
        const count = bytes[offset + 2];
        if (!count || count > components.size || length !== 6 + 2 * count) invalid();
        const ss = bytes[end - 3], se = bytes[end - 2], ah = bytes[end - 1] >> 4, al = bytes[end - 1] & 15;
        if (frame === 0xc0 ? (ss !== 0 || se !== 63 || ah !== 0 || al !== 0) : (ss > se || se > 63 || ah > 13 || al > 13 || (ss === 0 && se !== 0) || (ss > 0 && count !== 1) || (ah !== 0 && ah !== al + 1))) invalid();
        const seen = new Set<number>();
        for (let i = offset + 3; i < end - 3; i += 2) {
          const id = bytes[i], tables = bytes[i + 1], q = components.get(id);
          if (q === undefined || seen.has(id) || !quant.has(q) || (tables >> 4) > 3 || (tables & 15) > 3) invalid();
          if ((ss === 0 && ah === 0 && !huffman.has(tables >> 4)) || (se > 0 && !huffman.has(16 + (tables & 15)))) invalid();
          seen.add(id);
        }
        offset = end; const start = offset;
        while (offset < bytes.length) {
          if (bytes[offset] !== 0xff) { offset++; continue; }
          let next = offset + 1; while (bytes[next] === 0xff) next++;
          if (next >= bytes.length) invalid();
          const m = bytes[next];
          if (m === 0 || (m >= 0xd0 && m <= 0xd7)) { offset = next + 1; continue; }
          break;
        }
        if (offset === start) invalid();
        scan = true; continue;
      } else if (!((marker >= 0xe0 && marker <= 0xef) || marker === 0xfe || (marker === 0xdd && length === 4))) invalid();
      offset = end;
    }
    return invalid();
  }
  if (view.getUint32(4, true) + 8 !== bytes.length) invalid();
  let offset = 12, image = false, extended: { width: number; height: number } | undefined;
  let dimensions = { width: 0, height: 0 };
  while (offset + 8 <= bytes.length) {
    const chunk = text(offset, 4), length = view.getUint32(offset + 4, true), start = offset + 8, end = start + length;
    if (end + (length & 1) > bytes.length || ((length & 1) && bytes[end] !== 0)) invalid();
    if (chunk === 'ANIM' || chunk === 'ANMF') animation();
    if (chunk === 'VP8X') {
      if (offset !== 12 || extended || length !== 10 || (bytes[start] & 0xc1) || bytes[start + 1] || bytes[start + 2] || bytes[start + 3]) invalid();
      if (bytes[start] & 2) animation();
      const u24 = (o: number) => bytes[o] + bytes[o + 1] * 256 + bytes[o + 2] * 65536;
      extended = validateProofDimensions(u24(start + 4) + 1, u24(start + 7) + 1);
    } else if (chunk === 'VP8 ') {
      if (image || length <= 10 || (bytes[start] & 1) || ((bytes[start] >> 1) & 7) > 3 || !(bytes[start] & 16) || text(start + 3, 3) !== '\x9d\x01\x2a') invalid();
      dimensions = validateProofDimensions(view.getUint16(start + 6, true) & 0x3fff, view.getUint16(start + 8, true) & 0x3fff); image = true;
    } else if (chunk === 'VP8L') {
      if (image || length <= 5 || bytes[start] !== 0x2f) invalid();
      const bits = view.getUint32(start + 1, true);
      if (bits >>> 29) invalid();
      dimensions = validateProofDimensions((bits & 0x3fff) + 1, ((bits >>> 14) & 0x3fff) + 1); image = true;
    }
    offset = end + (length & 1);
  }
  if (!image || offset !== bytes.length || (extended && (extended.width !== dimensions.width || extended.height !== dimensions.height))) invalid();
  return dimensions;
}
