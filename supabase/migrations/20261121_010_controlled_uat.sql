-- SkyBar V2 — 010 Controlled UAT on the existing database
-- Run only after 001–009. No deletion or data reset.
-- Activates a 72-hour UAT window for the exact existing TEST002 UUID only.
-- All normal staff remain locked until 1 January 2027 (Malaysia time).
BEGIN;
SELECT pg_advisory_xact_lock(20270101);
DO $precheck$
BEGIN
 IF (now() AT TIME ZONE 'Asia/Kuala_Lumpur')::date >= date '2027-01-01' THEN
   RAISE EXCEPTION 'Pre-launch UAT cannot be enabled on or after go-live';
 END IF;
 IF to_regclass('public.uat_environment_guard') IS NOT NULL THEN
   RAISE EXCEPTION 'Unexpected staging bypass marker';
 END IF;
 IF NOT EXISTS (SELECT 1 FROM public.staff WHERE employee_id='TEST002' AND role='STAFF' AND active) THEN
   RAISE EXCEPTION 'Expected active dummy TEST002 not found; check employee directory';
 END IF;
 IF EXISTS (SELECT 1 FROM public.staff WHERE role='STAFF' AND active AND employee_id !~ '^TEST[0-9]+$') THEN
   RAISE EXCEPTION 'Actual active staff exist; do not enable shared-database UAT';
 END IF;
 IF EXISTS (SELECT 1 FROM public.leave_requests r JOIN public.staff s ON s.id=r.staff_id WHERE s.employee_id !~ '^TEST[0-9]+$')
 OR EXISTS (SELECT 1 FROM public.overtime_requests r JOIN public.staff s ON s.id=r.staff_id WHERE s.employee_id !~ '^TEST[0-9]+$') THEN
   RAISE EXCEPTION 'Non-test leave or OT history exists; stop and review';
 END IF;
 IF NOT EXISTS (SELECT 1 FROM public.staff WHERE active AND role='ADMIN') THEN
   RAISE EXCEPTION 'Active admin required';
 END IF;
END;
$precheck$;

CREATE TABLE IF NOT EXISTS public.uat_submission_control (
 id smallint PRIMARY KEY CHECK(id=1),
 enabled boolean NOT NULL DEFAULT false,
 expires_at timestamptz NOT NULL,
 allowed_staff_ids uuid[] NOT NULL DEFAULT ARRAY[]::uuid[]
);
ALTER TABLE public.uat_submission_control ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.uat_submission_control FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.uat_submission_allowed_v2(p_staff_id uuid)
RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path=public AS $$
 SELECT EXISTS (
  SELECT 1 FROM public.uat_submission_control c JOIN public.staff s ON s.id=p_staff_id
  WHERE c.id=1 AND c.enabled AND c.expires_at>now()
    AND (now() AT TIME ZONE 'Asia/Kuala_Lumpur')::date < date '2027-01-01'
    AND s.id=ANY(c.allowed_staff_ids) AND s.active AND s.role='STAFF'
    AND s.employee_id ~ '^TEST[0-9]+$'
    AND NOT EXISTS (SELECT 1 FROM public.staff x WHERE x.active AND x.role='STAFF' AND x.employee_id !~ '^TEST[0-9]+$')
 );
$$;
REVOKE EXECUTE ON FUNCTION public.uat_submission_allowed_v2(uuid) FROM PUBLIC,anon,authenticated,service_role;

-- Only a database operator can modify the control table via SQL Editor.
-- The frontend and existing Edge Function cannot toggle this mode.

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
  -- Lock covers mode changes and the full submission transaction.
  perform pg_advisory_xact_lock(20270101);
  if v_today<date '2027-01-01' and not public.uat_submission_allowed_v2(p_staff_id) then
    raise exception 'Live submissions open 1 January 2027';
  end if;
  -- Dummy IDs must never be used for live operations after UAT expires.
  if exists(select 1 from public.staff where id=p_staff_id and employee_id ~ '^TEST[0-9]+$')
      and not public.uat_submission_allowed_v2(p_staff_id) then
    raise exception 'Dummy account not authorized for active UAT';
  end if;
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
  -- Lock covers mode changes and the full submission transaction.
  perform pg_advisory_xact_lock(20270101);
  if v_today<date '2027-01-01' and not public.uat_submission_allowed_v2(p_staff_id) then
    raise exception 'Live submissions open 1 January 2027';
  end if;
  -- Dummy IDs must never be used for live operations after UAT expires.
  if exists(select 1 from public.staff where id=p_staff_id and employee_id ~ '^TEST[0-9]+$')
      and not public.uat_submission_allowed_v2(p_staff_id) then
    raise exception 'Dummy account not authorized for active UAT';
  end if;
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

REVOKE EXECUTE ON FUNCTION public.submit_leave_v2(uuid,text,text,date,date,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.submit_leave_v2(uuid,text,text,date,date,text,text) TO service_role;
REVOKE EXECUTE ON FUNCTION public.submit_overtime_v2(uuid,date,time,time,text,text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.submit_overtime_v2(uuid,date,time,time,text,text,uuid) TO service_role;

INSERT INTO public.uat_submission_control(id,enabled,expires_at,allowed_staff_ids)
SELECT 1,true,least(now()+interval '72 hours', timestamptz '2027-01-01 00:00:00+08'),ARRAY[id]
FROM public.staff WHERE employee_id='TEST002' AND active AND role='STAFF'
ON CONFLICT(id) DO UPDATE SET enabled=excluded.enabled,expires_at=excluded.expires_at,allowed_staff_ids=excluded.allowed_staff_ids;

INSERT INTO public.audit_log(actor_staff_id,action,record_id,metadata)
SELECT id,'ENABLE_CONTROLLED_UAT','UAT_CONTROL_1',jsonb_build_object('dummy_employee_id','TEST002','expires_at',(SELECT expires_at FROM public.uat_submission_control WHERE id=1))
FROM public.staff WHERE active AND role='ADMIN' ORDER BY employee_id LIMIT 1;

COMMIT;

SELECT c.enabled AS uat_enabled,c.expires_at AT TIME ZONE 'Asia/Kuala_Lumpur' AS expiry_malaysia,
       s.employee_id AS allowed_dummy,public.uat_submission_allowed_v2(s.id) AS dummy_submission_allowed
FROM public.uat_submission_control c JOIN public.staff s ON s.id=ANY(c.allowed_staff_ids)
WHERE c.id=1;
