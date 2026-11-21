-- Stop shared-database UAT immediately. No data deletion.
BEGIN;
SELECT pg_advisory_xact_lock(20270101);
UPDATE public.uat_submission_control SET enabled=false,allowed_staff_ids=ARRAY[]::uuid[] WHERE id=1;
INSERT INTO public.audit_log(actor_staff_id,action,record_id)
SELECT id,'DISABLE_CONTROLLED_UAT','UAT_CONTROL_1' FROM public.staff WHERE active AND role='ADMIN' ORDER BY employee_id LIMIT 1;
COMMIT;
SELECT enabled AS uat_enabled,cardinality(allowed_staff_ids) AS allowed_accounts FROM public.uat_submission_control WHERE id=1;
