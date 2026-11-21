-- SKYBAR STAFF MANAGEMENT V2 — FRESH START FINAL EXECUTION
-- DESTRUCTIVE: ONLY run after validating a complete recoverable backup.
-- Changes: removes TEST002/TEST003/TEST004 and their linked dummy AL/PH/Leave/OT/session records.
-- Preserves ADMIN001, uploaded HR OT master, audit events (archives dummy actor in metadata).
-- Restores BOTH original pre-2027 submission guards and removes temporary UAT-only controls.
--
-- MANUAL APPROVAL REQUIRED: replace exactly the placeholder below after reviewing
-- the backup archive, sha256, restore plan, and dry-run PASS. DO NOT share credentials.
BEGIN;
DO $approval_gate$
DECLARE
  approval_phrase text := 'NOT_APPROVED'; -- EDIT ONLY THIS STRING WHEN READY
BEGIN
  IF approval_phrase <> 'I APPROVE DELETION OF TEST002 TEST003 TEST004' THEN
    RAISE EXCEPTION 'STOP: Fresh Start has NOT been explicitly approved';
  END IF;
END;
$approval_gate$;
SELECT pg_advisory_xact_lock(20270101);
LOCK TABLE public.staff, public.staff_sessions, public.login_attempts,
  public.al_balances, public.ph_credits, public.ph_usage,
  public.leave_requests, public.leave_days, public.overtime_requests,
  public.audit_log, public.ot_form_templates, public.uat_submission_control
  IN SHARE ROW EXCLUSIVE MODE;

DO $fresh_start$
DECLARE
  test_ids uuid[];
  admin_id uuid;
  archived_audit_count integer;
