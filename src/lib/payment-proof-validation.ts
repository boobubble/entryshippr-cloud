import { validateImageBytes } from './image-validation';

/** Container checks only, not full pixel decoding. Preserve original proof bytes. */
export function validatePaymentProofBytes(bytes: Uint8Array, type: string) {
  validateImageBytes(bytes, type);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const invalid = () => { throw new Error('Screenshot is incomplete or has an invalid image structure.'); };
  const text = (offset: number, length: number) => String.fromCharCode(...bytes.subarray(offset, offset + length));
  if (type === 'image/png') {
    let offset = 8;
    let imageData = false;
    let header = false;
    while (offset + 12 <= bytes.length) {
      const length = view.getUint32(offset);
      const chunk = text(offset + 4, 4);
      const end = offset + 12 + length;
      if (end > bytes.length) invalid();
      if (!header) {
        if (chunk !== 'IHDR' || length !== 13 || view.getUint32(offset + 8) === 0 || view.getUint32(offset + 12) === 0) invalid();
        header = true;
      } else if (chunk === 'IHDR') invalid();
      let crc = 0xffffffff;
      for (let i = offset + 4; i < end - 4; i++) {
        crc ^= bytes[i];
        for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
      }
      if (((crc ^ 0xffffffff) >>> 0) !== view.getUint32(end - 4)) invalid();
      if (chunk === 'IDAT' && length > 0) imageData = true;
      if (chunk === 'IEND') {
        if (length !== 0 || !imageData || end !== bytes.length) invalid();
        return;
      }
      offset = end;
    }
    invalid();
  } else if (type === 'image/jpeg') {
    let offset = 2;
    let frame = false;
    let scan = false;
    while (offset < bytes.length) {
      if (bytes[offset++] !== 0xff) invalid();
      while (bytes[offset] === 0xff) offset++;
      if (offset >= bytes.length) invalid();
      const marker = bytes[offset++];
      if (marker === 0xd9) {
        if (!frame || !scan || offset !== bytes.length) invalid();
        return;
      }
      if (marker === 0 || marker === 0xd8 || (marker >= 0xd0 && marker <= 0xd7)) invalid();
      if (marker === 0x01) continue;
      if (offset + 2 > bytes.length) invalid();
      const length = view.getUint16(offset);
      if (length < 2 || offset + length > bytes.length) invalid();
      if ([0xc0,0xc1,0xc2,0xc3,0xc5,0xc6,0xc7,0xc9,0xca,0xcb,0xcd,0xce,0xcf].includes(marker)) {
        if (length < 8 || view.getUint16(offset + 3) === 0 || view.getUint16(offset + 5) === 0) invalid();
        frame = true;
      }
      offset += length;
      if (marker === 0xda) {
        if (!frame || length < 6) invalid();
        const start = offset;
        while (offset < bytes.length) {
          if (bytes[offset] !== 0xff) { offset++; continue; }
          let next = offset + 1;
          while (bytes[next] === 0xff) next++;
          if (next >= bytes.length) invalid();
          if (bytes[next] === 0 || (bytes[next] >= 0xd0 && bytes[next] <= 0xd7)) { offset = next + 1; continue; }
          break;
        }
        if (offset === start) invalid();
        scan = true;
      }
    }
    invalid();
  } else {
    if (view.getUint32(4, true) + 8 !== bytes.length) invalid();
    let offset = 12;
    let image = false;
    while (offset + 8 <= bytes.length) {
      const chunk = text(offset, 4);
      const length = view.getUint32(offset + 4, true);
      const end = offset + 8 + length;
      if (end + (length & 1) > bytes.length) invalid();
      if (chunk === 'VP8 ') {
        if (length < 10 || text(offset + 11, 3) !== '\x9d\x01\x2a' || (view.getUint16(offset + 14, true) & 0x3fff) === 0 || (view.getUint16(offset + 16, true) & 0x3fff) === 0) invalid();
        image = true;
      } else if (chunk === 'VP8L') {
        if (length < 5 || bytes[offset + 8] !== 0x2f) invalid();
        image = true;
      } else if (chunk === 'ANMF') {
        if (length < 24) invalid();
        // Animated containers need pixel decoding to validate their nested frames.
        image = true;
      } else if (chunk === 'VP8X' && length !== 10) invalid();
      offset = end + (length & 1);
    }
    if (!image || offset !== bytes.length) invalid();
  }
}