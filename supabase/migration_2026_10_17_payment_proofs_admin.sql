-- REVIEW ONLY. External DEV zfvnqcyqxxipjaugkmvf only. NEVER run on production.
-- Requires existing EntrySetu schema + permission hardening. No bucket provisioning.
-- Transactional, single application: re-running fails safely without partial changes.
BEGIN;
CREATE SCHEMA IF NOT EXISTS entrysetu_private;
REVOKE ALL ON SCHEMA entrysetu_private FROM PUBLIC, anon, authenticated;
ALTER TABLE public.payments ADD COLUMN channel text NOT NULL DEFAULT 'razorpay';
ALTER TABLE public.payments ALTER COLUMN razorpay_order_id DROP NOT NULL;
ALTER TABLE public.payments ADD CONSTRAINT payments_channel_chk CHECK (
 (channel = 'razorpay' AND razorpay_order_id IS NOT NULL AND length(razorpay_order_id)>0)
 OR (channel = 'manual' AND razorpay_order_id IS NULL AND razorpay_payment_id IS NULL));
ALTER TABLE public.payments ADD CONSTRAINT payments_id_owner_unique UNIQUE(id,owner_id);
CREATE TABLE public.payment_submissions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), payment_id uuid NOT NULL UNIQUE, owner_id uuid NOT NULL,
 request_id uuid NOT NULL, reference text NOT NULL CHECK(length(btrim(reference)) BETWEEN 3 AND 100 AND reference !~ '[[:cntrl:]]'),
 proof_path text NOT NULL UNIQUE, mime text NOT NULL CHECK(mime IN ('image/png','image/jpeg','image/webp')),
 byte_size bigint NOT NULL CHECK(byte_size BETWEEN 12 AND 5242880),
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','approved','rejected')),
 submitted_at timestamptz, reviewed_at timestamptz, reviewer_id uuid, reason text,
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(owner_id,request_id), FOREIGN KEY(payment_id,owner_id) REFERENCES public.payments(id,owner_id),
 CHECK(proof_path = owner_id::text || '/' || id::text || CASE mime WHEN 'image/png' THEN '.png' WHEN 'image/jpeg' THEN '.jpg' ELSE '.webp' END),
 CHECK((status='pending' AND reviewed_at IS NULL AND reviewer_id IS NULL AND reason IS NULL)
 OR (status IN ('approved','rejected') AND submitted_at IS NOT NULL AND reviewed_at IS NOT NULL AND reviewer_id IS NOT NULL AND length(btrim(reason)) BETWEEN 3 AND 1000))
);
GRANT SELECT ON public.payment_submissions TO authenticated;
GRANT ALL ON public.payment_submissions TO service_role;
ALTER TABLE public.payment_submissions ENABLE ROW LEVEL SECURITY;
CREATE POLICY payment_submissions_read ON public.payment_submissions FOR SELECT TO authenticated USING(owner_id=auth.uid() OR public.is_admin());
CREATE INDEX payment_submissions_queue ON public.payment_submissions(status,created_at DESC);
CREATE TABLE public.subscription_audit (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), owner_id uuid NOT NULL, actor_id uuid,
 action text NOT NULL, reason text, payment_id uuid, old_access jsonb, new_access jsonb,
 created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.subscription_audit TO authenticated;
