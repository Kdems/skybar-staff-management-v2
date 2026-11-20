-- SKYBAR STAFF MANAGEMENT V2 — FOUNDATION
-- Fresh Supabase project only. Run in SQL Editor after reviewing the file.
-- All privileged RPCs are restricted to service_role; no browser-held database secrets.
create extension if not exists pgcrypto;

create table if not exists public.staff (
  id uuid primary key default gen_random_uuid(),
  employee_id text unique not null check (length(employee_id) between 2 and 32),
  name text not null,
  pin_hash text not null,
  position text not null default 'Staff',
  department text not null default 'SkyBar',
  role text not null default 'STAFF' check (role in ('STAFF','ADMIN')),
  active boolean not null default true,
  last_working_date date,
  created_at timestamptz not null default now()
);
create table if not exists public.staff_sessions (
  token_hash text primary key,
  staff_id uuid not null references public.staff(id) on delete cascade,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index if not exists idx_staff_sessions_expiry on public.staff_sessions(expires_at);
create table if not exists public.login_attempts (
  id bigint generated always as identity primary key,
  employee_id text not null,
  attempted_at timestamptz not null default now()
);
create index if not exists idx_login_attempts_lookup on public.login_attempts(employee_id,attempted_at);

create table if not exists public.al_balances (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff(id),
  source_year integer not null check (source_year between 2020 and 2100),
  entitlement numeric(8,2) not null default 0,
  carry_forward numeric(8,2) not null default 0,
  adjustment numeric(8,2) not null default 0,
  notes text,
  unique (staff_id,source_year)
);
create table if not exists public.ph_credits (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff(id),
  source_year integer not null check (source_year between 2020 and 2100),
  holiday_name text not null,
  holiday_date date,
  units numeric(8,2) not null check (units>0),
  release_mode text not null default 'AUTO_DATE' check (release_mode in ('AUTO_DATE','MANUAL')),
  active boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  check (release_mode <> 'AUTO_DATE' or holiday_date is not null)
);
create table if not exists public.leave_requests (
  id uuid primary key default gen_random_uuid(),
  request_code text unique not null,
  staff_id uuid not null references public.staff(id),
  leave_type text not null check (leave_type in ('AL','PH','EL')),
  duration text not null check (duration in ('FULL','HALF_AM','HALF_PM')),
  start_date date not null,
  end_date date not null,
  units numeric(8,2) not null check (units>0),
  reason text not null,
  status text not null default 'PENDING' check (status in ('PENDING','APPROVED','REJECTED','CANCELLED')),
  submitted_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references public.staff(id),
  admin_note text,
  check (end_date>=start_date)
);
create table if not exists public.leave_days (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.leave_requests(id) on delete cascade,
  staff_id uuid not null references public.staff(id),
  leave_date date not null,
  status text not null check (status in ('PENDING','APPROVED','REJECTED','CANCELLED')),
  unique(request_id,leave_date)
);
create index if not exists idx_leave_days_calendar on public.leave_days(leave_date,status);
create table if not exists public.ph_usage (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.leave_requests(id) on delete cascade,
  credit_id uuid not null references public.ph_credits(id),
  units numeric(8,2) not null check (units>0)
);
create table if not exists public.overtime_requests (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff(id),
  ot_date date not null,
  shift_start time not null,
  shift_end time not null,
  total_shift_minutes integer not null check (total_shift_minutes>0 and total_shift_minutes<=1440),
  ot_minutes integer not null check (ot_minutes>0),
  claim_type text not null check (claim_type in ('NORMAL','OFF','PH')),
  reason text not null,
  instructed_by uuid references public.staff(id),
  status text not null default 'PENDING' check (status in ('PENDING','APPROVED','REJECTED','CANCELLED')),
  created_at timestamptz not null default now()
);
create table if not exists public.audit_log (
  id bigint generated always as identity primary key,
  actor_staff_id uuid references public.staff(id),
  action text not null,
  record_id text,
  metadata jsonb,
  created_at timestamptz not null default now()
);

-- RLS: no anon/authenticated policies. Only server-side service_role can access.
alter table public.staff enable row level security;
alter table public.staff_sessions enable row level security;
alter table public.login_attempts enable row level security;
alter table public.al_balances enable row level security;
alter table public.ph_credits enable row level security;
alter table public.leave_requests enable row level security;
alter table public.leave_days enable row level security;
alter table public.ph_usage enable row level security;
alter table public.overtime_requests enable row level security;
alter table public.audit_log enable row level security;

create or replace function public.login_staff(p_employee_id text,p_pin text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_staff public.staff%rowtype; v_count int;
begin
  if p_employee_id is null or length(p_employee_id)>32 or p_pin !~ '^[0-9]{6,8}$' then
    raise exception 'Invalid Employee ID or PIN';
  end if;
  perform pg_advisory_xact_lock(hashtext('login:'||upper(p_employee_id)));
  select count(*) into v_count from public.login_attempts
   where employee_id=upper(p_employee_id) and attempted_at>now()-interval '15 minutes';
  if v_count>=8 then raise exception 'Too many attempts. Try again later'; end if;
  insert into public.login_attempts(employee_id) values(upper(p_employee_id));
  select * into v_staff from public.staff where employee_id=upper(p_employee_id) and active;
  if not found or v_staff.pin_hash<>crypt(p_pin,v_staff.pin_hash) then
    raise exception 'Invalid Employee ID or PIN';
  end if;
  delete from public.login_attempts where employee_id=upper(p_employee_id);
  return jsonb_build_object('id',v_staff.id,'employee_id',v_staff.employee_id,
    'name',v_staff.name,'position',v_staff.position,'role',v_staff.role);
end $$;

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
    from public.al_balances where staff_id=p_staff_id and source_year<=extract(year from v_today);
    select v_available-coalesce(sum(units),0) into v_available from public.leave_requests
      where staff_id=p_staff_id and leave_type='AL' and status in ('PENDING','APPROVED');
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

create or replace function public.change_leave_status_v2(p_actor uuid,p_request uuid,p_status text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_staff uuid;v_status text;
begin
  if p_status not in ('APPROVED','REJECTED','CANCELLED') then raise exception 'Invalid status'; end if;
  perform pg_advisory_xact_lock(20270101);
  select staff_id,status into v_staff,v_status from public.leave_requests where id=p_request for update;
  if not found then raise exception 'Request not found'; end if;
  if p_status='CANCELLED' then
    if (p_actor<>v_staff and not exists(select 1 from public.staff where id=p_actor and role='ADMIN' and active))
       or v_status<>'PENDING' then raise exception 'Cannot cancel this request'; end if;
  else
    if not exists(select 1 from public.staff where id=p_actor and role='ADMIN' and active) or v_status<>'PENDING'
      then raise exception 'Only admins may approve or reject pending requests'; end if;
  end if;
  update public.leave_requests set status=p_status,decided_at=now(),decided_by=p_actor where id=p_request;
  update public.leave_days set status=p_status where request_id=p_request;
  insert into public.audit_log(actor_staff_id,action,record_id) values(p_actor,p_status||'_LEAVE',p_request::text);
  return jsonb_build_object('ok',true);
end $$;

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
  v_minutes:=round(extract(epoch from (p_end-p_start))/60)::integer;
  if v_minutes<=0 then v_minutes:=v_minutes+1440; end if;
  if v_minutes<=540 then raise exception 'No OT after 9 working hours'; end if;
  if p_approver is not null and not exists(select 1 from public.staff where id=p_approver and role='ADMIN' and active) then
    raise exception 'Invalid approver'; end if;
  insert into public.overtime_requests(staff_id,ot_date,shift_start,shift_end,
    total_shift_minutes,ot_minutes,claim_type,reason,instructed_by)
    values(p_staff_id,p_date,p_start,p_end,v_minutes,v_minutes-540,p_claim_type,trim(p_reason),p_approver)
    returning id into v_id;
  insert into public.audit_log(actor_staff_id,action,record_id) values(p_staff_id,'SUBMIT_OT',v_id::text);
  return jsonb_build_object('requestId',v_id,'hours',(v_minutes-540)/60.0);
end $$;

-- Restrict all privileged RPCs to server-side service role.
revoke execute on function public.login_staff(text,text) from public,anon,authenticated;
revoke execute on function public.submit_leave_v2(uuid,text,text,date,date,text,text) from public,anon,authenticated;
revoke execute on function public.change_leave_status_v2(uuid,uuid,text) from public,anon,authenticated;
revoke execute on function public.submit_overtime_v2(uuid,date,time,time,text,text,uuid) from public,anon,authenticated;
grant execute on function public.login_staff(text,text) to service_role;
grant execute on function public.submit_leave_v2(uuid,text,text,date,date,text,text) to service_role;
grant execute on function public.change_leave_status_v2(uuid,uuid,text) to service_role;
grant execute on function public.submit_overtime_v2(uuid,date,time,time,text,text,uuid) to service_role;

-- ADMIN BOOTSTRAP (run separately, after changing both placeholders).
-- Choose a private 8-digit PIN. Do not commit your actual PIN to GitHub.
-- insert into public.staff(employee_id,name,pin_hash,position,role)
-- values ('ADMIN001','System Admin',crypt('REPLACE_WITH_PRIVATE_8_DIGIT_PIN',gen_salt('bf',12)),'Outlet Manager','ADMIN');
