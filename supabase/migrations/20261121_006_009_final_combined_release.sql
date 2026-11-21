-- SKYBAR STAFF MANAGEMENT V2 — FINAL COMBINED RELEASE 006–009
-- One SQL Editor execution, ONE transaction; run only after backup and migrations 001–005.
-- Includes Admin Leave OFF correction, OT approval, private HR OT template and V1.7 payroll parity.
-- IMPORTANT: do not run individual 006,007,008,009 after this combined migration.
-- Production leave submission lock (1 January 2027) remains unchanged.
BEGIN;
DO $combined_precheck$
BEGIN
  IF to_regclass('public.staff') IS NULL
    OR to_regclass('public.leave_requests') IS NULL
    OR to_regclass('public.al_balances') IS NULL
    OR to_regclass('public.ph_credits') IS NULL
    OR to_regclass('public.ph_usage') IS NULL
    OR to_regclass('public.overtime_requests') IS NULL
    OR to_regclass('public.audit_log') IS NULL THEN
    RAISE EXCEPTION 'Expected V2 schema missing. Install migrations 001–005 first.';
  END IF;
  IF to_regclass('public.uat_environment_guard') IS NOT NULL THEN
    RAISE EXCEPTION 'STOP: this release targets live V2 only, not the isolated UAT database';
  END IF;
  IF NOT EXISTS (
     SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.proname='submit_leave_v2'
       AND position('2027-01-01' IN pg_get_functiondef(p.oid))>0
  ) THEN
    RAISE EXCEPTION 'Expected 2027 leave submission safety lock missing; stop and investigate';
  END IF;
END;
$combined_precheck$;

-- ----------- MIGRATION 006 (source: supabase/migrations/20261121_006_admin_leave_edit_offday.sql) -----------
-- SKYBAR STAFF MANAGEMENT V2 — 006 ADMIN LEAVE TYPE CORRECTION
-- Install AFTER migrations 001–005. Production leave submission lock remains unchanged.
-- OFF = Off Day (admin-reclassified leave request only).
-- Staff submit_leave_v2 intentionally does not permit OFF.
-- Atomic conversion preserves dates, requester and approval status;
-- PH allocation is refunded/reallocated, AL availability recalculated and the change audited.


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

-- ----------- MIGRATION 007 (source: supabase/migrations/20261121_007_overtime_approval.sql) -----------
-- SkyBar Staff Management V2 — 007 Overtime Approval and Cancellation
-- Apply AFTER 001–006. Live submissions remain locked until 1 January 2027.

ALTER TABLE public.overtime_requests
  ADD COLUMN IF NOT EXISTS decided_at timestamptz,
  ADD COLUMN IF NOT EXISTS decided_by uuid REFERENCES public.staff(id),
  ADD COLUMN IF NOT EXISTS admin_note text;