GRANT INSERT,SELECT ON public.subscription_audit TO service_role;
ALTER TABLE public.subscription_audit ENABLE ROW LEVEL SECURITY;
CREATE POLICY subscription_audit_admin ON public.subscription_audit FOR SELECT TO authenticated USING(public.is_admin());
CREATE INDEX subscription_audit_owner ON public.subscription_audit(owner_id,created_at DESC);
CREATE FUNCTION entrysetu_private.audit_immutable() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$ BEGIN RAISE EXCEPTION 'Audit history is immutable' USING ERRCODE='42501'; END $$;
CREATE TRIGGER subscription_audit_immutable BEFORE UPDATE OR DELETE ON public.subscription_audit FOR EACH ROW EXECUTE FUNCTION entrysetu_private.audit_immutable();
CREATE TRIGGER subscription_audit_no_truncate BEFORE TRUNCATE ON public.subscription_audit EXECUTE FUNCTION entrysetu_private.audit_immutable();
CREATE FUNCTION entrysetu_private.audit_profile_access() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE before_access jsonb; after_access jsonb;
BEGIN
 IF TG_OP<>'INSERT' THEN before_access:=jsonb_build_object('plan',OLD.plan,'expires_at',OLD.plan_expires_at,'trial_ends_at',OLD.trial_ends_at,'joining_fee_paid',OLD.joining_fee_paid); END IF;
 IF TG_OP<>'DELETE' THEN after_access:=jsonb_build_object('plan',NEW.plan,'expires_at',NEW.plan_expires_at,'trial_ends_at',NEW.trial_ends_at,'joining_fee_paid',NEW.joining_fee_paid); END IF;
 IF before_access IS DISTINCT FROM after_access THEN
  INSERT INTO public.subscription_audit(owner_id,actor_id,action,old_access,new_access) VALUES(CASE WHEN TG_OP='DELETE' THEN OLD.id ELSE NEW.id END,auth.uid(),'profile_'||lower(TG_OP),before_access,after_access);
 END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER profiles_access_audit AFTER INSERT OR UPDATE OR DELETE ON public.profiles FOR EACH ROW EXECUTE FUNCTION entrysetu_private.audit_profile_access();
