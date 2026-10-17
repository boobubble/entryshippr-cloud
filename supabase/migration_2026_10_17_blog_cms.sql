-- REVIEW ONLY: external DEV zfvnqcyqxxipjaugkmvf, never production.
-- Apply after payment/admin proposal. Buckets are separately provisioned via Storage API.
BEGIN;
CREATE FUNCTION entrysetu_private.blog_node_valid(n jsonb,depth integer DEFAULT 0,parent text DEFAULT NULL) RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
DECLARE typ text; k text; child jsonb; mark jsonb; allowed text[];
BEGIN
 IF depth>12 OR jsonb_typeof(n) IS DISTINCT FROM 'object' THEN RETURN false; END IF;
 FOR k IN SELECT jsonb_object_keys(n) LOOP IF k NOT IN ('type','text','attrs','marks','content') THEN RETURN false; END IF; END LOOP;
 typ:=n->>'type'; IF typ IS NULL OR typ NOT IN ('doc','paragraph','heading','text','bulletList','orderedList','listItem','hardBreak') OR (depth=0 AND typ<>'doc') OR (depth>0 AND typ='doc') THEN RETURN false; END IF;
 IF typ='text' THEN
  IF jsonb_typeof(n->'text') IS DISTINCT FROM 'string' OR length(n->>'text')>10000 OR n ? 'content' OR n ? 'attrs' OR parent NOT IN ('paragraph','heading') THEN RETURN false; END IF;
 ELSE IF n ? 'text' OR n ? 'marks' THEN RETURN false; END IF; END IF;
 IF n ? 'attrs' THEN
  IF typ<>'heading' OR jsonb_typeof(n->'attrs') IS DISTINCT FROM 'object' OR jsonb_typeof(n->'attrs'->'level') IS DISTINCT FROM 'number' OR coalesce(n->'attrs'->>'level','') NOT IN ('2','3') OR NOT (n->'attrs' ? 'level') THEN RETURN false; END IF;
  FOR k IN SELECT jsonb_object_keys(n->'attrs') LOOP IF k<>'level' THEN RETURN false; END IF; END LOOP;
 END IF;
 IF typ='heading' AND NOT(n ? 'attrs') THEN RETURN false; END IF;
 IF n ? 'marks' THEN
  IF jsonb_typeof(n->'marks') IS DISTINCT FROM 'array' OR jsonb_array_length(n->'marks')>3 THEN RETURN false; END IF;
  FOR mark IN SELECT value FROM jsonb_array_elements(n->'marks') LOOP
   IF jsonb_typeof(mark)<>'object' OR coalesce(mark->>'type','') NOT IN ('bold','italic','link') THEN RETURN false; END IF;
   FOR k IN SELECT jsonb_object_keys(mark) LOOP IF k NOT IN ('type','attrs') THEN RETURN false; END IF; END LOOP;
   IF mark->>'type'='link' THEN
    IF jsonb_typeof(mark->'attrs') IS DISTINCT FROM 'object' OR jsonb_typeof(mark->'attrs'->'href') IS DISTINCT FROM 'string' OR length(mark->'attrs'->>'href')>2048 OR (mark->'attrs'->>'href') !~ '^https?://[^[:space:]@/]+([/:?#]|$)' OR (mark->'attrs'->>'href') ~ '[[:cntrl:]]' THEN RETURN false; END IF;
    FOR k IN SELECT jsonb_object_keys(mark->'attrs') LOOP IF k<>'href' THEN RETURN false; END IF; END LOOP;
   ELSIF mark ? 'attrs' THEN RETURN false; END IF;
  END LOOP;
 END IF;
 IF typ='hardBreak' THEN RETURN NOT(n ? 'content') AND NOT(n ? 'attrs') AND parent IN ('paragraph','heading'); END IF;
 IF typ='text' THEN RETURN true; END IF;
 IF jsonb_typeof(n->'content') IS DISTINCT FROM 'array' THEN RETURN false; END IF;
 allowed:=CASE WHEN typ IN ('doc','listItem') THEN ARRAY['paragraph','heading','bulletList','orderedList'] WHEN typ IN ('bulletList','orderedList') THEN ARRAY['listItem'] ELSE ARRAY['text','hardBreak'] END;
 FOR child IN SELECT value FROM jsonb_array_elements(n->'content') LOOP
  IF NOT(coalesce(child->>'type','')=ANY(allowed)) OR NOT entrysetu_private.blog_node_valid(child,depth+1,typ) THEN RETURN false; END IF;
 END LOOP;
 RETURN true;
