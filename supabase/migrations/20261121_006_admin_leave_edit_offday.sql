-- SKYBAR STAFF MANAGEMENT V2 — 006 ADMIN LEAVE TYPE CORRECTION
-- Install AFTER migrations 001–005. Production leave submission lock remains unchanged.
-- OFF = Off Day (admin-reclassified leave request only).
-- Staff submit_leave_v2 intentionally does not permit OFF.
-- Atomic conversion preserves dates, requester and approval status;
-- PH allocation is refunded/reallocated, AL availability recalculated and the change audited.

BEGIN;
ALTER TABLE public.leave_requests DROP CONSTRAINT IF EXISTS leave_requests_leave_type_check;
ALTER TABLE public.leave_requests ADD CONSTRAINT leave_requests_leave_type_check
  CHECK (leave_type IN ('AL','PH','EL','OFF'));

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
      AND (c.release_mode='MANUAL' OR c.holiday_date<=v_today);
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
        AND (c.release_mode='MANUAL' OR c.holiday_date<=v_today)
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
COMMIT;