-- All profile entitlement changes (including legacy service-role RPCs) have a before/after event.
-- Review/action events separately carry the reason/payment; these are intentionally distinct events.
CREATE FUNCTION public.begin_manual_payment(p_plan public.plan_kind,p_reference text,p_mime text,p_size bigint,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid(); profile public.profiles; existing public.payment_submissions; sid uuid:=gen_random_uuid(); pid uuid; path text; amount bigint; fee boolean;
BEGIN
 IF u IS NULL OR auth.role()<>'authenticated' THEN RAISE EXCEPTION 'Sign in required' USING ERRCODE='42501'; END IF;
 IF p_plan IS NULL OR p_request_id IS NULL OR p_reference IS NULL OR length(btrim(p_reference)) NOT BETWEEN 3 AND 100 OR p_reference ~ '[[:cntrl:]]' OR p_mime IS NULL OR p_mime NOT IN ('image/png','image/jpeg','image/webp') OR p_size IS NULL OR p_size NOT BETWEEN 12 AND 5242880 THEN RAISE EXCEPTION 'Invalid submission' USING ERRCODE='23514'; END IF;
 SELECT * INTO profile FROM public.profiles WHERE id=u FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Profile not found'; END IF;
 SELECT * INTO existing FROM public.payment_submissions WHERE owner_id=u AND request_id=p_request_id;
 IF FOUND THEN
  IF existing.status<>'pending' THEN RAISE EXCEPTION 'Submission already reviewed'; END IF;
  IF existing.reference<>btrim(p_reference) OR existing.mime<>p_mime OR existing.byte_size<>p_size OR NOT EXISTS(SELECT 1 FROM public.payments WHERE id=existing.payment_id AND plan=p_plan) THEN RAISE EXCEPTION 'Retry must match original submission'; END IF;
  RETURN jsonb_build_object('id',existing.id,'proof_path',existing.proof_path,'submitted_at',existing.submitted_at);
 END IF;
 fee:=NOT profile.joining_fee_paid;
 amount:=(CASE p_plan WHEN 'standard' THEN 120000 ELSE 180000 END)+CASE WHEN fee THEN 300000 ELSE 0 END;
 INSERT INTO public.payments(owner_id,plan,amount_paise,includes_joining_fee,channel) VALUES(u,p_plan,amount,fee,'manual') RETURNING id INTO pid;
 path:=u::text||'/'||sid::text||CASE p_mime WHEN 'image/png' THEN '.png' WHEN 'image/jpeg' THEN '.jpg' ELSE '.webp' END;
 INSERT INTO public.payment_submissions(id,payment_id,owner_id,request_id,reference,proof_path,mime,byte_size) VALUES(sid,pid,u,p_request_id,btrim(p_reference),path,p_mime,p_size);
 RETURN jsonb_build_object('id',sid,'proof_path',path,'submitted_at',NULL);
END $$;
CREATE FUNCTION public.complete_manual_payment(p_id uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE s public.payment_submissions;
BEGIN
 IF auth.uid() IS NULL OR auth.role()<>'authenticated' THEN RAISE EXCEPTION 'Sign in required' USING ERRCODE='42501'; END IF;
 SELECT * INTO s FROM public.payment_submissions WHERE id=p_id AND owner_id=auth.uid() FOR UPDATE;
 IF NOT FOUND OR s.status<>'pending' THEN RAISE EXCEPTION 'Pending submission not found'; END IF;
 IF s.submitted_at IS NOT NULL THEN RETURN; END IF;
 IF NOT EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='payment-proofs' AND name=s.proof_path AND metadata->>'mimetype'=s.mime AND (metadata->>'size')::bigint=s.byte_size) THEN RAISE EXCEPTION 'Verified screenshot upload is missing'; END IF;
 UPDATE public.payment_submissions SET submitted_at=now() WHERE id=s.id;
END $$;
CREATE FUNCTION public.review_manual_payment(p_id uuid,p_decision text,p_reason text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE s public.payment_submissions; pay public.payments; profile public.profiles; expected bigint;
BEGIN
 IF auth.role()<>'authenticated' OR NOT public.is_admin() THEN RAISE EXCEPTION 'Admins only' USING ERRCODE='42501'; END IF;
 IF p_decision IS NULL OR p_decision NOT IN ('approved','rejected') OR p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'Decision and reason required'; END IF;
 SELECT * INTO s FROM public.payment_submissions WHERE id=p_id FOR UPDATE;
 IF NOT FOUND OR s.submitted_at IS NULL THEN RAISE EXCEPTION 'Completed submission not found'; END IF;
 IF s.status=p_decision THEN RETURN; END IF;
 IF s.status<>'pending' THEN RAISE EXCEPTION 'Submission already reviewed'; END IF;
 SELECT * INTO pay FROM public.payments WHERE id=s.payment_id FOR UPDATE;
 IF NOT FOUND OR pay.channel<>'manual' OR pay.owner_id<>s.owner_id OR pay.status<>'created' THEN RAISE EXCEPTION 'Payment cannot be reviewed'; END IF;
 SELECT * INTO profile FROM public.profiles WHERE id=s.owner_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Profile not found'; END IF;
 IF p_decision='approved' THEN
  expected:=(CASE pay.plan WHEN 'standard' THEN 120000 ELSE 180000 END)+CASE WHEN pay.includes_joining_fee THEN 300000 ELSE 0 END;
  IF pay.amount_paise<>expected OR pay.includes_joining_fee=profile.joining_fee_paid THEN RAISE EXCEPTION 'Amount or joining fee changed; reject and request a new submission'; END IF;
  IF profile.plan IS NOT NULL AND profile.plan<>pay.plan AND profile.plan_expires_at>now() THEN RAISE EXCEPTION 'Active plan differs; resolve before approval'; END IF;
  UPDATE public.payments SET status='paid',paid_at=now() WHERE id=pay.id;
  UPDATE public.profiles SET plan=pay.plan,plan_expires_at=greatest(coalesce(plan_expires_at,now()),now())+interval '1 year',joining_fee_paid=joining_fee_paid OR pay.includes_joining_fee WHERE id=s.owner_id;
 ELSE UPDATE public.payments SET status='failed' WHERE id=pay.id;
 END IF;
 UPDATE public.payment_submissions SET status=p_decision,reviewed_at=now(),reviewer_id=auth.uid(),reason=btrim(p_reason) WHERE id=s.id;
 INSERT INTO public.subscription_audit(owner_id,actor_id,action,reason,payment_id) VALUES(s.owner_id,auth.uid(),'proof_'||p_decision,btrim(p_reason),pay.id);
END $$;
CREATE FUNCTION public.admin_set_access_audited(p_user_id uuid,p_action text,p_plan public.plan_kind,p_reason text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF auth.role()<>'authenticated' OR NOT public.is_admin() THEN RAISE EXCEPTION 'Admins only' USING ERRCODE='42501'; END IF;
 IF p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'Reason required'; END IF;
 PERFORM 1 FROM public.profiles WHERE id=p_user_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Profile not found'; END IF;
 PERFORM public.admin_set_access(p_user_id,p_action,p_plan);
 INSERT INTO public.subscription_audit(owner_id,actor_id,action,reason) VALUES(p_user_id,auth.uid(),'admin_'||p_action,btrim(p_reason));
END $$;
-- Preserve signature and arithmetic; explicitly reject non-gateway records and failed orders.
CREATE OR REPLACE FUNCTION public.activate_payment(p_order_id text,p_payment_id text,p_amount_paise bigint)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE pay public.payments;
BEGIN
 SELECT * INTO pay FROM public.payments WHERE razorpay_order_id=p_order_id FOR UPDATE;
 IF NOT FOUND OR pay.channel<>'razorpay' THEN RAISE EXCEPTION 'Unknown Razorpay order'; END IF;
 IF pay.amount_paise<>p_amount_paise OR p_payment_id IS NULL OR length(p_payment_id)=0 THEN RAISE EXCEPTION 'Payment mismatch'; END IF;
 IF pay.status='paid' THEN RETURN false; END IF;
 IF pay.status<>'created' THEN RAISE EXCEPTION 'Order not pending'; END IF;
 PERFORM 1 FROM public.profiles WHERE id=pay.owner_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Profile not found'; END IF;
 UPDATE public.payments SET status='paid',razorpay_payment_id=p_payment_id,paid_at=now() WHERE id=pay.id;
 UPDATE public.profiles SET plan=pay.plan,plan_expires_at=greatest(coalesce(plan_expires_at,now()),now())+interval '1 year',joining_fee_paid=joining_fee_paid OR pay.includes_joining_fee WHERE id=pay.owner_id;
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.activate_payment(text,text,bigint) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.activate_payment(text,text,bigint) TO service_role;
REVOKE ALL ON FUNCTION public.begin_manual_payment(public.plan_kind,text,text,bigint,uuid),public.complete_manual_payment(uuid),public.review_manual_payment(uuid,text,text),public.admin_set_access_audited(uuid,text,public.plan_kind,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.begin_manual_payment(public.plan_kind,text,text,bigint,uuid),public.complete_manual_payment(uuid),public.review_manual_payment(uuid,text,text),public.admin_set_access_audited(uuid,text,public.plan_kind,text) TO authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA entrysetu_private FROM PUBLIC,anon,authenticated;
-- Bucket must be provisioned separately through Storage API, PRIVATE, 5 MB, permitted MIME types.
CREATE POLICY payment_proof_insert ON storage.objects FOR INSERT TO authenticated WITH CHECK(bucket_id='payment-proofs' AND EXISTS(SELECT 1 FROM public.payment_submissions s WHERE s.owner_id=auth.uid() AND s.proof_path=name AND s.status='pending' AND s.submitted_at IS NULL));
CREATE POLICY payment_proof_read ON storage.objects FOR SELECT TO authenticated USING(bucket_id='payment-proofs' AND EXISTS(SELECT 1 FROM public.payment_submissions s WHERE s.proof_path=name AND (s.owner_id=auth.uid() OR public.is_admin())));
-- No UPDATE or DELETE policies: immutable evidence. No retention deletion job is authorized.
COMMIT;
