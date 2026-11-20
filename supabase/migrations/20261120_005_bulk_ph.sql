-- SkyBar Staff Management V2 — 005 Bulk PH Allocation
-- Depends on migrations 001–004.
-- Never delete any existing PH credits. Existing single-staff records remain intact.
-- Both RPCs require an active ADMIN actor and may only be called using service_role.

ALTER TABLE public.ph_credits ADD COLUMN IF NOT EXISTS bulk_key text;
CREATE UNIQUE INDEX IF NOT EXISTS ph_credits_staff_bulk_key_uq
  ON public.ph_credits (staff_id,bulk_key) WHERE bulk_key IS NOT NULL;

CREATE OR REPLACE FUNCTION public.admin_apply_ph_schedule_v2(
 p_actor uuid, p_year integer, p_staff_ids uuid[], p_holidays jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
 v_ids uuid[]; v_unique_count integer; v_item jsonb; v_staff uuid;
 v_name text; v_date date; v_units numeric; v_key text; v_seen text[] := ARRAY[]::text[];
 v_existing public.ph_credits%ROWTYPE;
 v_created integer := 0; v_skipped integer := 0;
BEGIN
 IF NOT EXISTS (SELECT 1 FROM public.staff WHERE id=p_actor AND role='ADMIN' AND active)
   THEN RAISE EXCEPTION 'Admin access required'; END IF;
 IF p_year IS NULL OR p_year<2020 OR p_year>2100
   THEN RAISE EXCEPTION 'Invalid source year'; END IF;
 IF COALESCE(cardinality(p_staff_ids),0)<1 OR cardinality(p_staff_ids)>100
   THEN RAISE EXCEPTION 'Choose 1 to 100 active staff'; END IF;
 IF jsonb_typeof(p_holidays) IS DISTINCT FROM 'array'
    OR jsonb_array_length(p_holidays)<1 OR jsonb_array_length(p_holidays)>40
   THEN RAISE EXCEPTION 'Enter between 1 and 40 PH dates'; END IF;
 SELECT count(*) INTO v_unique_count FROM (SELECT DISTINCT unnest(p_staff_ids) AS id) q;
 SELECT coalesce(array_agg(DISTINCT id),ARRAY[]::uuid[]) INTO v_ids
   FROM public.staff WHERE id=ANY(p_staff_ids) AND active AND role='STAFF';
 IF cardinality(v_ids)<>v_unique_count
   THEN RAISE EXCEPTION 'Some selected staff are missing, inactive, or not staff accounts'; END IF;

 -- Validate every holiday BEFORE writing any credit.
 FOR v_item IN SELECT value FROM jsonb_array_elements(p_holidays) LOOP
   IF jsonb_typeof(v_item) IS DISTINCT FROM 'object'
      THEN RAISE EXCEPTION 'Invalid holiday record'; END IF;
   v_name:=trim(coalesce(v_item->>'name',''));
   IF length(v_name)<2 OR length(v_name)>160
     THEN RAISE EXCEPTION 'Each PH needs a holiday name (2-160 characters)'; END IF;
   IF v_item->>'date' IS NULL OR v_item->>'date' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
     THEN RAISE EXCEPTION 'Each PH needs a date in YYYY-MM-DD format'; END IF;
   v_date:=(v_item->>'date')::date;
   IF extract(year FROM v_date)::integer<>p_year
     THEN RAISE EXCEPTION 'PH % date must be in %',v_name,p_year; END IF;
   IF v_item->>'units' IS NULL THEN RAISE EXCEPTION 'PH units are required'; END IF;
   v_units:=(v_item->>'units')::numeric;
   IF v_units<0.5 OR v_units>3 OR v_units*2<>trunc(v_units*2)
     THEN RAISE EXCEPTION 'PH units must be 0.5-3 in half-day steps'; END IF;
   v_key:='DATED:'||v_date::text||':'||lower(v_name);
   IF v_key=ANY(v_seen) THEN RAISE EXCEPTION 'Duplicate PH in schedule: %',v_name; END IF;
   v_seen:=array_append(v_seen,v_key);
 END LOOP;

 -- Serialize with submit_leave_v2, PH edits and the historical balance batch.
 PERFORM pg_advisory_xact_lock(20270101);
 FOREACH v_staff IN ARRAY v_ids LOOP
   FOR v_item IN SELECT value FROM jsonb_array_elements(p_holidays) LOOP
     v_name:=trim(v_item->>'name');
     v_date:=(v_item->>'date')::date;
     v_units:=(v_item->>'units')::numeric;
     v_key:='DATED:'||v_date::text||':'||lower(v_name);
     -- Also recognize credits created using the original individual-PH workflow.
     SELECT * INTO v_existing FROM public.ph_credits
       WHERE staff_id=v_staff AND source_year=p_year AND holiday_date=v_date
       AND lower(holiday_name)=lower(v_name) AND release_mode='AUTO_DATE'
       ORDER BY created_at LIMIT 1 FOR UPDATE;
     IF FOUND THEN
       IF v_existing.units<>v_units THEN
         RAISE EXCEPTION 'Existing PH % on % has % units; edit it in the ledger before retrying',
            v_name,v_date,v_existing.units;
       END IF;
       v_skipped:=v_skipped+1;
     ELSE
       INSERT INTO public.ph_credits
         (staff_id,source_year,holiday_name,holiday_date,units,release_mode,active,notes,bulk_key)
       VALUES(v_staff,p_year,v_name,v_date,v_units,'AUTO_DATE',true,
              'Bulk PH schedule — admin confirmed date',v_key);
       v_created:=v_created+1;
     END IF;
   END LOOP;
 END LOOP;
 INSERT INTO public.audit_log(actor_staff_id,action,metadata)
   VALUES(p_actor,'BULK_PH_SCHEDULE',jsonb_build_object(
     'year',p_year,'staff_count',cardinality(v_ids),'holiday_count',jsonb_array_length(p_holidays),
     'created',v_created,'skipped_existing',v_skipped));
 RETURN jsonb_build_object('ok',true,'staffCount',cardinality(v_ids),
   'holidayCount',jsonb_array_length(p_holidays),'created',v_created,'skipped',v_skipped);
END $$;

CREATE OR REPLACE FUNCTION public.admin_save_ph_opening_balances_v2(
 p_actor uuid, p_year integer, p_balances jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
 v_today date:=(now() AT TIME ZONE 'Asia/Kuala_Lumpur')::date;
 v_item jsonb; v_staff uuid; v_units numeric; v_key text; v_title text;
 v_record public.ph_credits%ROWTYPE; v_existing_usage numeric;
 v_seen uuid[] := ARRAY[]::uuid[]; v_updated integer:=0; v_added integer:=0;
 v_inactive integer:=0; v_skipped integer:=0;
BEGIN
 IF NOT EXISTS (SELECT 1 FROM public.staff WHERE id=p_actor AND role='ADMIN' AND active)
   THEN RAISE EXCEPTION 'Admin access required'; END IF;
 IF p_year IS NULL OR p_year<2020 OR p_year>extract(year FROM v_today)::integer
   THEN RAISE EXCEPTION 'Historical PH balance cannot be recorded for a future year'; END IF;
 IF jsonb_typeof(p_balances) IS DISTINCT FROM 'array' OR
    jsonb_array_length(p_balances)<1 OR jsonb_array_length(p_balances)>100
   THEN RAISE EXCEPTION 'Select between 1 and 100 staff'; END IF;
 v_key:='OPENING:'||p_year::text;
 v_title:='Opening PH Balance '||p_year::text;
 PERFORM pg_advisory_xact_lock(20270101);
 FOR v_item IN SELECT value FROM jsonb_array_elements(p_balances) LOOP
   IF jsonb_typeof(v_item) IS DISTINCT FROM 'object' THEN
     RAISE EXCEPTION 'Invalid PH opening balance entry'; END IF;
   v_staff:=(v_item->>'staffId')::uuid;
   IF v_staff=ANY(v_seen) THEN RAISE EXCEPTION 'Same staff supplied more than once'; END IF;
   v_seen:=array_append(v_seen,v_staff);
   IF NOT EXISTS(SELECT 1 FROM public.staff WHERE id=v_staff AND active AND role='STAFF')
     THEN RAISE EXCEPTION 'Historical PH balances require active staff accounts'; END IF;
   IF v_item->>'units' IS NULL THEN RAISE EXCEPTION 'Enter opening balance for every selected staff'; END IF;
   v_units:=(v_item->>'units')::numeric;
   IF v_units<0 OR v_units>30 OR v_units*2<>trunc(v_units*2)
     THEN RAISE EXCEPTION 'Historical PH balance must be 0-30 days, in half-day steps'; END IF;

   SELECT * INTO v_record FROM public.ph_credits WHERE staff_id=v_staff AND bulk_key=v_key
     FOR UPDATE;
   IF NOT FOUND THEN
     SELECT * INTO v_record FROM public.ph_credits
       WHERE staff_id=v_staff AND source_year=p_year AND holiday_name=v_title
         AND release_mode='MANUAL'
       ORDER BY created_at LIMIT 1 FOR UPDATE;
   END IF;
   IF v_units=0 THEN
     IF NOT FOUND THEN
       v_skipped:=v_skipped+1;
     ELSE
       IF EXISTS(SELECT 1 FROM public.ph_usage WHERE credit_id=v_record.id) THEN
         RAISE EXCEPTION 'Cannot zero an opening balance with PH usage history. Edit it individually.';
       END IF;
       UPDATE public.ph_credits SET active=false, bulk_key=v_key WHERE id=v_record.id;
       v_inactive:=v_inactive+1;
     END IF;
   ELSIF FOUND THEN
     SELECT coalesce(sum(u.units),0) INTO v_existing_usage
       FROM public.ph_usage u JOIN public.leave_requests r ON r.id=u.request_id
       WHERE u.credit_id=v_record.id AND r.status IN ('PENDING','APPROVED');
     IF v_units<v_existing_usage THEN
       RAISE EXCEPTION 'Cannot reduce opening PH below already reserved units'; END IF;
     UPDATE public.ph_credits SET units=v_units,active=true,bulk_key=v_key,
       notes='Approved historical PH opening balance; as-of year '
         ||p_year::text
       WHERE id=v_record.id;
     v_updated:=v_updated+1;
   ELSE
     INSERT INTO public.ph_credits
       (staff_id,source_year,holiday_name,holiday_date,units,release_mode,active,notes,bulk_key)
     VALUES(v_staff,p_year,v_title,
       CASE WHEN p_year=extract(year FROM v_today)::integer THEN v_today ELSE NULL END,
       v_units,'MANUAL',true,
       'Approved historical PH opening balance. For current year, date is allocation as-of date, NOT holiday date.',
       v_key);
     v_added:=v_added+1;
   END IF;
 END LOOP;
 INSERT INTO public.audit_log(actor_staff_id,action,metadata)
   VALUES(p_actor,'BULK_PH_OPENING',jsonb_build_object(
     'year',p_year,'staff_count',cardinality(v_seen),
     'created',v_added,'updated',v_updated,'deactivated',v_inactive,'skipped',v_skipped));
 RETURN jsonb_build_object('ok',true,'staffCount',cardinality(v_seen),
   'created',v_added,'updated',v_updated,'deactivated',v_inactive,'skipped',v_skipped);
END $$;

REVOKE EXECUTE ON FUNCTION public.admin_apply_ph_schedule_v2(uuid,integer,uuid[],jsonb)
  FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_save_ph_opening_balances_v2(uuid,integer,jsonb)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.admin_apply_ph_schedule_v2(uuid,integer,uuid[],jsonb)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_save_ph_opening_balances_v2(uuid,integer,jsonb)
  TO service_role;
