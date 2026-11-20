-- V2 Annual Leave + Public Holiday Management
-- RUN ONCE after migrations 001, 002 and 003 in Supabase SQL Editor.
-- Access exclusively through authenticated Edge API and service_role.
-- Admin may prepare 2027 entitlements and holiday credits before go-live.
-- Live staff leave submissions remain locked until 2027-01-01.
-- Keep each AL year independent: 2026 entitlement is not counted again when
-- carried-forward leave is explicitly entered in the 2027 row.

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

CREATE OR REPLACE FUNCTION public.admin_save_al_v2(
 p_actor uuid, p_staff uuid, p_year integer, p_entitlement numeric,
 p_carry_forward numeric, p_adjustment numeric, p_notes text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_total numeric; v_reserved numeric; v_id uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.staff WHERE id=p_actor AND role='ADMIN' AND active)
    THEN RAISE EXCEPTION 'Admin access required'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.staff WHERE id=p_staff)
    THEN RAISE EXCEPTION 'Staff not found'; END IF;
  IF p_year IS NULL OR p_year < 2020 OR p_year > 2100 THEN
    RAISE EXCEPTION 'Invalid entitlement year'; END IF;
  IF p_entitlement IS NULL OR p_carry_forward IS NULL OR p_adjustment IS NULL OR
     p_entitlement < 0 OR p_entitlement > 365 OR
     p_carry_forward < 0 OR p_carry_forward > 365 OR
     abs(p_adjustment) > 365 THEN
    RAISE EXCEPTION 'Invalid AL amounts'; END IF;
  v_total:=p_entitlement+p_carry_forward+p_adjustment;
  IF v_total < 0 OR v_total > 365 THEN RAISE EXCEPTION 'Invalid total AL allowance'; END IF;
  IF p_entitlement*2<>trunc(p_entitlement*2) OR p_carry_forward*2<>trunc(p_carry_forward*2)
      OR p_adjustment*2<>trunc(p_adjustment*2) THEN
    RAISE EXCEPTION 'AL values must be whole or half days'; END IF;
  IF length(coalesce(p_notes,'')) > 500 THEN RAISE EXCEPTION 'Notes too long'; END IF;
  -- Same lock as submit_leave_v2, avoiding balance edits racing a request.
  PERFORM pg_advisory_xact_lock(20270101);
  SELECT coalesce(sum(units),0) INTO v_reserved FROM public.leave_requests
    WHERE staff_id=p_staff AND leave_type='AL' AND status IN ('PENDING','APPROVED')
      AND start_date>=make_date(p_year,1,1) AND start_date<make_date(p_year+1,1,1);
  IF v_total<v_reserved THEN RAISE EXCEPTION 'AL cannot be less than already reserved/used (%)',v_reserved; END IF;
  INSERT INTO public.al_balances(staff_id,source_year,entitlement,carry_forward,adjustment,notes)
    VALUES(p_staff,p_year,p_entitlement,p_carry_forward,p_adjustment,nullif(trim(coalesce(p_notes,'')),''))
  ON CONFLICT (staff_id,source_year) DO UPDATE SET
    entitlement=excluded.entitlement,carry_forward=excluded.carry_forward,
    adjustment=excluded.adjustment,notes=excluded.notes
  RETURNING id INTO v_id;
  INSERT INTO public.audit_log(actor_staff_id,action,record_id,metadata)
    VALUES(p_actor,'SAVE_AL_BALANCE',v_id::text,
      jsonb_build_object('staff_id',p_staff,'year',p_year,'entitlement',p_entitlement,
         'carry_forward',p_carry_forward,'adjustment',p_adjustment));
  RETURN jsonb_build_object('ok',true,'balanceId',v_id);
END $$;

