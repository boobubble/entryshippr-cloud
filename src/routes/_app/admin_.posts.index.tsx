import { createFileRoute,Link } from '@tanstack/react-router';
import { useState } from 'react';
import { useQuery,useQueryClient } from '@tanstack/react-query';
import { useServerFn } from '@tanstack/react-start';
import { toast } from 'sonner';
import { useProfile,errMsg } from '@/lib/hooks';
import { accessToken } from '@/lib/supabase';
import { getBlogAdmin,deleteBlogPost,blogTaxonomy } from '@/lib/blog.functions';
import { PageHead,appHead } from '@/components/PageHead';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
export const Route=createFileRoute('/_app/admin_/posts/')({head:()=>({...appHead('Blog CMS','Manage EntrySetu articles, categories and tags.')(),meta:[...appHead('Blog CMS','Manage EntrySetu articles, categories and tags.')().meta,{name:'robots',content:'noindex,nofollow'}]}),component:Posts});
function Posts(){const {data:me}=useProfile();const [page,setPage]=useState(0);const [category,setCategory]=useState('');const [tag,setTag]=useState('');const [busy,setBusy]=useState(false);const qc=useQueryClient();const get=useServerFn(getBlogAdmin);const remove=useServerFn(deleteBlogPost);const taxonomy=useServerFn(blogTaxonomy);
 const data=useQuery({queryKey:['blog-admin',page],enabled:!!me?.isAdmin,retry:false,queryFn:async()=>get({data:{token:await accessToken(),page}})});
 async function del(id:string){if(!window.confirm('Delete this article?')||busy)return;setBusy(true);try{await remove({data:{token:await accessToken(),id}});await qc.invalidateQueries({queryKey:['blog-admin']});toast.success('Article deleted.');}catch(e){toast.error(errMsg(e));}finally{setBusy(false);}}
 async function add(kind:'category'|'tag'){if(busy)return;setBusy(true);try{await taxonomy({data:{token:await accessToken(),kind,name:kind==='category'?category:tag}});kind==='category'?setCategory(''):setTag('');await qc.invalidateQueries({queryKey:['blog-admin']});}catch(e){toast.error(errMsg(e));}finally{setBusy(false);}}
 if(!me)return <p>Loading…</p>;if(!me.isAdmin)return <p>Admins only.</p>;
 return <><PageHead title="Blog CMS"><Button asChild><Link to="/admin/posts/$id" params={{id:'new'}}>New article</Link></Button></PageHead>{data.error&&<p role="alert" className="text-destructive">{errMsg(data.error)}</p>}
 <div className="overflow-x-auto"><table className="w-full text-sm"><thead className="bg-muted text-left"><tr><th className="p-3">Title</th><th className="p-3">Status</th><th className="p-3">Updated</th><th/></tr></thead><tbody>{data.data?.posts.map(p=><tr className="border-b" key={p.id}><td className="p-3"><Link to="/admin/posts/$id" params={{id:p.id}} className="text-primary">{p.title}</Link></td><td className="p-3 capitalize">{p.status}</td><td className="p-3">{new Date(p.updated_at).toLocaleDateString('en-IN')}</td><td className="p-3 text-right"><Button size="sm" variant="ghost" disabled={busy} onClick={()=>del(p.id)}>Delete</Button></td></tr>)}</tbody></table>{data.data?.count===0&&<p className="p-4 text-muted-foreground">No articles yet.</p>}</div><div className="my-4 flex justify-end gap-3"><Button size="sm" variant="outline" disabled={!page} onClick={()=>setPage(p=>p-1)}>Previous</Button><span>Page {page+1}</span><Button size="sm" variant="outline" disabled={!data.data||(page+1)*20>=data.data.count} onClick={()=>setPage(p=>p+1)}>Next</Button></div>
 <section className="mt-8 grid gap-6 border-t pt-6 md:grid-cols-2"><div><h2 className="mb-3 font-semibold">Categories</h2><div className="flex gap-2"><Input aria-label="New category" maxLength={100} value={category} onChange={e=>setCategory(e.target.value)}/><Button disabled={busy||!category.trim()} onClick={()=>add('category')}>Add</Button></div><p className="mt-3 text-sm text-muted-foreground">{data.data?.categories.map(c=>c.name).join(', ')}</p></div><div><h2 className="mb-3 font-semibold">Tags</h2><div className="flex gap-2"><Input aria-label="New tag" maxLength={100} value={tag} onChange={e=>setTag(e.target.value)}/><Button disabled={busy||!tag.trim()} onClick={()=>add('tag')}>Add</Button></div><p className="mt-3 text-sm text-muted-foreground">{data.data?.tags.map(t=>t.name).join(', ')}</p></div></section></>;
}
