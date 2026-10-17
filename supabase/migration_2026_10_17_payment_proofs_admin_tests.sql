-- REVIEW ONLY. Rollback-only on DEV after the payment/admin proposal. NEVER production.
-- Does not provision buckets or persist user data. Fixtures use synthetic auth users.
BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean,label text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %',label; END IF; END $$;
SELECT pg_temp.assert_true(NOT has_table_privilege('anon','public.payment_submissions','SELECT'),'proofs deny anonymous table access');
SELECT pg_temp.assert_true(NOT has_table_privilege('authenticated','public.payment_submissions','INSERT'),'seller cannot directly create submissions');
SELECT pg_temp.assert_true(NOT has_table_privilege('authenticated','public.payment_submissions','UPDATE'),'seller cannot review submissions');
SELECT pg_temp.assert_true(NOT has_function_privilege('authenticated','public.activate_payment(text,text,bigint)','EXECUTE'),'gateway activation service only');
SELECT pg_temp.assert_true(NOT has_function_privilege('anon','public.review_manual_payment(uuid,text,text)','EXECUTE'),'anonymous review denied');
SELECT pg_temp.assert_true(has_function_privilege('authenticated','public.review_manual_payment(uuid,text,text)','EXECUTE'),'signed-in review callable with internal admin check');
SELECT pg_temp.assert_true(NOT has_table_privilege('service_role','public.subscription_audit','UPDATE'),'service role audit update grant denied');
INSERT INTO auth.users(id,email) VALUES('a7100000-0000-4000-8000-000000000001','proof-test-a@example.invalid'),('a7100000-0000-4000-8000-000000000002','proof-test-b@example.invalid'),('a7100000-0000-4000-8000-000000000003','proof-test-admin@example.invalid');
INSERT INTO public.profiles(id,email) VALUES('a7100000-0000-4000-8000-000000000001','proof-test-a@example.invalid'),('a7100000-0000-4000-8000-000000000002','proof-test-b@example.invalid'),('a7100000-0000-4000-8000-000000000003','proof-test-admin@example.invalid') ON CONFLICT(id) DO NOTHING;
INSERT INTO public.user_roles(user_id,role) VALUES('a7100000-0000-4000-8000-000000000003','admin');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}',true);
CREATE TEMP TABLE proof_test_result AS SELECT public.begin_manual_payment('standard','UTR-TEST-1','image/png',20,'a7200000-0000-4000-8000-000000000001') AS value;
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM public.payment_submissions),'owner reads own pending submission');
SELECT pg_temp.assert_true((SELECT amount_paise=420000 AND includes_joining_fee AND channel='manual' AND status='created' FROM public.payments WHERE owner_id=auth.uid()),'Standard 1200 plus joining fee 3000, no activation');
SELECT pg_temp.assert_true((SELECT plan IS NULL AND NOT joining_fee_paid FROM public.profiles WHERE id=auth.uid()),'upload initiation does not grant access');
SELECT pg_temp.assert_true(public.begin_manual_payment('standard','UTR-TEST-1','image/png',20,'a7200000-0000-4000-8000-000000000001')->>'id'=(SELECT value->>'id' FROM proof_test_result),'begin retry is idempotent');
DO $$ BEGIN PERFORM public.complete_manual_payment((SELECT (value->>'id')::uuid FROM proof_test_result)); RAISE EXCEPTION 'FAIL: missing object accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE '%screenshot upload is missing%' THEN RAISE; END IF; END $$;
DO $$ BEGIN PERFORM public.review_manual_payment((SELECT (value->>'id')::uuid FROM proof_test_result),'approved','not admin'); RAISE EXCEPTION 'FAIL: seller reviewed'; EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
SELECT set_config('request.jwt.claims','{"sub":"a7100000-0000-4000-8000-000000000002","role":"authenticated"}',true);
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM public.payment_submissions),'tenant B cannot see A proof');
SELECT public.begin_manual_payment('unlimited','UTR-TEST-2','image/webp',20,'a7200000-0000-4000-8000-000000000002');
SELECT pg_temp.assert_true((SELECT amount_paise=480000 FROM public.payments WHERE owner_id=auth.uid()),'Unlimited 1800 plus joining fee 3000');
RESET ROLE;
-- Synthetic object metadata only, no bucket creation. Rollback removes it.
-- If payment-proofs is not yet provisioned, skip this section by NOT running the tests until separately approved storage setup exists.
INSERT INTO storage.objects(bucket_id,name,metadata) SELECT 'payment-proofs',proof_path,jsonb_build_object('mimetype',mime,'size',byte_size) FROM public.payment_submissions WHERE owner_id='a7100000-0000-4000-8000-000000000001';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}',true);
SELECT public.complete_manual_payment((SELECT (value->>'id')::uuid FROM proof_test_result));
SELECT public.complete_manual_payment((SELECT (value->>'id')::uuid FROM proof_test_result));
SELECT pg_temp.assert_true((SELECT plan IS NULL FROM public.profiles WHERE id=auth.uid()),'completion still does not activate');
SELECT set_config('request.jwt.claims','{"sub":"a7100000-0000-4000-8000-000000000003","role":"authenticated"}',true);
SELECT public.review_manual_payment((SELECT (value->>'id')::uuid FROM proof_test_result),'approved','Verified test evidence');
SELECT public.review_manual_payment((SELECT (value->>'id')::uuid FROM proof_test_result),'approved','Idempotent retry');
SELECT pg_temp.assert_true((SELECT plan='standard' AND joining_fee_paid AND plan_expires_at=now()+interval '1 year' FROM public.profiles WHERE id='a7100000-0000-4000-8000-000000000001'),'approval grants one year once');
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM public.subscription_audit WHERE action='proof_approved' AND owner_id='a7100000-0000-4000-8000-000000000001'),'exactly one approval event');
DO $$ BEGIN PERFORM public.review_manual_payment((SELECT (value->>'id')::uuid FROM proof_test_result),'rejected','Conflicting review'); RAISE EXCEPTION 'FAIL: changed terminal review'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE '%already reviewed%' THEN RAISE; END IF; END $$;
SELECT public.admin_set_access_audited('a7100000-0000-4000-8000-000000000002','extend_trial',NULL,'Five-day test extension');
SELECT pg_temp.assert_true((SELECT trial_ends_at=now()+interval '10 days' FROM public.profiles WHERE id='a7100000-0000-4000-8000-000000000002'),'trial extension adds five days');
RESET ROLE;
DO $$ BEGIN UPDATE public.subscription_audit SET reason='tampered'; RAISE EXCEPTION 'FAIL: audit editable'; EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
DO $$ BEGIN DELETE FROM public.subscription_audit; RAISE EXCEPTION 'FAIL: audit deletable'; EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
DO $$ BEGIN RAISE NOTICE 'PAYMENT/ADMIN ROLLBACK CHECKS PASSED (if this notice is reached). True concurrent connections and Storage API upload limits still require separate testing.'; END $$;
ROLLBACK;
