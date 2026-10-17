import type { ReactNode } from 'react';
import { validateBlogDocument,type BlogNode } from '@/lib/blog-validation';
export function BlogContent({content}:{content:unknown}){
 let doc:BlogNode;try{doc=validateBlogDocument(content);}catch{return <p role="alert">Article content unavailable.</p>;}
 function render(n:BlogNode,key:number):ReactNode{const children=n.content?.map(render);
  if(n.type==='text'){let value:ReactNode=n.text;for(const [i,m] of (n.marks||[]).entries()){if(m.type==='bold')value=<strong key={i}>{value}</strong>;if(m.type==='italic')value=<em key={i}>{value}</em>;if(m.type==='link')value=<a key={i} href={m.attrs?.href} rel="noopener noreferrer" className="text-primary underline">{value}</a>;}return <span key={key}>{value}</span>;}
  if(n.type==='paragraph')return <p key={key} className="my-4 leading-7">{children}</p>;
  if(n.type==='heading')return n.attrs?.level===2?<h2 key={key} className="mb-3 mt-8 text-2xl font-semibold">{children}</h2>:<h3 key={key} className="mb-3 mt-6 text-xl font-semibold">{children}</h3>;
  if(n.type==='bulletList')return <ul key={key} className="my-4 list-disc pl-6">{children}</ul>;if(n.type==='orderedList')return <ol key={key} className="my-4 list-decimal pl-6">{children}</ol>;if(n.type==='listItem')return <li key={key}>{children}</li>;if(n.type==='hardBreak')return <br key={key}/>;return <div key={key}>{children}</div>;
 }
 return <div className="break-words">{render(doc,0)}</div>;
}