BEGIN
  IF (now() AT TIME ZONE 'Asia/Kuala_Lumpur')::date >= date '2027-01-01' THEN
    RAISE EXCEPTION 'STOP: Prelaunch cleanup cannot run after go-live';
  END IF;
  IF to_regclass('public.uat_submission_control') IS NULL THEN
    RAISE EXCEPTION 'STOP: Expected UAT control missing';
  END IF;
  IF NOT EXISTS (
     SELECT 1 FROM public.uat_submission_control
     WHERE id=1 AND enabled=false AND cardinality(allowed_staff_ids)=0
   ) THEN RAISE EXCEPTION 'STOP: Disable UAT mode before cleanup'; END IF;

  SELECT id INTO admin_id FROM public.staff
    WHERE employee_id='ADMIN001' AND role='ADMIN' AND active;
  IF admin_id IS NULL THEN RAISE EXCEPTION 'STOP: ADMIN001 account missing'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.ot_form_templates WHERE id=1 AND updated_by=admin_id
      AND octet_length(file_bytes)>300
  ) THEN
    RAISE EXCEPTION 'STOP: Original HR OT template or uploader is not ADMIN001';
  END IF;

  SELECT array_agg(id) INTO test_ids FROM public.staff
    WHERE employee_id IN ('TEST002','TEST003','TEST004') AND role='STAFF';
  IF coalesce(cardinality(test_ids),0)<>3 THEN
    RAISE EXCEPTION 'STOP: Expected exactly TEST002/TEST003/TEST004';
  END IF;
  IF EXISTS (SELECT 1 FROM public.staff WHERE role='STAFF' AND id<>ALL(test_ids)) THEN
    RAISE EXCEPTION 'STOP: Other real/unknown staff exist (even inactive)';
  END IF;
  IF EXISTS (SELECT 1 FROM public.al_balances WHERE staff_id<>ALL(test_ids))
    OR EXISTS (SELECT 1 FROM public.ph_credits WHERE staff_id<>ALL(test_ids))
    OR EXISTS (SELECT 1 FROM public.leave_requests WHERE staff_id<>ALL(test_ids))
    OR EXISTS (SELECT 1 FROM public.leave_days WHERE staff_id<>ALL(test_ids))
    OR EXISTS (SELECT 1 FROM public.overtime_requests WHERE staff_id<>ALL(test_ids))
    OR EXISTS (SELECT 1 FROM public.ph_usage
      WHERE request_id NOT IN (SELECT id FROM public.leave_requests WHERE staff_id=ANY(test_ids)))
    OR EXISTS (SELECT 1 FROM public.staff_sessions
      WHERE staff_id <> admin_id AND staff_id<>ALL(test_ids))
  THEN RAISE EXCEPTION 'STOP: Non-dummy operational records exist'; END IF;

  -- Match the UAT snapshot. Unexpected changes require a fresh review.
  IF (SELECT count(*) FROM public.leave_requests WHERE staff_id=ANY(test_ids))<>3
    OR (SELECT count(*) FROM public.overtime_requests WHERE staff_id=ANY(test_ids))<>4
    OR (SELECT count(*) FROM public.al_balances WHERE staff_id=ANY(test_ids))<>4
    OR (SELECT count(*) FROM public.ph_credits WHERE staff_id=ANY(test_ids))<>10
    OR (SELECT count(*) FROM public.leave_days WHERE staff_id=ANY(test_ids))<>3
    OR (SELECT count(*) FROM public.ph_usage WHERE request_id IN
        (SELECT id FROM public.leave_requests WHERE staff_id=ANY(test_ids)))<>1
  THEN RAISE EXCEPTION 'STOP: Dummy record counts changed since preview; review before cleanup'; END IF;

  -- Preserve audit event contents and clear actor FK before removing dummy staff.
  UPDATE public.audit_log a SET
    metadata=jsonb_build_object(
      'original_metadata',a.metadata,
      'archived_uat_actor',jsonb_build_object('id',s.id,'employee_id',s.employee_id)
    ),
    actor_staff_id=NULL
  FROM public.staff s
  WHERE a.actor_staff_id=s.id AND s.id=ANY(test_ids);
  GET DIAGNOSTICS archived_audit_count=ROW_COUNT;

  -- Fail safely if a non-dummy row references any dummy via management fields.
  IF EXISTS (SELECT 1 FROM public.leave_requests
      WHERE staff_id<>ALL(test_ids) AND decided_by=ANY(test_ids))
    OR EXISTS (SELECT 1 FROM public.overtime_requests
      WHERE staff_id<>ALL(test_ids)
        AND (decided_by=ANY(test_ids) OR instructed_by=ANY(test_ids)))
  THEN RAISE EXCEPTION 'STOP: Non-test records reference dummy approvers'; END IF;

  DELETE FROM public.ph_usage WHERE request_id IN
    (SELECT id FROM public.leave_requests WHERE staff_id=ANY(test_ids));
  DELETE FROM public.leave_days WHERE request_id IN
    (SELECT id FROM public.leave_requests WHERE staff_id=ANY(test_ids));
  DELETE FROM public.leave_requests WHERE staff_id=ANY(test_ids);
  DELETE FROM public.overtime_requests WHERE staff_id=ANY(test_ids);
  DELETE FROM public.al_balances WHERE staff_id=ANY(test_ids);
  DELETE FROM public.ph_credits WHERE staff_id=ANY(test_ids);
  DELETE FROM public.staff_sessions WHERE staff_id=ANY(test_ids);
  DELETE FROM public.login_attempts WHERE employee_id IN ('TEST002','TEST003','TEST004');
  DELETE FROM public.staff WHERE id=ANY(test_ids);

  INSERT INTO public.audit_log(actor_staff_id,action,record_id,metadata)
  VALUES (admin_id,'FRESH_START_UAT_CLEANUP','UAT_CONTROL_1',
    jsonb_build_object('dummy_ids',ARRAY['TEST002','TEST003','TEST004'],
      'archived_actor_audit_rows',archived_audit_count));

  IF (SELECT count(*) FROM public.staff WHERE employee_id='ADMIN001' AND role='ADMIN' AND active)<>1
    OR (SELECT count(*) FROM public.ot_form_templates WHERE id=1 AND updated_by=admin_id)<>1
    OR EXISTS (SELECT 1 FROM public.staff WHERE role='STAFF')
  THEN RAISE EXCEPTION 'STOP: Post-cleanup verification failed'; END IF;
  RAISE NOTICE 'FINAL CLEANUP VALIDATED: 3 dummy staff and UAT operational data removed. Archived audit actors: %. ADMIN001 and OT template protected. COMMIT pending.',archived_audit_count;
END;
$fresh_start$;

-- Reapply original production submission functions, eliminating UAT bypass.

create or replace function public.submit_leave_v2(
  p_staff_id uuid,p_leave_type text,p_duration text,
  p_start date,p_end date,p_reason text,p_code text
) returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_date date; v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
 v_month date := date_trunc('month',now() at time zone 'Asia/Kuala_Lumpur')::date;
 v_days integer; v_units numeric; v_slots integer; v_available numeric;
 v_request uuid; v_credit record; v_needed numeric; v_use numeric;
