-- V2 Employee Management — install AFTER 001_foundation and 002_login_pgcrypto_search_path
-- Supports registration, profile edits (including Staff ID), resignation/reactivation,
-- resetting PINs, and deletion only when an account has no operational history.
ALTER TABLE public.staff ADD COLUMN IF NOT EXISTS employment_status text DEFAULT 'ACTIVE';
UPDATE public.staff SET employment_status=CASE WHEN active THEN 'ACTIVE' ELSE 'INACTIVE' END WHERE employment_status IS NULL;
ALTER TABLE public.staff ALTER COLUMN employment_status SET NOT NULL;
DO $block$
BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='staff_employment_status_check') THEN
   ALTER TABLE public.staff ADD CONSTRAINT staff_employment_status_check
     CHECK (employment_status IN ('ACTIVE','INACTIVE','RESIGNED'));
 END IF;
END
$block$;

CREATE OR REPLACE FUNCTION public.employee_create_v2(
  p_actor uuid,p_employee_id text,p_name text,p_position text,p_department text,p_pin text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,extensions AS $$
DECLARE v_staff uuid;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.staff WHERE id=p_actor AND role='ADMIN' AND active) THEN
    RAISE EXCEPTION 'Admin access required';
  END IF;
  IF upper(trim(coalesce(p_employee_id,''))) !~ '^[A-Z0-9_-]{2,32}$'
    OR length(trim(coalesce(p_name,'')))<2
    OR length(trim(coalesce(p_position,'')))<2
    OR length(trim(coalesce(p_department,'')))<2
    OR coalesce(p_pin,'') !~ '^[0-9]{8}$' THEN
      RAISE EXCEPTION 'Enter valid ID, name, position, department and an 8-digit PIN';
  END IF;
  INSERT INTO public.staff(employee_id,name,pin_hash,position,department,role,active,employment_status)
  VALUES (upper(trim(p_employee_id)),trim(p_name),crypt(p_pin,gen_salt('bf',12)),
    trim(p_position),trim(p_department),'STAFF',true,'ACTIVE')
  RETURNING id INTO v_staff;
  INSERT INTO public.audit_log(actor_staff_id,action,record_id,metadata)
  VALUES(p_actor,'CREATE_EMPLOYEE',v_staff::text,jsonb_build_object('employee_id',upper(trim(p_employee_id))));
  RETURN jsonb_build_object('ok',true,'staff_id',v_staff);
END $$;

CREATE OR REPLACE FUNCTION public.employee_update_v2(
  p_actor uuid,p_target uuid,p_employee_id text,p_name text,p_position text,p_department text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public AS $$
DECLARE v_old text; v_role text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.staff WHERE id=p_actor AND role='ADMIN' AND active) THEN
    RAISE EXCEPTION 'Admin access required';
  END IF;
  IF upper(trim(coalesce(p_employee_id,''))) !~ '^[A-Z0-9_-]{2,32}$'
    OR length(trim(coalesce(p_name,'')))<2
    OR length(trim(coalesce(p_position,'')))<2
    OR length(trim(coalesce(p_department,'')))<2 THEN
      RAISE EXCEPTION 'Enter valid employee details';
  END IF;
  SELECT employee_id,role INTO v_old,v_role FROM public.staff WHERE id=p_target FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Employee not found'; END IF;
  IF v_role='ADMIN' AND v_old<>upper(trim(p_employee_id)) THEN
    RAISE EXCEPTION 'Admin Employee ID cannot be changed here';
  END IF;
  UPDATE public.staff SET employee_id=upper(trim(p_employee_id)),name=trim(p_name),
     position=trim(p_position),department=trim(p_department) WHERE id=p_target;
  -- History is UUID-linked, so Leave, PH and OT follow the same staff record automatically.
  INSERT INTO public.audit_log(actor_staff_id,action,record_id,metadata)
  VALUES(p_actor,'UPDATE_EMPLOYEE',p_target::text,
     jsonb_build_object('old_id',v_old,'new_id',upper(trim(p_employee_id))));
  RETURN jsonb_build_object('ok',true);
END $$;

CREATE OR REPLACE FUNCTION public.employee_status_v2(
  p_actor uuid,p_target uuid,p_status text,p_last_working_date date,p_note text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public AS $$
DECLARE v_role text; v_old text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.staff WHERE id=p_actor AND role='ADMIN' AND active) THEN
    RAISE EXCEPTION 'Admin access required';
  END IF;
  IF p_actor=p_target THEN RAISE EXCEPTION 'Cannot deactivate your own account'; END IF;
  IF p_status NOT IN ('ACTIVE','INACTIVE','RESIGNED') THEN RAISE EXCEPTION 'Invalid status'; END IF;
  IF p_status='RESIGNED' AND p_last_working_date IS NULL THEN
    RAISE EXCEPTION 'Last working date required for resigned staff';
  END IF;
  SELECT role,employment_status INTO v_role,v_old FROM public.staff WHERE id=p_target FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Employee not found'; END IF;
  IF v_role='ADMIN' THEN RAISE EXCEPTION 'Administrator status must be managed separately'; END IF;
  UPDATE public.staff SET employment_status=p_status,active=(p_status='ACTIVE'),
     last_working_date=CASE WHEN p_status='RESIGNED' THEN p_last_working_date ELSE NULL END WHERE id=p_target;
  IF p_status<>'ACTIVE' THEN DELETE FROM public.staff_sessions WHERE staff_id=p_target; END IF;
  INSERT INTO public.audit_log(actor_staff_id,action,record_id,metadata)
  VALUES(p_actor,'SET_EMPLOYEE_STATUS',p_target::text,
     jsonb_build_object('from',v_old,'to',p_status,'last_working_date',p_last_working_date,
       'note',left(coalesce(p_note,''),500)));
  RETURN jsonb_build_object('ok',true);
