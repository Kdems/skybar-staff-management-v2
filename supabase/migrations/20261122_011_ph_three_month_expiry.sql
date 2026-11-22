-- SkyBar V2 / 011 — PH valid for three calendar months from the holiday date.
-- Example: 2027-01-01 is usable through 2027-03-31; burns on 2027-04-01.
-- Booking/leave END date must be before expiry (covers multi-day claims).
-- Unused units become unavailable on expiry; reserved/approved PH history remains.
-- Does not create reminders, notifications, scheduled jobs or delete any PH rows.
-- Historical/manual opening balances with NULL holiday_date cannot be dated
-- without HR evidence and are deliberately preserved until reconciled.
-- Run once AFTER Fresh Start and final production baseline backup.
BEGIN;

DO $precheck$
BEGIN
 IF to_regclass('public.ph_credits') IS NULL
  OR to_regclass('public.ph_usage') IS NULL
  OR to_regclass('public.leave_requests') IS NULL THEN
   RAISE EXCEPTION 'STOP: Expected PH schema missing';
 END IF;
 IF to_regclass('public.uat_submission_control') IS NOT NULL THEN
   RAISE EXCEPTION 'STOP: Temporary UAT controls still present';
 END IF;
 IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.proname IN ('submit_leave_v2','admin_change_leave_type_v2')) <> 2 THEN
   RAISE EXCEPTION 'STOP: Missing PH submit or Admin correction function';
 END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.proname='submit_leave_v2'
       AND pg_get_functiondef(p.oid) LIKE '%2027-01-01%'
       AND pg_get_functiondef(p.oid) NOT LIKE '%uat_submission_allowed_v2%') THEN
   RAISE EXCEPTION 'STOP: Original 2027 leave guard not restored';
 END IF;
END;
$precheck$;

-- PostgreSQL calendar-month arithmetic clamps month-end dates.
-- NULL holiday_date (historical opening balance) -> NULL expires_on.
ALTER TABLE public.ph_credits
  ADD COLUMN IF NOT EXISTS expires_on date
  GENERATED ALWAYS AS ((holiday_date + interval '3 months')::date) STORED;

COMMENT ON COLUMN public.ph_credits.expires_on IS
 'Exclusive 3-month expiry date; any unused dated PH units burn at local Malaysia midnight on this date. NULL means historical undated opening credit requiring HR reconciliation.';

-- Only the original active date-guarded 2027 production functions are replaced.

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
      where c.staff_id=p_staff_id and c.active and (c.release_mode='MANUAL' or c.holiday_date<=v_today) and (c.expires_on is null or (v_today<c.expires_on and p_end<c.expires_on));
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
        and (c.release_mode='MANUAL' or c.holiday_date<=v_today) and (c.expires_on is null or (v_today<c.expires_on and p_end<c.expires_on))
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

