-- Read-only preview. Safe before backup; no records are changed.
BEGIN TRANSACTION READ ONLY;
WITH t AS (SELECT id FROM public.staff WHERE employee_id IN ('TEST002','TEST003','TEST004') AND role='STAFF')
SELECT 'Dummy staff' AS item,count(*) AS records FROM t
UNION ALL SELECT 'AL balances',count(*) FROM public.al_balances WHERE staff_id IN (SELECT id FROM t)
UNION ALL SELECT 'PH credits',count(*) FROM public.ph_credits WHERE staff_id IN (SELECT id FROM t)
UNION ALL SELECT 'Leave requests',count(*) FROM public.leave_requests WHERE staff_id IN (SELECT id FROM t)
UNION ALL SELECT 'Leave days',count(*) FROM public.leave_days WHERE staff_id IN (SELECT id FROM t)
UNION ALL SELECT 'PH usage',count(*) FROM public.ph_usage WHERE request_id IN (SELECT id FROM public.leave_requests WHERE staff_id IN (SELECT id FROM t))
UNION ALL SELECT 'OT requests',count(*) FROM public.overtime_requests WHERE staff_id IN (SELECT id FROM t)
UNION ALL SELECT 'Sessions',count(*) FROM public.staff_sessions WHERE staff_id IN (SELECT id FROM t)
UNION ALL SELECT 'Login attempts',count(*) FROM public.login_attempts WHERE employee_id IN ('TEST002','TEST003','TEST004')
UNION ALL SELECT 'Audit rows to retain with archived actor identity',count(*) FROM public.audit_log WHERE actor_staff_id IN (SELECT id FROM t)
UNION ALL SELECT 'Other active staff (must be zero)',count(*) FROM public.staff WHERE active AND role='STAFF' AND employee_id NOT IN ('TEST002','TEST003','TEST004')
UNION ALL SELECT 'Protected ADMIN001 (must be one)',count(*) FROM public.staff WHERE employee_id='ADMIN001' AND role='ADMIN' AND active
UNION ALL SELECT 'Protected OT master (must be one)',count(*) FROM public.ot_form_templates WHERE id=1 AND octet_length(file_bytes)>300
UNION ALL SELECT 'UAT enabled or allowlist nonempty (must be zero)',count(*) FROM public.uat_submission_control WHERE enabled OR cardinality(allowed_staff_ids)>0;
ROLLBACK;
