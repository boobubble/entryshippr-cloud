import { describe,it,expect } from 'vitest';
import { IMAGE_LIMIT,validateImageMeta,validateImageBytes,validateReference } from '@/lib/image-validation';
describe('Payment proofs',()=>{
 it('permits exactly 5 MB and rejects larger files',()=>{expect(()=>validateImageMeta('image/png',5*1024*1024)).not.toThrow();expect(()=>validateImageMeta('image/png',IMAGE_LIMIT+1)).toThrow();});
 it.each(['image/svg+xml','text/html','application/pdf'])('rejects %s',type=>expect(()=>validateImageMeta(type,20)).toThrow());
 it.each(['image/png','image/jpeg','image/webp'])('rejects forged %s',type=>expect(()=>validateImageBytes(new Uint8Array(20),type)).toThrow());
 it('accepts PNG signature',()=>expect(()=>validateImageBytes(new Uint8Array([137,80,78,71,13,10,26,10,0,0,0,0]),'image/png')).not.toThrow());
 it('accepts JPG signature',()=>expect(()=>validateImageBytes(new Uint8Array([255,216,255,0,0,0,0,0,0,0,0,0]),'image/jpeg')).not.toThrow());
 it('accepts WebP signature',()=>expect(()=>validateImageBytes(new TextEncoder().encode('RIFF0000WEBP'),'image/webp')).not.toThrow());
 it('bounds transaction reference and rejects control characters',()=>{expect(validateReference(' UTR123 ')).toBe('UTR123');expect(()=>validateReference('xx')).toThrow();expect(()=>validateReference('a'.repeat(101))).toThrow();expect(()=>validateReference('UTR\n123')).toThrow();});
});