REVOKE EXECUTE ON FUNCTION public.submit_leave_v2(uuid,text,text,date,date,text,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.submit_leave_v2(uuid,text,text,date,date,text,text)
  TO service_role;

CREATE OR REPLACE FUNCTION public.admin_change_leave_type_v2(
  p_actor uuid, p_request uuid, p_type text, p_note text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  v_request public.leave_requests%ROWTYPE;
  v_year integer;
  v_new_al numeric;
  v_granted numeric;
  v_reserved numeric;
  v_available numeric;
  v_needed numeric;
  v_credit record;
  v_use numeric;
  v_today date := (now() AT TIME ZONE 'Asia/Kuala_Lumpur')::date;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.staff
                 WHERE id=p_actor AND role='ADMIN' AND active) THEN
    RAISE EXCEPTION 'Only an active Admin can change leave type';
  END IF;
  IF p_type IS NULL OR p_type NOT IN ('AL','PH','EL','OFF') THEN
    RAISE EXCEPTION 'Invalid leave type';
  END IF;
  IF length(trim(coalesce(p_note,'')))<3 OR length(trim(coalesce(p_note,'')))>500 THEN
    RAISE EXCEPTION 'Admin must provide a reason (3–500 characters)';
  END IF;

  -- Matches the lock used by submissions and PH credit administration.
  PERFORM pg_advisory_xact_lock(20270101);
  SELECT * INTO v_request FROM public.leave_requests WHERE id=p_request FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Leave request not found'; END IF;
  IF v_request.status NOT IN ('PENDING','APPROVED') THEN
    RAISE EXCEPTION 'Only pending or approved leave can be reclassified';
  END IF;
  IF v_request.leave_type=p_type THEN
    RAISE EXCEPTION 'Select a different leave type';
  END IF;
  v_year := extract(year FROM v_request.start_date)::integer;
  IF extract(year FROM v_request.end_date)::integer<>v_year THEN
    RAISE EXCEPTION 'Leave date range must stay within one year';
  END IF;
  IF v_request.units IS NULL OR v_request.units<=0 THEN
    RAISE EXCEPTION 'Invalid leave units';
  END IF;

  -- Changing AWAY from PH releases all prior reservations for this request
  -- automatically, even when request status is Approved.
  IF v_request.leave_type='PH' THEN
    DELETE FROM public.ph_usage WHERE request_id=v_request.id;
  END IF;

  IF p_type='AL' THEN
    SELECT coalesce(sum(entitlement+carry_forward+adjustment),0)
      INTO v_granted FROM public.al_balances
      WHERE staff_id=v_request.staff_id AND source_year=v_year;
    -- Exclude the original record; it is being moved into AL in this transaction.
    SELECT coalesce(sum(units),0) INTO v_reserved FROM public.leave_requests
      WHERE staff_id=v_request.staff_id AND leave_type='AL'
        AND status IN ('PENDING','APPROVED') AND id<>v_request.id
        AND start_date>=make_date(v_year,1,1)
        AND start_date<make_date(v_year+1,1,1);
    IF v_granted-v_reserved<v_request.units THEN
      RAISE EXCEPTION 'Insufficient AL balance for requested year: need %, available %',
        v_request.units,greatest(0,v_granted-v_reserved);
    END IF;
  ELSIF p_type='PH' THEN
    SELECT coalesce(sum(greatest(0,c.units-coalesce((
      SELECT sum(u.units) FROM public.ph_usage u
      JOIN public.leave_requests r ON r.id=u.request_id
      WHERE u.credit_id=c.id AND r.status IN ('PENDING','APPROVED')
    ),0))),0) INTO v_available FROM public.ph_credits c
    WHERE c.staff_id=v_request.staff_id AND c.active
      AND (c.release_mode='MANUAL' OR c.holiday_date<=v_today) AND (c.expires_on IS NULL OR (v_today<c.expires_on AND v_request.end_date<c.expires_on));
    IF v_available<v_request.units THEN
      RAISE EXCEPTION 'Insufficient released PH credits: need %, available %',
        v_request.units,v_available;
    END IF;

    -- Allocate oldest released credits first (same as ordinary leave submission).
    v_needed:=v_request.units;
    FOR v_credit IN
      SELECT c.id,c.units-coalesce((
        SELECT sum(u.units) FROM public.ph_usage u
        JOIN public.leave_requests r ON r.id=u.request_id
        WHERE u.credit_id=c.id AND r.status IN ('PENDING','APPROVED')
      ),0) AS remaining
      FROM public.ph_credits c
      WHERE c.staff_id=v_request.staff_id AND c.active
        AND (c.release_mode='MANUAL' OR c.holiday_date<=v_today) AND (c.expires_on IS NULL OR (v_today<c.expires_on AND v_request.end_date<c.expires_on))
      ORDER BY c.source_year,c.holiday_date NULLS FIRST,c.created_at,c.id
    LOOP
      EXIT WHEN v_needed<=0;
      v_use:=least(v_needed,greatest(0,v_credit.remaining));
      IF v_use>0 THEN
        INSERT INTO public.ph_usage(request_id,credit_id,units)
          VALUES(v_request.id,v_credit.id,v_use);
        v_needed:=v_needed-v_use;
      END IF;
    END LOOP;
    IF v_needed>0 THEN RAISE EXCEPTION 'PH allocation failed'; END IF;
  END IF;

  -- OFF and EL do not debit AL or PH. OFF still reserves the daily leave slot
  -- because leave_days and the request's Pending/Approved state are preserved.
  UPDATE public.leave_requests
    SET leave_type=p_type,
      admin_note=trim(p_note)
    WHERE id=v_request.id;

  INSERT INTO public.audit_log(actor_staff_id,action,record_id,metadata)
    VALUES(p_actor,'ADMIN_EDIT_LEAVE_TYPE',v_request.id::text,
      jsonb_build_object(
        'staff_id',v_request.staff_id,
        'previous_type',v_request.leave_type,'new_type',p_type,
        'status',v_request.status,'units',v_request.units,
        'start_date',v_request.start_date,'end_date',v_request.end_date,
        'admin_note',trim(p_note)
      ));
  RETURN jsonb_build_object('ok',true,'requestId',v_request.id,
    'previousType',v_request.leave_type,'newType',p_type,
    'status',v_request.status,'units',v_request.units);
END $$;

REVOKE EXECUTE ON FUNCTION public.admin_change_leave_type_v2(uuid,uuid,text,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.admin_change_leave_type_v2(uuid,uuid,text,text)
  TO service_role;

-- Verify both server-side paths use expiry and the original go-live lock remains.
DO $verify$
BEGIN
 IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname IN ('submit_leave_v2','admin_change_leave_type_v2')
       AND pg_get_functiondef(p.oid) LIKE '%expires_on%') <> 2 THEN
   RAISE EXCEPTION 'STOP: PH expiry missing in a server-side submission path';
 END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname='submit_leave_v2'
       AND pg_get_functiondef(p.oid) LIKE '%2027-01-01%') THEN
   RAISE EXCEPTION 'STOP: 2027 production date lock missing';
 END IF;
 IF (date '2027-01-01'+interval '3 months')::date<>date '2027-04-01'
    OR (date '2027-01-31'+interval '3 months')::date<>date '2027-04-30' THEN
   RAISE EXCEPTION 'STOP: Calendar-month expiry date calculation unexpected';
 END IF;
END;
$verify$;

COMMIT;

SELECT 'PH THREE-MONTH EXPIRY — SQL PASS' AS result,
  count(*) AS total_credits,
  count(*) FILTER (WHERE holiday_date IS NOT NULL) AS dated_credits,
  count(*) FILTER (WHERE holiday_date IS NULL) AS undated_historical_credits,
  count(*) FILTER (WHERE active AND expires_on IS NOT NULL
     AND expires_on <= (now() AT TIME ZONE 'Asia/Kuala_Lumpur')::date) AS expired_dated_credits,
  count(*) FILTER (WHERE active AND expires_on IS NOT NULL
     AND expires_on > (now() AT TIME ZONE 'Asia/Kuala_Lumpur')::date) AS unexpired_dated_credits
FROM public.ph_credits;
