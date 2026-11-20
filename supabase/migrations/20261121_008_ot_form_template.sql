-- SkyBar Staff Management V2 — 008 Editable HR OT Form Template
-- Run AFTER 001-007, only in approved database.
-- Admin uploads one source-matched .xlsx template (macro-free).
-- Server authenticates all reads; staff receive template only through Edge session.
BEGIN;
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
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $
DECLARE v_name text;v_bytes bytea;
BEGIN
 SELECT filename,file_bytes INTO v_name,v_bytes
 FROM public.ot_form_templates WHERE id=1;
 IF NOT FOUND THEN RAISE EXCEPTION 'OT form template not configured. Ask Admin to upload the approved .xlsx template'; END IF;
 RETURN jsonb_build_object('filename',v_name,'base64',encode(v_bytes,'base64'));
END $;

REVOKE EXECUTE ON FUNCTION public.get_ot_form_v2()
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_ot_form_v2() TO service_role;

REVOKE EXECUTE ON FUNCTION public.admin_set_ot_form_v2(uuid,text,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_ot_form_v2(uuid,text,text) TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.ot_form_templates TO service_role;
COMMIT;
