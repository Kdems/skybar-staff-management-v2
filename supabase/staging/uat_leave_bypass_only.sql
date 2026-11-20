-- STAGING ONLY. NEVER run this SQL in the production project.
-- It permits leave UAT before 2027-01-01 ONLY in an empty separate Supabase project.
-- Required order: new empty Supabase project -> migrations 001,002,003,004,005
-- -> THIS FILE -> seed ADMIN001 and dummy STAFF users.
-- This script refuses to run if any staff or leave/PH/AL/OT records already exist.
-- Do NOT replicate real staff data. Create UAT-specific Admin PINs.
BEGIN;

DO $uat_precheck$
BEGIN
  IF to_regclass('public.staff') IS NULL
     OR to_regclass('public.leave_requests') IS NULL
     OR to_regclass('public.ph_credits') IS NULL
     OR to_regclass('public.al_balances') IS NULL THEN
    RAISE EXCEPTION 'Run core staging schema migrations 001 through 005 first';
  END IF;
  IF EXISTS(SELECT 1 FROM public.staff) OR
     EXISTS(SELECT 1 FROM public.leave_requests) OR
     EXISTS(SELECT 1 FROM public.ph_credits) OR
     EXISTS(SELECT 1 FROM public.al_balances) OR
     EXISTS(SELECT 1 FROM public.overtime_requests) THEN
    RAISE EXCEPTION 'STOP: this is not an empty staging database; do not override the live lock';
  END IF;
END;
$uat_precheck$;

CREATE TABLE public.uat_environment_guard (
  id integer PRIMARY KEY DEFAULT 1 CHECK (id=1),
  environment text NOT NULL CHECK (environment='UAT_ONLY'),
  created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.uat_environment_guard(id,environment) VALUES(1,'UAT_ONLY');
ALTER TABLE public.uat_environment_guard ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.uat_environment_guard FROM PUBLIC,anon,authenticated;

-- Staging: only the database-side go-live check is relaxed;
-- current-month, staff active, remaining balance, 2 staff/date,
-- overlap, pending/approved and PH credit release rules stay enforced.

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
  if v_today<date '2027-01-01' AND NOT EXISTS (
    SELECT 1 FROM public.uat_environment_guard
    WHERE id=1 AND environment='UAT_ONLY'
  ) then
    raise exception 'Live submissions open 1 January 2027';
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

-- Original server-only grants from migration 001 remain unchanged.
-- A guard check stays inside the leave RPC. It will deny early submissions
-- if the UAT environment record is not present.
COMMIT;
