-- SkyBar Staff Management V2: read-only production readiness report.
-- Run in Supabase SQL Editor. Makes NO changes and returns NO employee names or credentials.
-- A PASS here is a configuration/data check, not an end-to-end UAT or a backup.

BEGIN TRANSACTION READ ONLY;

WITH expected_tables(name) AS (
 VALUES ('staff'),('staff_sessions'),('login_attempts'),('al_balances'),
 ('ph_credits'),('ph_usage'),('leave_requests'),('leave_days'),
 ('overtime_requests'),('audit_log'),('ot_form_templates')
), actual_tables AS (
 SELECT c.oid,c.relname,c.relrowsecurity
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public' AND c.relkind IN ('r','p')
), privileged_functions AS (
 SELECT p.oid,p.proname,pg_get_functiondef(p.oid) AS body
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.prokind='f' AND p.proname IN (
 'submit_leave_v2','submit_overtime_v2','change_leave_status_v2',
 'admin_change_leave_type_v2','change_overtime_status_v2',
 'admin_set_ot_form_v2','get_ot_form_v2','admin_set_ot_approver_v2',
 'admin_apply_ph_schedule_v2','admin_save_ph_opening_balances_v2',
 'admin_save_al_v2','employee_create_v2','employee_update_v2',
 'employee_status_v2','employee_reset_pin_v2','employee_delete_unused_v2',
 'employee_change_own_pin_v2','login_staff')
), expected_functions(name) AS (
 VALUES ('submit_leave_v2'),('submit_overtime_v2'),('change_leave_status_v2'),
 ('admin_change_leave_type_v2'),('change_overtime_status_v2'),
 ('admin_set_ot_form_v2'),('get_ot_form_v2'),('admin_set_ot_approver_v2'),
 ('admin_apply_ph_schedule_v2'),('admin_save_ph_opening_balances_v2'),
 ('admin_save_al_v2'),('employee_create_v2'),('employee_update_v2'),
 ('employee_status_v2'),('employee_reset_pin_v2'),('employee_delete_unused_v2'),
 ('employee_change_own_pin_v2'),('login_staff')
), checks AS (
 SELECT 1 AS seq,'Required database tables' AS check_name,
   CASE WHEN count(a.oid)=11 THEN 'PASS' ELSE 'REVIEW' END AS result,
   count(a.oid)::text||' / 11 present' AS detail
 FROM expected_tables e LEFT JOIN actual_tables a ON a.relname=e.name
 UNION ALL
 SELECT 2,'Row-level security enabled',
   CASE WHEN count(a.oid) FILTER (WHERE a.relrowsecurity)=11 THEN 'PASS' ELSE 'REVIEW' END,
   count(a.oid) FILTER (WHERE a.relrowsecurity)||' / 11 enabled'
 FROM expected_tables e LEFT JOIN actual_tables a ON a.relname=e.name
 UNION ALL
 SELECT 3,'Public database policies',
   CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
   count(*)||' policies on protected tables (expected 0)'
 FROM pg_policies p JOIN expected_tables t ON t.name=p.tablename WHERE p.schemaname='public'
 UNION ALL
 SELECT 4,'Required server functions',
   CASE WHEN count(*) FILTER (WHERE NOT EXISTS(SELECT 1 FROM privileged_functions f WHERE f.proname=e.name))=0 THEN 'PASS' ELSE 'REVIEW' END,
   coalesce(string_agg(e.name,', ' ORDER BY e.name) FILTER (WHERE NOT EXISTS(SELECT 1 FROM privileged_functions f WHERE f.proname=e.name)),'All listed functions present')
 FROM expected_functions e
 UNION ALL
 SELECT 5,'No direct public RPC execution',
   CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
   coalesce(string_agg(proname,', ' ORDER BY proname),'No listed RPC executable by anon/authenticated')
 FROM privileged_functions WHERE has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE')
 UNION ALL
 SELECT 6,'Leave and OT launch date guards',
   CASE WHEN count(DISTINCT proname)=2 THEN 'PASS' ELSE 'REVIEW' END,
   count(DISTINCT proname)||' / 2 functions contain the expected 2027 lock'
 FROM privileged_functions WHERE proname IN ('submit_leave_v2','submit_overtime_v2') AND body LIKE '%2027-01-01%'
 UNION ALL
 SELECT 7,'No staging bypass marker',
   CASE WHEN to_regclass('public.uat_environment_guard') IS NULL THEN 'PASS' ELSE 'REVIEW' END,
   CASE WHEN to_regclass('public.uat_environment_guard') IS NULL THEN 'No staging guard table' ELSE 'Staging marker present — investigate before use' END
 UNION ALL
 SELECT 8,'Original OT master stored',
   CASE WHEN count(*)=1 THEN 'PASS' ELSE 'REVIEW' END,
   count(*)||' valid nonempty master record'
 FROM public.ot_form_templates WHERE id=1 AND octet_length(file_bytes)>300
 UNION ALL
 SELECT 9,'Active Admin accounts',
   CASE WHEN count(*)>0 THEN 'PASS' ELSE 'REVIEW' END,
   count(*)||' active Admin account(s)'
 FROM public.staff WHERE active AND role='ADMIN'
 UNION ALL
 SELECT 10,'Active OT approvers',
   CASE WHEN count(*)>0 THEN 'PASS' ELSE 'REVIEW' END,
   count(*)||' active flagged approver(s)'
 FROM public.staff WHERE active AND ot_approver
 UNION ALL
 SELECT 11,'Active operational staff / 2027 AL',
   'REVIEW',count(*)||' active STAFF accounts excluding obvious TEST IDs; '||
      count(*) FILTER(WHERE EXISTS(SELECT 1 FROM public.al_balances a WHERE a.staff_id=s.id AND a.source_year=2027))||' have 2027 AL rows; reconcile to HR roster'
 FROM public.staff s WHERE s.active AND s.role='STAFF' AND s.employee_id NOT ILIKE 'TEST%'
 UNION ALL
 SELECT 12,'Active TEST accounts',
   'INFO',count(*)||' active TEST-prefix accounts; keep until final UAT cleanup'
 FROM public.staff WHERE active AND employee_id ILIKE 'TEST%'
 UNION ALL
 SELECT 13,'Duplicate active OT dates',
   CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,count(*)||' duplicate staff/date groups'
 FROM (SELECT staff_id,ot_date FROM public.overtime_requests WHERE status IN ('PENDING','APPROVED') GROUP BY staff_id,ot_date HAVING count(*)>1) d
 UNION ALL
 SELECT 14,'Leave calendar maximum two staff',
   CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,count(*)||' dates exceeding two distinct staff'
 FROM (SELECT leave_date FROM public.leave_days WHERE status IN ('PENDING','APPROVED') GROUP BY leave_date HAVING count(DISTINCT staff_id)>2) d
)
SELECT check_name,result,detail FROM checks ORDER BY seq;

ROLLBACK;