END $$;

CREATE OR REPLACE FUNCTION public.employee_reset_pin_v2(
  p_actor uuid,p_target uuid,p_pin text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,extensions AS $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.staff WHERE id=p_actor AND role='ADMIN' AND active) THEN
    RAISE EXCEPTION 'Admin access required';
  END IF;
  IF coalesce(p_pin,'') !~ '^[0-9]{8}$' THEN RAISE EXCEPTION 'PIN must be exactly 8 digits'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.staff WHERE id=p_target) THEN RAISE EXCEPTION 'Employee not found'; END IF;
  UPDATE public.staff SET pin_hash=crypt(p_pin,gen_salt('bf',12)) WHERE id=p_target;
  DELETE FROM public.staff_sessions WHERE staff_id=p_target;
  INSERT INTO public.audit_log(actor_staff_id,action,record_id) VALUES(p_actor,'RESET_STAFF_PIN',p_target::text);
  RETURN jsonb_build_object('ok',true);
END $$;

CREATE OR REPLACE FUNCTION public.employee_change_own_pin_v2(
  p_actor uuid,p_old_pin text,p_new_pin text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,extensions AS $$
DECLARE v_hash text;
BEGIN
  IF coalesce(p_new_pin,'') !~ '^[0-9]{8}$' THEN RAISE EXCEPTION 'New PIN must be 8 digits'; END IF;
  SELECT pin_hash INTO v_hash FROM public.staff WHERE id=p_actor AND active FOR UPDATE;
  IF NOT FOUND OR v_hash <> crypt(coalesce(p_old_pin,''),v_hash) THEN RAISE EXCEPTION 'Current PIN incorrect'; END IF;
  IF p_new_pin=p_old_pin THEN RAISE EXCEPTION 'Choose a different PIN'; END IF;
  UPDATE public.staff SET pin_hash=crypt(p_new_pin,gen_salt('bf',12)) WHERE id=p_actor;
  DELETE FROM public.staff_sessions WHERE staff_id=p_actor;
  INSERT INTO public.audit_log(actor_staff_id,action,record_id) VALUES(p_actor,'CHANGE_OWN_PIN',p_actor::text);
  RETURN jsonb_build_object('ok',true);
END $$;

CREATE OR REPLACE FUNCTION public.employee_delete_unused_v2(
  p_actor uuid,p_target uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public AS $$
DECLARE v_role text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.staff WHERE id=p_actor AND role='ADMIN' AND active) THEN
    RAISE EXCEPTION 'Admin access required';
  END IF;
  IF p_actor=p_target THEN RAISE EXCEPTION 'Cannot delete own account'; END IF;
  SELECT role INTO v_role FROM public.staff WHERE id=p_target FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Employee not found'; END IF;
  IF v_role='ADMIN' THEN RAISE EXCEPTION 'Cannot delete admin account'; END IF;
  IF EXISTS(SELECT 1 FROM public.al_balances WHERE staff_id=p_target)
    OR EXISTS(SELECT 1 FROM public.ph_credits WHERE staff_id=p_target)
    OR EXISTS(SELECT 1 FROM public.leave_requests WHERE staff_id=p_target OR decided_by=p_target)
    OR EXISTS(SELECT 1 FROM public.leave_days WHERE staff_id=p_target)
    OR EXISTS(SELECT 1 FROM public.overtime_requests WHERE staff_id=p_target OR instructed_by=p_target)
    OR EXISTS(SELECT 1 FROM public.audit_log WHERE actor_staff_id=p_target) THEN
      RAISE EXCEPTION 'Employee has historical records. Mark Resigned instead.';
  END IF;
  DELETE FROM public.staff WHERE id=p_target;
  INSERT INTO public.audit_log(actor_staff_id,action,record_id) VALUES(p_actor,'DELETE_UNUSED_EMPLOYEE',p_target::text);
  RETURN jsonb_build_object('ok',true);
END $$;

REVOKE EXECUTE ON FUNCTION public.employee_create_v2(uuid,text,text,text,text,text) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.employee_update_v2(uuid,uuid,text,text,text,text) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.employee_status_v2(uuid,uuid,text,date,text) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.employee_reset_pin_v2(uuid,uuid,text) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.employee_change_own_pin_v2(uuid,text,text) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.employee_delete_unused_v2(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.employee_create_v2(uuid,text,text,text,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.employee_update_v2(uuid,uuid,text,text,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.employee_status_v2(uuid,uuid,text,date,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.employee_reset_pin_v2(uuid,uuid,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.employee_change_own_pin_v2(uuid,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.employee_delete_unused_v2(uuid,uuid) TO service_role;