CREATE OR REPLACE FUNCTION public.change_overtime_status_v2(
 p_actor uuid,p_request uuid,p_status text,p_admin_note text DEFAULT ''
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_request public.overtime_requests%ROWTYPE; v_actor public.staff%ROWTYPE;
BEGIN
 SELECT * INTO v_actor FROM public.staff WHERE id=p_actor AND active;
 IF NOT FOUND THEN RAISE EXCEPTION 'Inactive or missing actor'; END IF;
 IF p_status NOT IN ('APPROVED','REJECTED','CANCELLED') THEN
   RAISE EXCEPTION 'Invalid overtime status'; END IF;
 IF length(coalesce(p_admin_note,''))>500 THEN
   RAISE EXCEPTION 'Admin note too long'; END IF;
 SELECT * INTO v_request FROM public.overtime_requests WHERE id=p_request FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Overtime request not found'; END IF;
 IF v_request.status<>'PENDING' THEN
   RAISE EXCEPTION 'Only pending overtime can be changed'; END IF;
 IF p_status='CANCELLED' THEN
   IF p_actor<>v_request.staff_id AND v_actor.role<>'ADMIN' THEN
     RAISE EXCEPTION 'Only request owner or Admin can cancel pending OT'; END IF;
 ELSE
   IF v_actor.role<>'ADMIN' THEN
     RAISE EXCEPTION 'Admin approval required'; END IF;
   IF p_status='REJECTED' AND length(trim(coalesce(p_admin_note,'')))<3 THEN
     RAISE EXCEPTION 'Rejection requires a reason'; END IF;
 END IF;
 UPDATE public.overtime_requests SET
   status=p_status,decided_at=now(),decided_by=p_actor,
   admin_note=nullif(trim(coalesce(p_admin_note,'')),'')
 WHERE id=p_request;
 INSERT INTO public.audit_log(actor_staff_id,action,record_id,metadata)
  VALUES(p_actor,'OT_'||p_status,p_request::text,
   jsonb_build_object('staff_id',v_request.staff_id,'ot_date',v_request.ot_date,
     'ot_minutes',v_request.ot_minutes,'admin_note',p_admin_note));
 RETURN jsonb_build_object('ok',true,'status',p_status,'requestId',p_request);
END $$;

REVOKE EXECUTE ON FUNCTION public.change_overtime_status_v2(uuid,uuid,text,text)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.change_overtime_status_v2(uuid,uuid,text,text) TO service_role;

-- ----------- MIGRATION 008 (source: supabase/migrations/20261121_008_ot_form_template.sql) -----------
-- SkyBar Staff Management V2 — 008 Editable HR OT Form Template
-- Run AFTER 001-007, only in approved database.
-- Admin uploads one source-matched .xlsx template (macro-free).
-- Server authenticates all reads; staff receive template only through Edge session.

CREATE TABLE IF NOT EXISTS public.ot_form_templates (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id=1),
  filename text NOT NULL,
  file_bytes bytea NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid NOT NULL REFERENCES public.staff(id)
);
ALTER TABLE public.ot_form_templates ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ot_form_templates FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.admin_set_ot_form_v2(
 p_actor uuid,p_filename text,p_b64 text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_bytes bytea;v_size integer;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.staff WHERE id=p_actor AND role='ADMIN' AND active)
   THEN RAISE EXCEPTION 'Admin access required'; END IF;
 IF p_filename IS NULL OR p_filename !~* '^[a-zA-Z0-9._ -]{1,100}[.]xlsx$'
   THEN RAISE EXCEPTION 'Upload a valid macro-free .xlsx filename'; END IF;
 IF p_b64 IS NULL OR length(p_b64)<100 OR length(p_b64)>2800000 OR p_b64 !~ '^[A-Za-z0-9+/]+={0,2}$'
   THEN RAISE EXCEPTION 'Invalid XLSX template data'; END IF;
 BEGIN
   v_bytes:=decode(p_b64,'base64');
 EXCEPTION WHEN others THEN RAISE EXCEPTION 'Invalid base64 template'; END;
 v_size:=octet_length(v_bytes);
 IF v_size<300 OR v_size>2097152 OR substring(v_bytes FROM 1 FOR 4)<>decode('504b0304','hex')
   THEN RAISE EXCEPTION 'Invalid or oversized .xlsx ZIP template'; END IF;
 IF position(convert_to('vbaProject.bin','UTF8') IN v_bytes)>0
   THEN RAISE EXCEPTION 'Macro-enabled Excel files are not permitted'; END IF;
 PERFORM pg_advisory_xact_lock(20270101);
 INSERT INTO public.ot_form_templates(id,filename,file_bytes,updated_by)
 VALUES(1,p_filename,v_bytes,p_actor)
 ON CONFLICT (id) DO UPDATE SET filename=excluded.filename,
   file_bytes=excluded.file_bytes,updated_by=excluded.updated_by,updated_at=now();
 INSERT INTO public.audit_log(actor_staff_id,action,record_id,metadata)
 VALUES(p_actor,'REPLACE_OT_FORM_TEMPLATE','OT_TEMPLATE_1',
   jsonb_build_object('filename',p_filename,'bytes',v_size));
 RETURN jsonb_build_object('ok',true,'filename',p_filename,'bytes',v_size);
END $$;

CREATE OR REPLACE FUNCTION public.get_ot_form_v2()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_name text;v_bytes bytea;
BEGIN
 SELECT filename,file_bytes INTO v_name,v_bytes
 FROM public.ot_form_templates WHERE id=1;
 IF NOT FOUND THEN RAISE EXCEPTION 'OT form template not configured. Ask Admin to upload the approved .xlsx template'; END IF;
 RETURN jsonb_build_object('filename',v_name,'base64',encode(v_bytes,'base64'));
END $$;