EXCEPTION WHEN OTHERS THEN RETURN false;
END $$;
CREATE FUNCTION public.blog_document_valid(n jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE SECURITY DEFINER SET search_path='' AS $$ SELECT n IS NOT NULL AND octet_length(n::text)<=100000 AND jsonb_array_length(jsonb_path_query_array(n,'strict $.** ? (@.type != null)'))<=2000 AND entrysetu_private.blog_node_valid(n) $$;
REVOKE ALL ON FUNCTION public.blog_document_valid(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.blog_document_valid(jsonb) TO anon,authenticated,service_role;
CREATE TABLE public.blog_categories(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),name text NOT NULL UNIQUE CHECK(length(btrim(name)) BETWEEN 1 AND 100));
GRANT SELECT ON public.blog_categories TO anon;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.blog_categories TO authenticated;
GRANT ALL ON public.blog_categories TO service_role;
ALTER TABLE public.blog_categories ENABLE ROW LEVEL SECURITY;
CREATE TABLE public.blog_tags(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),name text NOT NULL UNIQUE CHECK(length(btrim(name)) BETWEEN 1 AND 100));
GRANT SELECT ON public.blog_tags TO anon;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.blog_tags TO authenticated;
GRANT ALL ON public.blog_tags TO service_role;
ALTER TABLE public.blog_tags ENABLE ROW LEVEL SECURITY;
CREATE TABLE public.blog_posts(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),author_id uuid NOT NULL REFERENCES auth.users(id),
 title text NOT NULL CHECK(length(btrim(title)) BETWEEN 1 AND 200),slug text NOT NULL UNIQUE CHECK(length(slug) BETWEEN 1 AND 160 AND slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
 excerpt text NOT NULL DEFAULT '' CHECK(length(excerpt)<=500),content jsonb NOT NULL CHECK(public.blog_document_valid(content)),
 status text NOT NULL DEFAULT 'draft' CHECK(status IN ('draft','published')),
 category_id uuid REFERENCES public.blog_categories(id) ON DELETE SET NULL,
 featured_image_path text UNIQUE,image_alt text NOT NULL DEFAULT '' CHECK(length(image_alt)<=200),
 seo_title text NOT NULL DEFAULT '' CHECK(length(seo_title)<=200),seo_description text NOT NULL DEFAULT '' CHECK(length(seo_description)<=500),
 published_at timestamptz,created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK(status<>'published' OR published_at IS NOT NULL),
 CHECK(featured_image_path IS NULL OR featured_image_path ~ ('^'||id::text||'/[0-9a-f-]{36}\.(png|jpg|webp)$'))
);
GRANT SELECT ON public.blog_posts TO anon;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.blog_posts TO authenticated;
GRANT ALL ON public.blog_posts TO service_role;
ALTER TABLE public.blog_posts ENABLE ROW LEVEL SECURITY;
CREATE POLICY blog_posts_public ON public.blog_posts FOR SELECT TO anon,authenticated USING(status='published');
CREATE POLICY blog_posts_admin ON public.blog_posts FOR ALL TO authenticated USING(public.is_admin()) WITH CHECK(public.is_admin());
CREATE INDEX blog_posts_published ON public.blog_posts(published_at DESC,id) WHERE status='published';
CREATE TABLE public.blog_post_tags(post_id uuid NOT NULL REFERENCES public.blog_posts(id) ON DELETE CASCADE,tag_id uuid NOT NULL REFERENCES public.blog_tags(id) ON DELETE CASCADE,PRIMARY KEY(post_id,tag_id));
GRANT SELECT ON public.blog_post_tags TO anon;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.blog_post_tags TO authenticated;
GRANT ALL ON public.blog_post_tags TO service_role;
ALTER TABLE public.blog_post_tags ENABLE ROW LEVEL SECURITY;
CREATE POLICY blog_post_tags_public ON public.blog_post_tags FOR SELECT TO anon,authenticated USING(EXISTS(SELECT 1 FROM public.blog_posts p WHERE p.id=post_id AND p.status='published'));
CREATE POLICY blog_post_tags_admin ON public.blog_post_tags FOR ALL TO authenticated USING(public.is_admin()) WITH CHECK(public.is_admin());
CREATE POLICY blog_categories_public ON public.blog_categories FOR SELECT TO anon,authenticated USING(EXISTS(SELECT 1 FROM public.blog_posts p WHERE p.category_id=blog_categories.id AND p.status='published'));
CREATE POLICY blog_categories_admin ON public.blog_categories FOR ALL TO authenticated USING(public.is_admin()) WITH CHECK(public.is_admin());
CREATE POLICY blog_tags_public ON public.blog_tags FOR SELECT TO anon,authenticated USING(EXISTS(SELECT 1 FROM public.blog_post_tags pt JOIN public.blog_posts p ON p.id=pt.post_id WHERE pt.tag_id=blog_tags.id AND p.status='published'));
CREATE POLICY blog_tags_admin ON public.blog_tags FOR ALL TO authenticated USING(public.is_admin()) WITH CHECK(public.is_admin());
CREATE FUNCTION entrysetu_private.blog_stamp() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$ BEGIN
 NEW.updated_at:=now();
 IF NEW.status='published' AND (TG_OP='INSERT' OR OLD.status<>'published') THEN NEW.published_at:=now(); END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER blog_stamp BEFORE INSERT OR UPDATE ON public.blog_posts FOR EACH ROW EXECUTE FUNCTION entrysetu_private.blog_stamp();
