-- SkyBar Staff Management V2 — PH 3-month expiry verification (READ ONLY)
-- Run after migration 011; no PH rows are modified.
BEGIN TRANSACTION READ ONLY;

WITH used AS (
 SELECT u.credit_id, coalesce(sum(u.units) FILTER(WHERE r.status IN ('PENDING','APPROVED')),0) AS units
 FROM public.ph_usage u
 JOIN public.leave_requests r ON r.id=u.request_id
 GROUP BY u.credit_id
), credit_status AS (
 SELECT c.*,
   greatest(0,c.units-coalesce(u.units,0)) AS unused_units,
   CASE WHEN NOT c.active THEN 'INACTIVE'
     WHEN c.expires_on IS NOT NULL AND c.expires_on <= (now() AT TIME ZONE 'Asia/Kuala_Lumpur')::date
       THEN CASE WHEN greatest(0,c.units-coalesce(u.units,0))>0 THEN 'BURN' ELSE 'USED' END
     WHEN c.release_mode='AUTO_DATE' AND c.holiday_date>(now() AT TIME ZONE 'Asia/Kuala_Lumpur')::date THEN 'LOCKED'
     ELSE 'RELEASED'
   END AS credit_status
 FROM public.ph_credits c LEFT JOIN used u ON u.credit_id=c.id
)
SELECT
  credit_status AS status,
  count(*) AS credits,
  coalesce(sum(unused_units),0) AS unused_units,
  coalesce(sum(unused_units) FILTER (WHERE credit_status='BURN'),0) AS burned_units
FROM credit_status
GROUP BY credit_status
ORDER BY credit_status;

SELECT
  (date '2027-01-01' + interval '3 months')::date AS new_year_burn_date,
  (date '2027-01-31' + interval '3 months')::date AS jan_31_burn_date,
  (SELECT count(*) FROM public.ph_credits WHERE holiday_date IS NULL) AS undated_historical_credits,
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public'
    AND p.proname IN ('submit_leave_v2','admin_change_leave_type_v2')
    AND pg_get_functiondef(p.oid) LIKE '%expires_on%') AS protected_submission_paths;

ROLLBACK;
