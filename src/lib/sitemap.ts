import { SITE_URL } from './blog-validation';
export function escapeXml(v:string){return v.replace(/[<>&"']/g,c=>({'<':'&lt;','>':'&gt;','&':'&amp;','"':'&quot;',"'":'&apos;'}[c]||c));}
// An unapplied blog schema has no article URLs yet; other failures must not
// disguise a partial sitemap as a successful one.
export function sitemapBatch(rows: {slug:string;updated_at:string}[] | null, error: {code?:string} | null, offset:number) {
 const setupPending = offset === 0 && (error?.code === 'PGRST205' || error?.code === '42P01');
 return { rows: rows || [], error: !!error && !setupPending };
}
export async function buildSitemap(fetchPage:(offset:number)=>Promise<{rows:{slug:string;updated_at:string}[];error:boolean}>){
 const urls=[`${SITE_URL}/`,`${SITE_URL}/blog`];let offset=0;
 for(;;){const r=await fetchPage(offset);if(r.error)throw new Error('Sitemap data unavailable.');for(const p of r.rows){if(!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(p.slug))throw new Error('Invalid article slug.');urls.push(`${SITE_URL}/blog/${p.slug}`);}if(r.rows.length<1000)break;offset+=1000;if(offset>=49000)throw new Error('Sitemap index required before exceeding URL limit.');}
 return `<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${urls.map(u=>`<url><loc>${escapeXml(u)}</loc></url>`).join('')}</urlset>`;
}
