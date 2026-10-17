import { createFileRoute,Link,useNavigate } from '@tanstack/react-router';
import { useEffect,useState } from 'react';
import { useQuery,useQueryClient } from '@tanstack/react-query';
import { useServerFn } from '@tanstack/react-start';
import { toast } from 'sonner';
import { useProfile,errMsg } from '@/lib/hooks';
import { accessToken } from '@/lib/supabase';
import { getAdminPost,getBlogAdmin,saveBlogPost,uploadBlogImage,adminBlogImage } from '@/lib/blog.functions';
import { EMPTY_DOCUMENT,type BlogNode,type BlogPost } from '@/lib/blog-validation';
import { BlogEditor } from '@/components/blog/BlogEditor';
import { BlogContent } from '@/components/blog/BlogContent';
import { PageHead,appHead } from '@/components/PageHead';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';
import { Checkbox } from '@/components/ui/checkbox';
import { Select,SelectContent,SelectItem,SelectTrigger,SelectValue } from '@/components/ui/select';
export const Route=createFileRoute('/_app/admin_/posts/$id')({head:()=>({...appHead('Article editor','Edit EntrySetu articles and publication details.')(),meta:[...appHead('Article editor','Edit EntrySetu articles and publication details.')().meta,{name:'robots',content:'noindex,nofollow'}]}),component:Editor});
function Editor(){const {id}=Route.useParams();const {data:me}=useProfile();const get=useServerFn(getAdminPost);const meta=useServerFn(getBlogAdmin);const save=useServerFn(saveBlogPost);const upload=useServerFn(uploadBlogImage);const image=useServerFn(adminBlogImage);const qc=useQueryClient();const navigate=useNavigate();
 const [draft,setDraft]=useState<{id:string;title:string;slug:string;excerpt:string;content:BlogNode;status:'draft'|'published';category_id:string|null;tags:string[];image_alt:string;seo_title:string;seo_description:string}|null>(null);const [busy,setBusy]=useState(false);const [preview,setPreview]=useState(false);const [imageUrl,setImageUrl]=useState<string|null>(null);
 const data=useQuery({queryKey:['blog-edit',id],enabled:!!me?.isAdmin&&id!=='new',retry:false,queryFn:async()=>get({data:{token:await accessToken(),id}})});const tax=useQuery({queryKey:['blog-admin',0],enabled:!!me?.isAdmin,retry:false,queryFn:async()=>meta({data:{token:await accessToken(),page:0}})});
 useEffect(()=>{setDraft(null);setImageUrl(null);if(id==='new')setDraft({id:crypto.randomUUID(),title:'',slug:'',excerpt:'',content:EMPTY_DOCUMENT,status:'draft',category_id:null,tags:[],image_alt:'',seo_title:'',seo_description:''});},[id]);
 useEffect(()=>{if(data.data?.post){const p=data.data.post;setDraft({id:p.id,title:p.title,slug:p.slug,excerpt:p.excerpt,content:p.content,status:p.status,category_id:p.category_id,tags:data.data.tags,image_alt:p.image_alt,seo_title:p.seo_title,seo_description:p.seo_description});}},[data.data]);
 useEffect(()=>{let live=true;if(data.data?.post?.featured_image_path)accessToken().then(token=>image({data:{token,id}})).then(url=>{if(live)setImageUrl(url);}).catch(()=>{});return()=>{live=false;};},[data.data,id,image]);
 async function persist(e:React.FormEvent){e.preventDefault();if(!draft||busy)return;setBusy(true);try{const r=await save({data:{token:await accessToken(),post:draft}});toast.success(draft.status==='published'?'Article published.':'Draft saved.');await qc.invalidateQueries({queryKey:['blog-admin']});if(id==='new')navigate({to:'/admin/posts/$id',params:{id:r.id}});}catch(e){toast.error(errMsg(e));}finally{setBusy(false);}}
 async function fileChange(file:File|undefined){if(!file||id==='new'||busy)return;setBusy(true);try{const d=new FormData();d.set('token',await accessToken());d.set('id',id);d.set('file',file);await upload({data:d});setImageUrl(await image({data:{token:await accessToken(),id}}));toast.success('Featured image saved.');}catch(e){toast.error(errMsg(e));}finally{setBusy(false);}}
 if(!me)return <p>Loading…</p>;if(!me.isAdmin)return <p>Admins only.</p>;if(data.error||tax.error)return <p role="alert" className="text-destructive">{errMsg(data.error||tax.error)}</p>;if(id!=='new'&&data.data&&!data.data.post)return <p>Article not found.</p>;if(!draft)return <p>Loading article…</p>;
 const field=(key:'title'|'slug'|'excerpt'|'image_alt'|'seo_title'|'seo_description',value:string)=>setDraft(d=>d?{...d,[key]:value}:d);
 return <><PageHead title={id==='new'?'New article':'Edit article'}><Button variant="outline" onClick={()=>setPreview(p=>!p)}>{preview?'Edit':'Preview'}</Button><Button variant="ghost" asChild><Link to="/admin/posts">All articles</Link></Button></PageHead><form onSubmit={persist} className="space-y-5"><fieldset disabled={busy} className="space-y-5">
 <div className="grid gap-4 md:grid-cols-2"><div><Label htmlFor="post-title">Title</Label><Input id="post-title" value={draft.title} maxLength={200} required onChange={e=>field('title',e.target.value)}/></div><div><Label htmlFor="post-slug">Slug</Label><Input id="post-slug" value={draft.slug} maxLength={160} required pattern="[a-z0-9]+(-[a-z0-9]+)*" onChange={e=>field('slug',e.target.value)}/></div></div>
 <div><Label htmlFor="post-excerpt">Excerpt</Label><Textarea id="post-excerpt" value={draft.excerpt} maxLength={500} onChange={e=>field('excerpt',e.target.value)}/></div>
 {preview?<article><h1 className="text-3xl font-bold">{draft.title}</h1>{imageUrl&&<img src={imageUrl} alt={draft.image_alt} className="my-5 aspect-video w-full object-cover"/>}<BlogContent content={draft.content}/></article>:<BlogEditor key={draft.id} content={draft.content} onChange={content=>setDraft(d=>d?{...d,content}:d)}/>}
 <div className="grid gap-4 md:grid-cols-2"><div><Label>Status</Label><Select value={draft.status} onValueChange={status=>setDraft(d=>d?{...d,status:status as BlogPost['status']}:d)}><SelectTrigger><SelectValue/></SelectTrigger><SelectContent><SelectItem value="draft">Draft</SelectItem><SelectItem value="published">Published</SelectItem></SelectContent></Select></div><div><Label>Category</Label><Select value={draft.category_id||'none'} onValueChange={v=>setDraft(d=>d?{...d,category_id:v==='none'?null:v}:d)}><SelectTrigger><SelectValue/></SelectTrigger><SelectContent><SelectItem value="none">None</SelectItem>{tax.data?.categories.map(c=><SelectItem key={c.id} value={c.id}>{c.name}</SelectItem>)}</SelectContent></Select></div></div>
 <div><Label>Tags</Label><div className="mt-2 flex flex-wrap gap-4">{tax.data?.tags.map(t=><label key={t.id} className="flex items-center gap-2 text-sm"><Checkbox checked={draft.tags.includes(t.id)} onCheckedChange={on=>setDraft(d=>d?{...d,tags:on?[...d.tags,t.id]:d.tags.filter(v=>v!==t.id)}:d)}/>{t.name}</label>)}</div></div>
 <div><Label htmlFor="post-image">Featured image · PNG/JPG/WebP · up to 5 MB</Label><Input id="post-image" type="file" accept="image/png,image/jpeg,image/webp" disabled={busy||id==='new'} onChange={e=>fileChange(e.target.files?.[0])}/>{id==='new'&&<p className="mt-1 text-sm text-muted-foreground">Save the draft before adding an image.</p>}{imageUrl&&!preview&&<img src={imageUrl} alt={draft.image_alt} className="mt-3 max-h-48 rounded-md"/>}</div>
 <div><Label htmlFor="post-alt">Image alt text</Label><Input id="post-alt" value={draft.image_alt} maxLength={200} onChange={e=>field('image_alt',e.target.value)}/></div>
 <div><Label htmlFor="post-seo-title">SEO title</Label><Input id="post-seo-title" value={draft.seo_title} maxLength={200} onChange={e=>field('seo_title',e.target.value)}/></div><div><Label htmlFor="post-description">Meta description</Label><Textarea id="post-description" value={draft.seo_description} maxLength={500} onChange={e=>field('seo_description',e.target.value)}/></div>
 <Button type="submit" disabled={busy}>{busy?'Saving…':draft.status==='published'?'Save and publish':'Save draft'}</Button></fieldset></form></>;
}
