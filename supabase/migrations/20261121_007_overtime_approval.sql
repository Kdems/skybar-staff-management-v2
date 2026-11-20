-- SkyBar Staff Management V2 — 007 Overtime Approval and Cancellation
-- Apply AFTER 001–006. Live submissions remain locked until 1 January 2027.
BEGIN;
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
COMMIT;
