import { describe,it,expect,vi } from 'vitest';
import { buildSitemap,escapeXml } from '@/lib/sitemap';
describe('Sitemap',()=>{
 it('includes only public static routes when no published articles exist',async()=>{const xml=await buildSitemap(async()=>({rows:[],error:false}));expect(xml).toContain('/blog</loc>');expect(xml).not.toContain('/admin');expect(xml).not.toContain('/billing');});
 it('includes returned published article slugs',async()=>expect(await buildSitemap(async()=>({rows:[{slug:'real-article',updated_at:'2026-10-17'}],error:false}))).toContain('/blog/real-article</loc>'));
 it('fails instead of producing partial sitemap on later batch error',async()=>{const fetch=vi.fn().mockResolvedValueOnce({rows:Array.from({length:1000},(_,i)=>({slug:`article-${i}`,updated_at:''})),error:false}).mockResolvedValueOnce({rows:[],error:true});await expect(buildSitemap(fetch)).rejects.toThrow();expect(fetch).toHaveBeenNthCalledWith(2,1000);});
 it('escapes XML',()=>expect(escapeXml('a&<b>')).toBe('a&amp;&lt;b&gt;'));
});
