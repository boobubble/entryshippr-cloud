import { createFileRoute,Link } from '@tanstack/react-router';
import { queryOptions,useSuspenseQuery } from '@tanstack/react-query';
import { listPublishedPosts } from '@/lib/blog.functions';
import { BlogCard } from '@/components/blog/BlogCard';
import { appHead } from '@/components/PageHead';
import { SITE_URL } from '@/lib/blog-validation';
import { Button } from '@/components/ui/button';
const posts=(page:number)=>queryOptions({queryKey:['public-blog',page],queryFn:()=>listPublishedPosts({data:{page,limit:12}})});
export const Route=createFileRoute('/blog/')({validateSearch:(s:Record<string,unknown>)=>({page:Math.max(0,Math.min(10000,Number(s['page'])||0))}),loaderDeps:({search})=>({page:search.page}),loader:({context,deps})=>context.queryClient.ensureQueryData(posts(deps.page)),head:()=>({...appHead('Blog','Courier business articles from EntrySetu.')(),links:[{rel:'canonical',href:`${SITE_URL}/blog`}]}),component:BlogList});
function BlogList(){const {page}=Route.useSearch();const {data}=useSuspenseQuery(posts(page));return <main className="mx-auto min-h-screen max-w-6xl px-6 py-8"><Link to="/" className="text-xl font-bold text-primary">EntrySetu</Link><h1 className="mb-8 mt-10 text-3xl font-bold">EntrySetu Blog</h1>{data.unavailable?<p role="alert">Articles are currently unavailable.</p>:!data.count?<p className="text-muted-foreground">No articles published yet.</p>:<><div className="grid gap-5 sm:grid-cols-2 lg:grid-cols-3">{data.posts.map(p=><BlogCard key={p.id} post={p}/>)}</div><div className="mt-8 flex justify-end gap-3"><Button variant="outline" disabled={page===0} asChild><Link to="/blog" search={{page:Math.max(0,page-1)}}>Previous</Link></Button><Button variant="outline" disabled={(page+1)*12>=data.count} asChild><Link to="/blog" search={{page:page+1}}>Next</Link></Button></div></>}</main>;}