CREATE FUNCTION public.save_blog_post(p_post jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE pid uuid; tag jsonb;
BEGIN
 IF auth.role() IS DISTINCT FROM 'authenticated' OR public.is_admin() IS DISTINCT FROM true THEN RAISE EXCEPTION 'Admins only' USING ERRCODE='42501'; END IF;
 pid:=(p_post->>'id')::uuid;
 IF jsonb_typeof(p_post->'tags') IS DISTINCT FROM 'array' OR jsonb_array_length(p_post->'tags')>20 THEN RAISE EXCEPTION 'Invalid tags'; END IF;
 INSERT INTO public.blog_posts(id,author_id,title,slug,excerpt,content,status,category_id,image_alt,seo_title,seo_description)
 VALUES(pid,auth.uid(),p_post->>'title',p_post->>'slug',p_post->>'excerpt',p_post->'content',p_post->>'status',(p_post->>'category_id')::uuid,p_post->>'image_alt',p_post->>'seo_title',p_post->>'seo_description')
 ON CONFLICT(id) DO UPDATE SET title=EXCLUDED.title,slug=EXCLUDED.slug,excerpt=EXCLUDED.excerpt,content=EXCLUDED.content,status=EXCLUDED.status,category_id=EXCLUDED.category_id,image_alt=EXCLUDED.image_alt,seo_title=EXCLUDED.seo_title,seo_description=EXCLUDED.seo_description;
 DELETE FROM public.blog_post_tags WHERE post_id=pid;
 FOR tag IN SELECT value FROM jsonb_array_elements(p_post->'tags') LOOP INSERT INTO public.blog_post_tags(post_id,tag_id) VALUES(pid,(tag#>>'{}')::uuid) ON CONFLICT DO NOTHING; END LOOP;
 RETURN pid;
END $$;
REVOKE ALL ON FUNCTION public.save_blog_post(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_blog_post(jsonb) TO authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA entrysetu_private FROM PUBLIC,anon,authenticated;
CREATE POLICY blog_images_admin_read ON storage.objects FOR SELECT TO authenticated USING(bucket_id='blog-images' AND public.is_admin());
CREATE POLICY blog_images_admin_insert ON storage.objects FOR INSERT TO authenticated WITH CHECK(bucket_id='blog-images' AND public.is_admin() AND name ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.(png|jpg|webp)$' AND EXISTS(SELECT 1 FROM public.blog_posts p WHERE p.id::text=split_part(name,'/',1)));
-- No anonymous Storage policy. Public image endpoint rechecks current publication on every request.
-- No UPDATE/DELETE policies; replacement images get new paths. Cleanup needs separate retention approval.
COMMIT;