REVOKE EXECUTE ON FUNCTION public.get_ot_form_v2()
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_ot_form_v2() TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_set_ot_form_v2(uuid,text,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_ot_form_v2(uuid,text,text) TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.ot_form_templates TO service_role;


-- ----------- MIGRATION 009: V1.7 OT APPROVER / PAYROLL PARITY -----------
-- SKYBAR STAFF MANAGEMENT V2 — 009 V1.7 OVERTIME FEATURE PARITY
-- Restores OT Approver management, duplicate-OT protection, and approved-OT Admin correction.
-- Requires migration 007; does NOT change the 2027-01-01 go-live lock.

ALTER TABLE public.staff ADD COLUMN IF NOT EXISTS ot_approver boolean NOT NULL DEFAULT false;
UPDATE public.staff SET ot_approver=true WHERE role='ADMIN';

CREATE UNIQUE INDEX IF NOT EXISTS overtime_active_staff_date_uq
  ON public.overtime_requests(staff_id,ot_date)
  WHERE status IN ('PENDING','APPROVED');

CREATE OR REPLACE FUNCTION public.admin_set_ot_approver_v2(
 p_actor uuid,p_target uuid,p_enabled boolean
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.staff WHERE id=p_actor AND active AND role='ADMIN')
    THEN RAISE EXCEPTION 'Admin access required'; END IF;
 IF p_enabled IS NULL THEN RAISE EXCEPTION 'Invalid OT Approver flag'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.staff WHERE id=p_target)
    THEN RAISE EXCEPTION 'Employee account not found'; END IF;
 UPDATE public.staff SET ot_approver=p_enabled WHERE id=p_target;
 INSERT INTO public.audit_log(actor_staff_id,action,record_id,metadata)
 VALUES(p_actor,'SET_OT_APPROVER',p_target::text,jsonb_build_object('enabled',p_enabled));
 RETURN jsonb_build_object('ok',true);
END $$;
REVOKE EXECUTE ON FUNCTION public.admin_set_ot_approver_v2(uuid,uuid,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_ot_approver_v2(uuid,uuid,boolean) TO service_role;

-- Replaces only OT submission function; leave submission lock and other leave RPCs remain intact.
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

-- Admin may cancel an Approved OT record with a reason (original V1.7 behavior);
-- Staff may only cancel own Pending OT, and only Admin may Approve/Reject.
CREATE OR REPLACE FUNCTION public.change_overtime_status_v2(
 p_actor uuid,p_request uuid,p_status text,p_admin_note text DEFAULT ''
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_request public.overtime_requests%ROWTYPE; v_actor public.staff%ROWTYPE;
BEGIN
 SELECT * INTO v_actor FROM public.staff WHERE id=p_actor AND active;
 IF NOT FOUND THEN RAISE EXCEPTION 'Inactive or missing actor'; END IF;
 IF p_status NOT IN ('APPROVED','REJECTED','CANCELLED') THEN
   RAISE EXCEPTION 'Invalid overtime status'; END IF;
 IF length(coalesce(p_admin_note,''))>500 THEN
   RAISE EXCEPTION 'Admin note too long'; END IF;
 SELECT * INTO v_request FROM public.overtime_requests WHERE id=p_request FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Overtime request not found'; END IF;
 IF v_request.status<>'PENDING'
   AND NOT (p_status='CANCELLED' AND v_request.status='APPROVED' AND v_actor.role='ADMIN') THEN
   RAISE EXCEPTION 'Only pending OT or approved OT cancelled by Admin can be changed'; END IF;
 IF p_status='CANCELLED' THEN
   IF v_request.status='APPROVED' AND length(trim(coalesce(p_admin_note,'')))<3
     THEN RAISE EXCEPTION 'Cancelling approved OT requires an Admin reason'; END IF;
   IF p_actor<>v_request.staff_id AND v_actor.role<>'ADMIN' THEN
     RAISE EXCEPTION 'Only request owner or Admin can cancel pending OT'; END IF;
 ELSE
   IF v_actor.role<>'ADMIN' THEN
     RAISE EXCEPTION 'Admin approval required'; END IF;
   IF p_status='REJECTED' AND length(trim(coalesce(p_admin_note,'')))<3 THEN
     RAISE EXCEPTION 'Rejection requires a reason'; END IF;
 END IF;
 UPDATE public.overtime_requests SET
   status=p_status,decided_at=now(),decided_by=p_actor,
   admin_note=nullif(trim(coalesce(p_admin_note,'')),'')
 WHERE id=p_request;
 INSERT INTO public.audit_log(actor_staff_id,action,record_id,metadata)
  VALUES(p_actor,'OT_'||p_status,p_request::text,
   jsonb_build_object('staff_id',v_request.staff_id,'ot_date',v_request.ot_date,
     'ot_minutes',v_request.ot_minutes,'admin_note',p_admin_note));
 RETURN jsonb_build_object('ok',true,'status',p_status,'requestId',p_request);
END $$;

REVOKE EXECUTE ON FUNCTION public.submit_overtime_v2(uuid,date,time,time,text,text,uuid)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.submit_overtime_v2(uuid,date,time,time,text,text,uuid) TO service_role;
REVOKE EXECUTE ON FUNCTION public.change_overtime_status_v2(uuid,uuid,text,text)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.change_overtime_status_v2(uuid,uuid,text,text) TO service_role;

COMMIT;
