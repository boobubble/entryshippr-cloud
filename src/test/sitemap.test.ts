import { describe,it,expect,vi } from 'vitest';
import { buildSitemap,escapeXml,sitemapBatch } from '@/lib/sitemap';
describe('Sitemap',()=>{
 it.each(['PGRST205','42P01'])('returns static URLs before blog setup (%s)',async code=>{const xml=await buildSitemap(async offset=>sitemapBatch(null,{code},offset));expect(xml.match(/<url>/g)).toHaveLength(2);expect(xml).toContain('https://entryshippr-cloud.lovable.app/</loc>');expect(xml).toContain('https://entryshippr-cloud.lovable.app/blog</loc>');});
 it.each(['42501','PGRST301','08006'])('does not hide permissions or connection errors (%s)',async code=>{await expect(buildSitemap(async offset=>sitemapBatch(null,{code},offset))).rejects.toThrow('unavailable');});
 it('does not hide a missing table after article batches started',()=>expect(sitemapBatch(null,{code:'PGRST205'},1000).error).toBe(true));
 it('includes only public static routes when no published articles exist',async()=>{const xml=await buildSitemap(async()=>({rows:[],error:false}));expect(xml).toContain('/blog</loc>');expect(xml).not.toContain('/admin');expect(xml).not.toContain('/billing');});
 it('includes returned published article slugs',async()=>expect(await buildSitemap(async()=>({rows:[{slug:'real-article',updated_at:'2026-10-17'}],error:false}))).toContain('/blog/real-article</loc>'));
 it('fails instead of producing partial sitemap on later batch error',async()=>{const fetch=vi.fn().mockResolvedValueOnce({rows:Array.from({length:1000},(_,i)=>({slug:`article-${i}`,updated_at:''})),error:false}).mockResolvedValueOnce({rows:[],error:true});await expect(buildSitemap(fetch)).rejects.toThrow();expect(fetch).toHaveBeenNthCalledWith(2,1000);});
 it('escapes XML',()=>expect(escapeXml('a&<b>')).toBe('a&amp;&lt;b&gt;'));
});
