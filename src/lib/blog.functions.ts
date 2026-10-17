import { createServerFn } from '@tanstack/react-start';
import { z } from 'zod';
import { postSchema,validateBlogDocument,type BlogPost } from './blog-validation';
import { validateImageBytes,imageExtension } from './image-validation';
export const listPublishedPosts=createServerFn({method:'GET'}).inputValidator(z.object({page:z.number().int().min(0).max(10000).default(0),limit:z.number().int().min(1).max(50).default(12)})).handler(async({data})=>{
 const {externalClient}=await import('./external-auth.server'); const client=externalClient();
 const r=await client.from('blog_posts').select('id,title,slug,excerpt,featured_image_path,image_alt,published_at,updated_at',{count:'exact'}).eq('status','published').order('published_at',{ascending:false}).order('id').range(data.page*data.limit,data.page*data.limit+data.limit-1);
 if(r.error)return {posts:[] as BlogPost[],count:0,unavailable:true};return {posts:r.data as BlogPost[],count:r.count||0,unavailable:false};
});
export const getPublishedPost=createServerFn({method:'GET'}).inputValidator(z.object({slug:z.string().max(160).regex(/^[a-z0-9]+(?:-[a-z0-9]+)*$/)})).handler(async({data})=>{
 const {externalClient}=await import('./external-auth.server');const r=await externalClient().from('blog_posts').select('*').eq('slug',data.slug).eq('status','published').maybeSingle();
 if(r.error)throw new Error('Articles are temporarily unavailable.');if(!r.data)return null;validateBlogDocument(r.data.content);return r.data as BlogPost;
});
export const getBlogAdmin=createServerFn({method:'POST'}).inputValidator(z.object({token:z.string().min(20),page:z.number().int().min(0).max(10000)})).handler(async({data})=>{
 const {authenticatedClient,dbError}=await import('./external-auth.server');const {client}=await authenticatedClient(data.token,true);
 const [posts,categories,tags]=await Promise.all([client.from('blog_posts').select('*',{count:'exact'}).order('updated_at',{ascending:false}).order('id').range(data.page*20,data.page*20+19),client.from('blog_categories').select('id,name').order('name'),client.from('blog_tags').select('id,name').order('name')]);
 [posts,categories,tags].forEach(r=>dbError(r.error));return {posts:posts.data as BlogPost[],count:posts.count||0,categories:categories.data||[],tags:tags.data||[]};
});
export const getAdminPost=createServerFn({method:'POST'}).inputValidator(z.object({token:z.string().min(20),id:z.string().uuid()})).handler(async({data})=>{
 const {authenticatedClient,dbError}=await import('./external-auth.server');const {client}=await authenticatedClient(data.token,true);
 const [p,t]=await Promise.all([client.from('blog_posts').select('*').eq('id',data.id).maybeSingle(),client.from('blog_post_tags').select('tag_id').eq('post_id',data.id)]);dbError(p.error);dbError(t.error);return {post:p.data as BlogPost|null,tags:(t.data||[]).map(t=>t.tag_id as string)};
});
export const saveBlogPost=createServerFn({method:'POST'}).inputValidator(z.object({token:z.string().min(20),post:postSchema})).handler(async({data})=>{
 const {authenticatedClient,dbError}=await import('./external-auth.server');const {client}=await authenticatedClient(data.token,true);
 const r=await client.rpc('save_blog_post',{p_post:data.post});dbError(r.error);return {id:data.post.id};
});
export const blogTaxonomy=createServerFn({method:'POST'}).inputValidator(z.object({token:z.string().min(20),kind:z.enum(['category','tag']),name:z.string().trim().min(1).max(100)})).handler(async({data})=>{
 const {authenticatedClient,dbError}=await import('./external-auth.server');const {client}=await authenticatedClient(data.token,true);
 const r=await client.from(data.kind==='category'?'blog_categories':'blog_tags').insert({name:data.name}).select('id,name').single();dbError(r.error);return r.data;
});
export const deleteBlogPost=createServerFn({method:'POST'}).inputValidator(z.object({token:z.string().min(20),id:z.string().uuid()})).handler(async({data})=>{
 const {authenticatedClient,dbError}=await import('./external-auth.server');const {client}=await authenticatedClient(data.token,true);
 const r=await client.from('blog_posts').delete().eq('id',data.id);dbError(r.error);return {ok:true};
});
export const uploadBlogImage=createServerFn({method:'POST'}).inputValidator((data:FormData)=>{if(!(data instanceof FormData))throw new Error('Invalid upload.');return data;}).handler(async({data})=>{
 const {authenticatedClient,dbError}=await import('./external-auth.server');const {client}=await authenticatedClient(String(data.get('token')||''),true);const id=z.string().uuid().parse(data.get('id'));const file=data.get('file');
 if(!(file instanceof File)||file.size>5242880)throw new Error('Choose an image up to 5 MB.');validateImageBytes(new Uint8Array(await file.arrayBuffer()),file.type);
 const path=`${id}/${crypto.randomUUID()}.${imageExtension(file.type)}`;const r=await client.storage.from('blog-images').upload(path,file,{upsert:false,contentType:file.type});if(r.error)throw new Error('Image upload unavailable. Check the approved private storage setup.');
 const saved=await client.from('blog_posts').update({featured_image_path:path}).eq('id',id).select('id').single();dbError(saved.error);return {path};
});
export const adminBlogImage=createServerFn({method:'POST'}).inputValidator(z.object({token:z.string().min(20),id:z.string().uuid()})).handler(async({data})=>{
 const {authenticatedClient,dbError}=await import('./external-auth.server');const {client}=await authenticatedClient(data.token,true);const p=await client.from('blog_posts').select('featured_image_path').eq('id',data.id).single();dbError(p.error);if(!p.data?.featured_image_path)return null;const r=await client.storage.from('blog-images').createSignedUrl(p.data.featured_image_path,60);if(r.error)throw new Error('Image unavailable.');return r.data?.signedUrl||null;
});
