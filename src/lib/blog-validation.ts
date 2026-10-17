import { z } from 'zod';
export function safeBlogUrl(value:string){if(!/^https?:\/\//.test(value)||/[\x00-\x20\x7f]/.test(value))return false;try{const u=new URL(value);return ['http:','https:'].includes(u.protocol)&&!u.username&&!u.password;}catch{return false;}}
export type BlogNode={type:string;text?:string;attrs?:{href?:string;level?:number};marks?:{type:'bold'|'italic'|'link';attrs?:{href:string}}[];content?:BlogNode[]};
export function validateBlogDocument(value:unknown):BlogNode {
 const serialized=JSON.stringify(value);if(!serialized||new TextEncoder().encode(serialized).length>100000)throw new Error('Article is too large.');let count=0;
 function check(v:unknown,depth:number,parent?:string):BlogNode {
  if(depth>12||++count>2000||!v||typeof v!=='object'||Array.isArray(v))throw new Error('Invalid article structure.');
  const n=v as BlogNode; const keys=Object.keys(n);if(keys.some(k=>!['type','text','attrs','marks','content'].includes(k)))throw new Error('Unsupported article attribute.');
  const types=['doc','paragraph','heading','text','bulletList','orderedList','listItem','hardBreak'];if(!types.includes(n.type)||n.type==='doc'&&depth!==0)throw new Error('Unsupported article content.');
  if(depth===0&&n.type!=='doc')throw new Error('Article must be a document.');
  if(n.type==='text'){if(typeof n.text!=='string'||n.text.length>10000||n.content||n.attrs||!['paragraph','heading'].includes(parent||''))throw new Error('Invalid article text.');}
  else if(n.text!==undefined||n.marks!==undefined)throw new Error('Invalid article attributes.');
  if(n.attrs){if(n.type!=='heading'||Object.keys(n.attrs).some(k=>k!=='level')||![2,3].includes(n.attrs.level||0))throw new Error('Unsupported heading.');}
  if(n.type==='heading'&&!n.attrs)throw new Error('Heading level required.');
  if(n.marks){if(!Array.isArray(n.marks)||n.marks.length>3)throw new Error('Invalid text formatting.');for(const m of n.marks){if(!m||Object.keys(m).some(k=>!['type','attrs'].includes(k))||!['bold','italic','link'].includes(m.type))throw new Error('Unsupported text formatting.');if(m.type==='link'){if(!m.attrs||Object.keys(m.attrs).some(k=>k!=='href')||typeof m.attrs.href!=='string'||m.attrs.href.length>2048||!safeBlogUrl(m.attrs.href))throw new Error('Invalid link.');}else if(m.attrs)throw new Error('Unsupported text attributes.');}}
  if(n.type==='hardBreak'&&(n.content||n.attrs||!['paragraph','heading'].includes(parent||'')))throw new Error('Invalid line break.');
  if(!['text','hardBreak'].includes(n.type)){
    if(!Array.isArray(n.content))throw new Error('Article content required.');
    const allowed=n.type==='doc'||n.type==='listItem'?['paragraph','heading','bulletList','orderedList']:n.type==='bulletList'||n.type==='orderedList'?['listItem']:['text','hardBreak'];
    for(const child of n.content){if(!child||!allowed.includes(child.type))throw new Error('Invalid nested content.');check(child,depth+1,n.type);}
  }
  return n;
 }
 return check(value,0);
}
export const postSchema=z.object({id:z.string().uuid(),title:z.string().trim().min(1).max(200),slug:z.string().min(1).max(160).regex(/^[a-z0-9]+(?:-[a-z0-9]+)*$/),excerpt:z.string().max(500),content:z.unknown().transform(validateBlogDocument),status:z.enum(['draft','published']),category_id:z.string().uuid().nullable(),tags:z.array(z.string().uuid()).max(20),image_alt:z.string().max(200),seo_title:z.string().max(200),seo_description:z.string().max(500)});
export const EMPTY_DOCUMENT:BlogNode={type:'doc',content:[{type:'paragraph',content:[]}]};
export type BlogPost={id:string;title:string;slug:string;excerpt:string;content:BlogNode;status:'draft'|'published';category_id:string|null;featured_image_path:string|null;image_alt:string;seo_title:string;seo_description:string;published_at:string|null;updated_at:string};
export const SITE_URL='https://entryshippr-cloud.lovable.app';
export function blogImageUrl(post:Pick<BlogPost,'id'|'featured_image_path'>){return post.featured_image_path?`${SITE_URL}/api/public/blog-images/${post.id}`:undefined;}
