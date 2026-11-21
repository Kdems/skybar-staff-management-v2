-- FRESH START DRAFT: DO NOT EXECUTE until backup is verified and approved.
-- Default is deliberately blocked. No TRUNCATE, DROP, schema reset or audit deletion.
BEGIN;
SELECT pg_advisory_xact_lock(20270101);
LOCK TABLE public.staff,public.staff_sessions,public.login_attempts,public.al_balances,
 public.ph_credits,public.leave_requests,public.leave_days,public.ph_usage,
 public.overtime_requests,public.audit_log,public.ot_form_templates,
 public.uat_submission_control IN SHARE ROW EXCLUSIVE MODE;

DO $cleanup$
DECLARE
 backup_verified_and_cleanup_approved boolean := false;
 test_ids uuid[];
 admin_id uuid;
BEGIN
 IF NOT backup_verified_and_cleanup_approved THEN
   RAISE EXCEPTION 'STOP: verified backup and explicit cleanup approval required';
 END IF;
 IF (now() AT TIME ZONE 'Asia/Kuala_Lumpur')::date >= date '2027-01-01' THEN
   RAISE EXCEPTION 'Pre-launch cleanup cannot run after go-live';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.uat_submission_control WHERE id=1 AND NOT enabled AND cardinality(allowed_staff_ids)=0) THEN
   RAISE EXCEPTION 'Disable UAT first';
 END IF;
 SELECT id INTO admin_id FROM public.staff WHERE employee_id='ADMIN001' AND role='ADMIN' AND active;
 IF admin_id IS NULL THEN RAISE EXCEPTION 'Protected admin missing'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.ot_form_templates WHERE id=1 AND octet_length(file_bytes)>300) THEN
   RAISE EXCEPTION 'Protected OT master missing';
 END IF;
 SELECT array_agg(id) INTO test_ids FROM public.staff WHERE employee_id IN ('TEST002','TEST003','TEST004') AND role='STAFF';
 IF coalesce(cardinality(test_ids),0)<>3 THEN RAISE EXCEPTION 'Expected exactly three dummy IDs'; END IF;
 IF EXISTS(SELECT 1 FROM public.staff WHERE role='STAFF' AND NOT id=ANY(test_ids)) THEN
   RAISE EXCEPTION 'Unknown or real staff accounts exist; review manually';
 END IF;
 IF EXISTS(SELECT 1 FROM public.leave_requests WHERE NOT staff_id=ANY(test_ids))
 OR EXISTS(SELECT 1 FROM public.overtime_requests WHERE NOT staff_id=ANY(test_ids))
 OR EXISTS(SELECT 1 FROM public.al_balances WHERE NOT staff_id=ANY(test_ids))
 OR EXISTS(SELECT 1 FROM public.ph_credits WHERE NOT staff_id=ANY(test_ids)) THEN
   RAISE EXCEPTION 'Non-test operational data exists; review manually';
 END IF;
 IF EXISTS(SELECT 1 FROM public.ot_form_templates WHERE updated_by=ANY(test_ids)) THEN
   RAISE EXCEPTION 'OT template references dummy staff; review manually';
 END IF;

 -- Delete children first, using only exact identified dummy UUIDs.
 DELETE FROM public.ph_usage WHERE request_id IN (SELECT id FROM public.leave_requests WHERE staff_id=ANY(test_ids));
 DELETE FROM public.leave_days WHERE request_id IN (SELECT id FROM public.leave_requests WHERE staff_id=ANY(test_ids));
 DELETE FROM public.leave_requests WHERE staff_id=ANY(test_ids);
 DELETE FROM public.overtime_requests WHERE staff_id=ANY(test_ids);
 DELETE FROM public.al_balances WHERE staff_id=ANY(test_ids);
 DELETE FROM public.ph_credits WHERE staff_id=ANY(test_ids);
 DELETE FROM public.staff_sessions WHERE staff_id=ANY(test_ids);
 DELETE FROM public.login_attempts WHERE employee_id IN ('TEST002','TEST003','TEST004');
 -- Keep audit history, moving the actor's identity into metadata before removing FK.
 UPDATE public.audit_log a
 SET metadata=jsonb_build_object('original_metadata',a.metadata,'archived_uat_actor',jsonb_build_object('id',s.id,'employee_id',s.employee_id)),actor_staff_id=NULL
 FROM public.staff s WHERE a.actor_staff_id=s.id AND s.id=ANY(test_ids);
 DELETE FROM public.staff WHERE id=ANY(test_ids);
 INSERT INTO public.audit_log(actor_staff_id,action,record_id,metadata)
 VALUES(admin_id,'FRESH_START_UAT_CLEANUP','UAT_CONTROL_1',jsonb_build_object('removed_employee_ids',ARRAY['TEST002','TEST003','TEST004']));
 IF EXISTS(SELECT 1 FROM public.staff WHERE id=ANY(test_ids)) OR NOT EXISTS(SELECT 1 FROM public.staff WHERE id=admin_id AND active)
 OR NOT EXISTS(SELECT 1 FROM public.ot_form_templates WHERE id=1) THEN
   RAISE EXCEPTION 'Post-cleanup invariant failed';
 END IF;
END;
$cleanup$;

-- This draft deliberately rolls back even if the guard above is edited.
-- A separate reviewed execution version must be prepared after verified backup.
ROLLBACK;
