import { createFileRoute } from '@tanstack/react-router';
import { buildSitemap } from '@/lib/sitemap';
export const Route=createFileRoute('/sitemap.xml')({server:{handlers:{GET:async()=>{
 const {externalClient}=await import('@/lib/external-auth.server');const client=externalClient();
 try{const xml=await buildSitemap(async offset=>{const r=await client.from('blog_posts').select('slug,updated_at').eq('status','published').order('id').range(offset,offset+999);return {rows:r.data||[],error:!!r.error};});return new Response(xml,{headers:{'Content-Type':'application/xml; charset=utf-8','Cache-Control':'no-store'}});}catch{return new Response('Sitemap temporarily unavailable',{status:503,headers:{'Cache-Control':'no-store'}});}
}}}});