CREATE OR REPLACE FUNCTION public.admin_save_ph_v2(
 p_actor uuid,p_credit uuid,p_staff uuid,p_year integer,p_name text,
 p_holiday_date date,p_units numeric,p_release_mode text,p_notes text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_now date:=(now() at time zone 'Asia/Kuala_Lumpur')::date;
 v_old public.ph_credits%ROWTYPE; v_allocated numeric; v_id uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.staff WHERE id=p_actor AND role='ADMIN' AND active)
    THEN RAISE EXCEPTION 'Admin access required'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.staff WHERE id=p_staff)
    THEN RAISE EXCEPTION 'Staff not found'; END IF;
  IF p_year IS NULL OR p_year < 2020 OR p_year > 2100 THEN RAISE EXCEPTION 'Invalid PH year'; END IF;
  IF length(trim(coalesce(p_name,''))) < 2 OR length(p_name) > 160 THEN
    RAISE EXCEPTION 'Enter a valid holiday name'; END IF;
  IF p_units IS NULL OR p_units<=0 OR p_units>30 OR p_units*2<>trunc(p_units*2) THEN
    RAISE EXCEPTION 'PH credit must be 0.5 to 30 days, in half-day increments'; END IF;
  IF p_release_mode NOT IN ('MANUAL','AUTO_DATE') THEN
    RAISE EXCEPTION 'Invalid PH release type'; END IF;
  IF p_release_mode='AUTO_DATE' AND p_holiday_date IS NULL THEN
    RAISE EXCEPTION 'Enter holiday date to auto-unlock PH'; END IF;
  IF p_holiday_date IS NOT NULL AND extract(year from p_holiday_date)::integer<>p_year THEN
    RAISE EXCEPTION 'Holiday date must match its PH source year'; END IF;
  -- Manual release is only for historical PH, never an undated future holiday.
  IF p_release_mode='MANUAL' AND
      (p_year>extract(year from v_now)::integer OR
       (p_year=extract(year from v_now)::integer AND
         (p_holiday_date IS NULL OR p_holiday_date>v_now))) THEN
    RAISE EXCEPTION 'Manual release only applies to historical earned PH; future PH requires a date'; END IF;
  IF length(coalesce(p_notes,''))>500 THEN RAISE EXCEPTION 'Notes too long'; END IF;
  PERFORM pg_advisory_xact_lock(20270101);
  IF p_credit IS NULL THEN
    INSERT INTO public.ph_credits(staff_id,source_year,holiday_name,holiday_date,units,release_mode,notes)
      VALUES(p_staff,p_year,trim(p_name),p_holiday_date,p_units,p_release_mode,
             nullif(trim(coalesce(p_notes,'')),''))
    RETURNING id INTO v_id;
  ELSE
    SELECT * INTO v_old FROM public.ph_credits WHERE id=p_credit FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'PH credit not found'; END IF;
    IF EXISTS(SELECT 1 FROM public.ph_usage WHERE credit_id=p_credit) AND
       (v_old.staff_id IS DISTINCT FROM p_staff OR v_old.source_year IS DISTINCT FROM p_year
       OR v_old.holiday_date IS DISTINCT FROM p_holiday_date
       OR v_old.release_mode IS DISTINCT FROM p_release_mode) THEN
      RAISE EXCEPTION 'Cannot change source date/year/staff once PH has usage history';
    END IF;
    SELECT coalesce(sum(u.units),0) INTO v_allocated
      FROM public.ph_usage u JOIN public.leave_requests r ON r.id=u.request_id
      WHERE u.credit_id=p_credit AND r.status IN ('PENDING','APPROVED');
    IF p_units<v_allocated THEN RAISE EXCEPTION 'PH units cannot be less than already reserved/used (%)',v_allocated; END IF;
    UPDATE public.ph_credits SET staff_id=p_staff,source_year=p_year,
      holiday_name=trim(p_name),holiday_date=p_holiday_date,units=p_units,release_mode=p_release_mode,
      notes=nullif(trim(coalesce(p_notes,'')),'')
      WHERE id=p_credit RETURNING id INTO v_id;
  END IF;
  INSERT INTO public.audit_log(actor_staff_id,action,record_id,metadata)
    VALUES(p_actor,CASE WHEN p_credit IS NULL THEN 'CREATE_PH_CREDIT' ELSE 'UPDATE_PH_CREDIT' END,
      v_id::text,jsonb_build_object('staff_id',p_staff,'year',p_year,'holiday_name',trim(p_name),
        'units',p_units,'release_mode',p_release_mode));
  RETURN jsonb_build_object('ok',true,'creditId',v_id);
END $$;

CREATE OR REPLACE FUNCTION public.admin_toggle_ph_v2(
 p_actor uuid,p_credit uuid,p_active boolean
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_staff uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.staff WHERE id=p_actor AND role='ADMIN' AND active)
    THEN RAISE EXCEPTION 'Admin access required'; END IF;
  IF p_active IS NULL THEN RAISE EXCEPTION 'Invalid status'; END IF;
  PERFORM pg_advisory_xact_lock(20270101);
  SELECT staff_id INTO v_staff FROM public.ph_credits WHERE id=p_credit FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PH credit not found'; END IF;
  IF NOT p_active AND EXISTS(
    SELECT 1 FROM public.ph_usage u JOIN public.leave_requests r ON r.id=u.request_id
    WHERE u.credit_id=p_credit AND r.status IN ('PENDING','APPROVED')
  ) THEN RAISE EXCEPTION 'Cannot deactivate a PH credit with pending or approved usage'; END IF;
  UPDATE public.ph_credits SET active=p_active WHERE id=p_credit;
  INSERT INTO public.audit_log(actor_staff_id,action,record_id,metadata)
    VALUES(p_actor,'TOGGLE_PH_CREDIT',p_credit::text,jsonb_build_object('active',p_active,'staff_id',v_staff));
  RETURN jsonb_build_object('ok',true);
END $$;

-- Prevent browser/anonymous access to RPCs.
REVOKE EXECUTE ON FUNCTION public.admin_save_al_v2(uuid,uuid,integer,numeric,numeric,numeric,text)
  FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_save_ph_v2(uuid,uuid,uuid,integer,text,date,numeric,text,text)
  FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_toggle_ph_v2(uuid,uuid,boolean)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.admin_save_al_v2(uuid,uuid,integer,numeric,numeric,numeric,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_save_ph_v2(uuid,uuid,uuid,integer,text,date,numeric,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_toggle_ph_v2(uuid,uuid,boolean) TO service_role;
