-- SKYBAR STAFF MANAGEMENT V2 — 009 V1.7 OVERTIME FEATURE PARITY
-- Restores OT Approver management, duplicate-OT protection, and approved-OT Admin correction.
-- Requires migration 007; does NOT change the 2027-01-01 go-live lock.
BEGIN;
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