begin
  -- Operations locked until target go-live, including admin.
  if v_today<date '2027-01-01' then raise exception 'Live submissions open 1 January 2027'; end if;
  if not exists (select 1 from public.staff where id=p_staff_id and active) then raise exception 'Inactive account'; end if;
  if p_leave_type not in ('AL','PH','EL') or p_duration not in ('FULL','HALF_AM','HALF_PM') then raise exception 'Invalid leave type or duration'; end if;
  if p_start is null or p_end is null or p_start>p_end or p_start<v_today
     or p_start<v_month or p_end>=(v_month+interval '1 month')::date then
    raise exception 'Only future dates within the current month are allowed';
  end if;
  if length(trim(coalesce(p_reason,'')))<3 or length(p_reason)>500 then raise exception 'Please enter a reason (3–500 characters)'; end if;
  v_days:=p_end-p_start+1; if v_days>31 then raise exception 'Invalid leave range'; end if;
  v_units:=v_days*(case when p_duration='FULL' then 1 else 0.5 end);

  -- Serialize all overlapping leave and PH credit submissions with one lock.
  perform pg_advisory_xact_lock(20270101);
  for v_date in select generate_series(p_start,p_end,'1 day'::interval)::date loop
    select count(*) into v_slots from public.leave_days where leave_date=v_date and status in ('PENDING','APPROVED');
    if v_slots>=2 then raise exception '% is full (2 staff maximum)',v_date; end if;
    if exists(select 1 from public.leave_days where leave_date=v_date and staff_id=p_staff_id and status in ('PENDING','APPROVED')) then
      raise exception 'You already have leave on %',v_date;
    end if;
  end loop;
  if p_leave_type='AL' then
    select coalesce(sum(entitlement+carry_forward+adjustment),0) into v_available
    from public.al_balances where staff_id=p_staff_id and source_year=extract(year from v_today)::integer;
    -- Only this year's allowance is usable; carry-forward is explicitly stored in this year's row.
    -- Do not double count older year's entitlement and the carry-forward figure.
    select v_available-coalesce(sum(units),0) into v_available from public.leave_requests
      where staff_id=p_staff_id and leave_type='AL' and status in ('PENDING','APPROVED')
        and start_date>=make_date(extract(year from v_today)::integer,1,1)
        and start_date<make_date(extract(year from v_today)::integer+1,1,1);
    if v_available<v_units then raise exception 'Insufficient AL balance'; end if;
  elsif p_leave_type='PH' then
    select coalesce(sum(greatest(0,c.units-coalesce((
      select sum(u.units) from public.ph_usage u join public.leave_requests r on r.id=u.request_id
      where u.credit_id=c.id and r.status in ('PENDING','APPROVED')),0))),0)
      into v_available from public.ph_credits c
      where c.staff_id=p_staff_id and c.active and (c.release_mode='MANUAL' or c.holiday_date<=v_today);
    if v_available<v_units then raise exception 'Insufficient unlocked PH balance'; end if;
  end if;
  insert into public.leave_requests(request_code,staff_id,leave_type,duration,start_date,end_date,units,reason)
    values(p_code,p_staff_id,p_leave_type,p_duration,p_start,p_end,v_units,trim(p_reason)) returning id into v_request;
  for v_date in select generate_series(p_start,p_end,'1 day'::interval)::date loop
    insert into public.leave_days(request_id,staff_id,leave_date,status) values(v_request,p_staff_id,v_date,'PENDING');
  end loop;
  if p_leave_type='PH' then
    v_needed:=v_units;
    for v_credit in
      select c.id,c.units-coalesce((
        select sum(u.units) from public.ph_usage u join public.leave_requests r on r.id=u.request_id
        where u.credit_id=c.id and r.status in ('PENDING','APPROVED')),0) as remaining
      from public.ph_credits c where c.staff_id=p_staff_id and c.active
        and (c.release_mode='MANUAL' or c.holiday_date<=v_today)
      order by c.source_year,c.holiday_date nulls first,c.created_at
    loop
      exit when v_needed<=0;
      v_use:=least(v_needed,greatest(v_credit.remaining,0));
      if v_use>0 then
        insert into public.ph_usage(request_id,credit_id,units) values(v_request,v_credit.id,v_use);
        v_needed:=v_needed-v_use;
      end if;
    end loop;
    if v_needed>0 then raise exception 'PH allocation failed'; end if;
  end if;
  insert into public.audit_log(actor_staff_id,action,record_id) values(p_staff_id,'SUBMIT_LEAVE',v_request::text);
  return jsonb_build_object('requestCode',p_code,'requestId',v_request);
end $$;

create or replace function public.submit_overtime_v2(
 p_staff_id uuid,p_date date,p_start time,p_end time,p_claim_type text,
 p_reason text,p_approver uuid
) returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
 v_minutes integer; v_id uuid;
