import { createFileRoute } from '@tanstack/react-router';
import { SUPABASE_URL } from '@/lib/supabase';
import { validateImageBytes } from '@/lib/image-validation';
export const Route=createFileRoute('/api/public/blog-images/$id')({server:{handlers:{GET:async({params})=>{
 const headers={'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'};
 if(!/^[0-9a-f-]{36}$/i.test(params.id))return new Response('Not found',{status:404,headers});
 const {externalClient}=await import('@/lib/external-auth.server');
 const post=await externalClient().from('blog_posts').select('featured_image_path').eq('id',params.id).eq('status','published').maybeSingle();
 if(post.error)return new Response('Unavailable',{status:503,headers});const path=post.data?.featured_image_path;
 if(!path||!path.startsWith(`${params.id}/`))return new Response('Not found',{status:404,headers});
 const key=process.env['EXT_SUPABASE_SECRET_KEY'];if(!key)return new Response('Unavailable',{status:503,headers});
 const image=await fetch(`${SUPABASE_URL}/storage/v1/object/authenticated/blog-images/${path}`,{headers:{apikey:key,Authorization:`Bearer ${key}`}});
 if(!image.ok)return new Response('Not found',{status:404,headers});
 const type=image.headers.get('content-type')?.split(';')[0]||'';if(Number(image.headers.get('content-length'))>5242880)return new Response('Unavailable',{status:503,headers});
 const bytes=new Uint8Array(await image.arrayBuffer());try{validateImageBytes(bytes,type);}catch{return new Response('Unavailable',{status:503,headers});}
 // Recheck publication after fetching to avoid serving an image unpublished during the request.
 const check=await externalClient().from('blog_posts').select('id').eq('id',params.id).eq('status','published').eq('featured_image_path',path).maybeSingle();if(check.error||!check.data)return new Response('Not found',{status:404,headers});
 return new Response(bytes,{headers:{...headers,'Content-Type':type,'Content-Disposition':'inline'}});
}}}});
