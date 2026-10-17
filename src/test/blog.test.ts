import { describe,it,expect } from 'vitest';
import { EMPTY_DOCUMENT,safeBlogUrl,validateBlogDocument,postSchema } from '@/lib/blog-validation';
describe('Blog safety',()=>{
 it('accepts empty draft',()=>expect(validateBlogDocument(EMPTY_DOCUMENT)).toEqual(EMPTY_DOCUMENT));
 it.each(['javascript:alert(1)','data:text/html,evil','https://user:pass@example.com','//evil.test',' https://example.com','https://example.com\n'])('rejects unsafe URL %s',v=>expect(safeBlogUrl(v)).toBe(false));
 it('accepts https links',()=>expect(safeBlogUrl('https://example.com/article?a=1')).toBe(true));
 it.each(['script','iframe','image','codeBlock'])('rejects %s nodes',type=>expect(()=>validateBlogDocument({type:'doc',content:[{type,content:[]}]})).toThrow());
 it('rejects event attributes',()=>expect(()=>validateBlogDocument({type:'doc',content:[],onclick:'evil'})).toThrow());
 it('rejects unsafe link marks',()=>expect(()=>validateBlogDocument({type:'doc',content:[{type:'paragraph',content:[{type:'text',text:'x',marks:[{type:'link',attrs:{href:'javascript:evil'}}]}]}]})).toThrow());
 it('rejects wrong nesting',()=>expect(()=>validateBlogDocument({type:'doc',content:[{type:'text',text:'x'}]})).toThrow());
 it('rejects over 2000 nodes',()=>expect(()=>validateBlogDocument({type:'doc',content:Array.from({length:2000},()=>({type:'paragraph',content:[]}))})).toThrow());
 it('rejects oversized documents',()=>expect(()=>validateBlogDocument({type:'doc',content:[{type:'paragraph',content:[{type:'text',text:'a'.repeat(100001)}]}]})).toThrow());
 it('rejects malformed missing content',()=>expect(()=>validateBlogDocument({type:'doc',content:null})).toThrow());
 it('requires a safe slug at save',()=>expect(()=>postSchema.parse({id:'b7100000-0000-4000-8000-000000000001',title:'Test',slug:'../evil',excerpt:'',content:EMPTY_DOCUMENT,status:'draft',category_id:null,tags:[],image_alt:'',seo_title:'',seo_description:''})).toThrow());
});