begin
  if v_today<date '2027-01-01' then raise exception 'Live submissions open 1 January 2027'; end if;
  if not exists(select 1 from public.staff where id=p_staff_id and active) then raise exception 'Inactive account'; end if;
  if p_date is null or p_date>v_today or p_date<v_today-interval '31 days' then raise exception 'OT date must be within the last 31 days'; end if;
  if p_claim_type not in ('NORMAL','OFF','PH') then raise exception 'Invalid OT claim type'; end if;
  if p_start is null or p_end is null then raise exception 'Shift times required'; end if;
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'Reason is required'; end if;
  -- Serialize submissions and block a second Pending/Approved OT for the same date.
  perform pg_advisory_xact_lock(20270101);
  if exists(select 1 from public.overtime_requests
    where staff_id=p_staff_id and ot_date=p_date and status in ('PENDING','APPROVED')) then
    raise exception 'An active OT claim already exists for this date';
  end if;
  v_minutes:=round(extract(epoch from (p_end-p_start))/60)::integer;
  if v_minutes<=0 then v_minutes:=v_minutes+1440; end if;
  if v_minutes<=540 then raise exception 'No OT after 9 working hours'; end if;
  if p_approver is null or not exists(select 1 from public.staff where id=p_approver and active and ot_approver) then
    raise exception 'Choose an active OT Approver / Manager / Supervisor'; end if;
  insert into public.overtime_requests(staff_id,ot_date,shift_start,shift_end,
    total_shift_minutes,ot_minutes,claim_type,reason,instructed_by)
    values(p_staff_id,p_date,p_start,p_end,v_minutes,v_minutes-540,p_claim_type,trim(p_reason),p_approver)
    returning id into v_id;
  insert into public.audit_log(actor_staff_id,action,record_id) values(p_staff_id,'SUBMIT_OT',v_id::text);
  return jsonb_build_object('requestId',v_id,'hours',(v_minutes-540)/60.0);
end $$;

REVOKE EXECUTE ON FUNCTION public.submit_leave_v2(uuid,text,text,date,date,text,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.submit_leave_v2(uuid,text,text,date,date,text,text)
  TO service_role;
REVOKE EXECUTE ON FUNCTION public.submit_overtime_v2(uuid,date,time,time,text,text,uuid)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.submit_overtime_v2(uuid,date,time,time,text,text,uuid)
  TO service_role;

-- Remove UAT-only helper and UAT-only control table after both original functions return.
DROP FUNCTION public.uat_submission_allowed_v2(uuid);
DROP TABLE public.uat_submission_control;

DO $endcheck$
BEGIN
 IF EXISTS (
   SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public'
     AND p.proname IN ('submit_leave_v2','submit_overtime_v2')
     AND pg_get_functiondef(p.oid) LIKE '%uat_submission_allowed_v2%'
 ) THEN RAISE EXCEPTION 'STOP: UAT bypass still referenced'; END IF;
 IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname IN ('submit_leave_v2','submit_overtime_v2')
     AND pg_get_functiondef(p.oid) LIKE '%2027-01-01%')<>2
 THEN RAISE EXCEPTION 'STOP: Production go-live guard missing'; END IF;
 RAISE NOTICE 'FINAL CHECK PASSED: production guards restored; cleanup will COMMIT.';
END;
$endcheck$;

SELECT 'PRE-COMMIT VALIDATION — PASS' AS result,
  (SELECT count(*) FROM public.staff WHERE role='STAFF') AS dummy_staff_in_transaction,
  (SELECT count(*) FROM public.ot_form_templates WHERE id=1) AS hr_master_protected;

-- Any prior failure aborts the transaction. Commit only if ALL checks passed.
COMMIT;

-- Independently read the final persisted state.
SELECT
 CASE WHEN
   (SELECT count(*) FROM public.staff WHERE employee_id IN ('TEST002','TEST003','TEST004'))=0
   AND (SELECT count(*) FROM public.staff WHERE employee_id='ADMIN001' AND role='ADMIN' AND active)=1
   AND (SELECT count(*) FROM public.ot_form_templates WHERE id=1)>0
   AND to_regclass('public.uat_submission_control') IS NULL
   AND (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='public' AND p.proname IN ('submit_leave_v2','submit_overtime_v2')
          AND pg_get_functiondef(p.oid) LIKE '%2027-01-01%'
          AND pg_get_functiondef(p.oid) NOT LIKE '%uat_submission_allowed_v2%')=2
 THEN 'FRESH START — PASS' ELSE 'REVIEW REQUIRED' END AS result,
 (SELECT count(*) FROM public.staff WHERE employee_id='ADMIN001' AND role='ADMIN' AND active) AS admins_preserved,
 (SELECT count(*) FROM public.staff WHERE role='STAFF') AS staff_remaining,
 (SELECT count(*) FROM public.ot_form_templates WHERE id=1) AS ot_master_preserved,
 (SELECT count(*) FROM public.leave_requests) AS leave_requests_remaining,
 (SELECT count(*) FROM public.overtime_requests) AS ot_requests_remaining,
 (SELECT count(*) FROM public.audit_log WHERE action='FRESH_START_UAT_CLEANUP') AS cleanup_audit_events;
