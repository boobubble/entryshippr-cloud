import { Link } from '@tanstack/react-router';
import { BlogCard } from './BlogCard';
import type { BlogPost } from '@/lib/blog-validation';
export function LatestPosts({posts}:{posts:BlogPost[]}){if(!posts.length)return null;return <section className="mx-auto max-w-6xl px-6 py-14"><div className="mb-6 flex items-center justify-between"><h2 className="text-2xl font-semibold">Latest from EntrySetu</h2><Link to="/blog" search={{page:0}} className="text-sm text-primary underline">All articles</Link></div><div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">{posts.slice(0,4).map(p=><BlogCard key={p.id} post={p}/>)}</div></section>;}
