// Supabase Edge Function: staff-api
// Deploy with verify_jwt=false. All access is authenticated with a hashed, server-side staff session.
// Never return or log SUPABASE_SERVICE_ROLE_KEY.
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const URL = Deno.env.get("SUPABASE_URL") || "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
// Exact browser origins allowed to call the API. No wildcard for a staff management app.
const DEFAULT_ALLOWED_ORIGINS = [
  "https://kdems.github.io",
  "https://skybar-staff-management-v2.texas-boiler.workers.dev"
];
const extraOrigin = (Deno.env.get("SKYBAR_ALLOWED_ORIGIN") || "").trim().replace(new RegExp("/+$"), "");
const ALLOWED = [...new Set([...DEFAULT_ALLOWED_ORIGINS, extraOrigin].filter(Boolean))];

class ApiError extends Error {
  constructor(message: string, readonly code=400) { super(message); }
}
function cors(origin: string | null) {
  const approved=origin && ALLOWED.includes(origin) ? origin : ALLOWED[0];
  return {
    "Access-Control-Allow-Origin": approved,
    "Access-Control-Allow-Headers": "authorization,content-type",
    "Access-Control-Allow-Methods": "POST,OPTIONS",
    "Vary": "Origin",
    "Content-Type": "application/json; charset=utf-8"
  };
}
function json(body: unknown,status=200,origin: string | null=null) {
  return new Response(JSON.stringify(body),{status,headers:cors(origin)});
}
async function request(path:string,method="GET",data?:unknown):Promise<any>{
  if(!URL||!SERVICE_KEY)throw new ApiError("Supabase service configuration missing",503);
  const response=await fetch(URL+"/rest/v1/"+path,{
    method,
    headers:{"apikey":SERVICE_KEY,"Authorization":"Bearer "+SERVICE_KEY,"Content-Type":"application/json",
      "Prefer":"return=representation"},
    ...(data!==undefined?{body:JSON.stringify(data)}:{})
  });
  const raw=await response.text();
  let body:any;try{body=raw?JSON.parse(raw):null}catch{body=null}
  if(!response.ok){
    const detail=String(body?.message||body?.hint||"Database request failed");
    if(response.status>=500)throw new ApiError("Database is temporarily unavailable",503);
    throw new ApiError(detail,response.status===401||response.status===403?403:400);
  }
  return body;
}
async function rpc(name:string,payload:unknown){return request("rpc/"+name,"POST",payload)}
async function sha256(value:string){
  const buffer=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(value));
  return Array.from(new Uint8Array(buffer)).map(x=>x.toString(16).padStart(2,"0")).join("");
}
function id(){return crypto.randomUUID()}
function tokenValue(){const bytes=crypto.getRandomValues(new Uint8Array(32));return Array.from(bytes).map(x=>x.toString(16).padStart(2,"0")).join("")}
type Staff = {id:string;employee_id:string;name:string;position:string;department:string;role:string;active:boolean};
async function authenticate(req:Request):Promise<Staff>{
  const token=(req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"").trim();
  if(!/^[a-f0-9]{64}$/.test(token))throw new ApiError("Session expired. Please sign in again.",401);
  const rows=await request("staff_sessions?token_hash=eq."+encodeURIComponent(await sha256(token))+"&expires_at=gt."+encodeURIComponent(new Date().toISOString())+"&select=staff_id&limit=1");
  if(!rows.length)throw new ApiError("Session expired. Please sign in again.",401);
  const people=await request("staff?id=eq."+encodeURIComponent(rows[0].staff_id)+"&active=eq.true&select=id,employee_id,name,position,department,role,active&limit=1");
  if(!people.length)throw new ApiError("Account is inactive.",403);
  return people[0];
}
async function login(payload:any){
  const employeeId=String(payload.employeeId||"").trim().toUpperCase();
  const pin=String(payload.pin||"");
  if(!/^[A-Z0-9_-]{2,32}$/.test(employeeId)||!/^[0-9]{6,8}$/.test(pin))throw new ApiError("Invalid Employee ID or PIN");
  const recent=await request("login_attempts?employee_id=eq."+encodeURIComponent(employeeId)+"&attempted_at=gt."+encodeURIComponent(new Date(Date.now()-15*60000).toISOString())+"&select=id&limit=8");
  if(recent.length>=8)throw new ApiError("Too many attempts. Try again later",429);
  let u:any;
  try{u=await rpc("login_staff",{p_employee_id:employeeId,p_pin:pin});}
  catch(e){await request("login_attempts","POST",[{employee_id:employeeId}]);throw new ApiError("Invalid Employee ID or PIN",401);}
  if(!u?.id)throw new ApiError("Invalid Employee ID or PIN",401);
  const token=tokenValue();
  await request("staff_sessions","POST",[{
    token_hash:await sha256(token),
    staff_id:u.id,
    expires_at:new Date(Date.now()+12*3600*1000).toISOString()
  }]);
  return {token,user:u};
}
function localDate(){
  return new Intl.DateTimeFormat("en-CA",{timeZone:"Asia/Kuala_Lumpur",year:"numeric",month:"2-digit",day:"2-digit"}).format(new Date());
}
async function bootstrap(staff:Staff){
  const prefix=localDate().slice(0,7);
  const year=Number(prefix.slice(0,4));
  const [als,credits,requests,days,ots,approvers]=await Promise.all([
    request("al_balances?staff_id=eq."+staff.id+"&source_year=eq."+year+"&select=entitlement,carry_forward,adjustment"),
    request("ph_credits?staff_id=eq."+staff.id+"&active=eq.true&select=id,units,release_mode,holiday_date,source_year"),
    request("leave_requests?staff_id=eq."+staff.id+"&select=id,leave_type,duration,start_date,end_date,units,status,reason,request_code,admin_note&order=submitted_at.desc&limit=150"),
    request("leave_days?leave_date=gte."+prefix+"-01&leave_date=lt."+nextMonth(prefix)+"-01&status=in.(PENDING,APPROVED)&select=leave_date,status,staff_id"),
    request("overtime_requests?staff_id=eq."+staff.id+"&select=id,ot_date,shift_start,shift_end,total_shift_minutes,ot_minutes,claim_type,reason,instructed_by,status,admin_note,decided_at,created_at&order=created_at.desc&limit=150"),
    request("staff?active=eq.true&role=eq.ADMIN&select=id,employee_id,name,position")
  ]);
  // AL uses the selected calendar year's allocation only, including its explicit carry-forward.
  const alGranted=als.reduce((n:number,r:any)=>n+Number(r.entitlement)+Number(r.carry_forward)+Number(r.adjustment),0);
  // Query ALL reserved AL requests (not just the last 150 shown in the UI).
  const alReserved=await request("leave_requests?staff_id=eq."+staff.id+"&leave_type=eq.AL&status=in.(PENDING,APPROVED)&start_date=gte."+year+"-01-01&start_date=lt."+(year+1)+"-01-01&select=units");
  const alUsed=alReserved.reduce((n:number,r:any)=>n+Number(r.units),0);
  // Include all active requests across the database for PH credit consumption, not just the last 150.
  const usage=credits.length ? await request("ph_usage?credit_id=in.("+credits.map((c:any)=>c.id).join(",")+")&select=credit_id,units,leave_requests!inner(status)") : [];
  const sums=new Map<string,number>();
  for(const u of usage){if(["PENDING","APPROVED"].includes(u.leave_requests?.status))sums.set(u.credit_id,(sums.get(u.credit_id)||0)+Number(u.units))}
  const today=localDate();
  let ph=0,locked=0;
  credits.forEach((c:any)=>{
    const remainder=Math.max(0,Number(c.units)-(sums.get(c.id)||0));
    if(c.release_mode==="MANUAL"||c.holiday_date<=today)ph+=remainder;else locked+=remainder;
  });
  const byDate:Record<string,unknown[]>={};
  // Resolve employee names from records by explicit lookup; never expose reasons.
  const dayStaffIds=[...new Set(days.map((d:any)=>d.staff_id))];
  let personNames=new Map<string,string>();
  if(dayStaffIds.length){
    const list=await request("staff?id=in.("+dayStaffIds.join(",")+")&select=id,name");
    personNames=new Map(list.map((x:any)=>[x.id,x.name]));
  }
  days.forEach((d:any)=>{
    (byDate[d.leave_date]??=[]).push({employee_name:personNames.get(d.staff_id)||"Staff",status:d.status});
  });
  let admin:any={};
  if(staff.role==="ADMIN"){
    const [employees,pending,alAllocations,phCredits,adminPhUsage,allLeaves,allOt]=await Promise.all([
      request("staff?select=id,employee_id,name,position,department,role,active,employment_status,last_working_date&order=name.asc"),
      request("leave_requests?status=eq.PENDING&select=id,staff_id,leave_type,start_date,end_date,reason,units&order=submitted_at.asc"),
      request("al_balances?select=id,staff_id,source_year,entitlement,carry_forward,adjustment,notes&order=source_year.desc"),
      request("ph_credits?select=id,staff_id,source_year,holiday_name,holiday_date,units,release_mode,active,notes,bulk_key&order=source_year.desc,holiday_date.asc.nullslast"),
      request("ph_usage?select=credit_id,units,leave_requests!inner(status)"),
      request("leave_requests?select=id,staff_id,request_code,leave_type,duration,start_date,end_date,units,status,reason,admin_note,submitted_at&order=submitted_at.desc&limit=400"),
      request("overtime_requests?select=id,staff_id,ot_date,shift_start,shift_end,total_shift_minutes,ot_minutes,claim_type,reason,instructed_by,status,admin_note,decided_at,created_at&order=created_at.desc&limit=500")
    ]);
    const names=new Map(employees.map((e:any)=>[e.id,e.name]));
    const usedByCredit=new Map<string,number>();
    for(const u of adminPhUsage){
      if(["PENDING","APPROVED"].includes(u.leave_requests?.status))
        usedByCredit.set(u.credit_id,(usedByCredit.get(u.credit_id)||0)+Number(u.units));
    }
    admin={
      employees,
      pending:pending.map((r:any)=>({...r,employee_name:names.get(r.staff_id)||"Staff"})),
      adminLeaves:allLeaves.map((r:any)=>({...r,employee_name:names.get(r.staff_id)||"Staff"})),
      adminOt:allOt.map((r:any)=>({...r,employee_name:names.get(r.staff_id)||"Staff"})),
      alAllocations,
      phCredits:phCredits.map((p:any)=>({...p,reservedUnits:usedByCredit.get(p.id)||0}))
    };
  }
  return {user:staff,data:{
    balances:{al:Math.max(0,alGranted-alUsed),ph,locked},
    calendar:byDate,requests,ot:ots,approvers:approvers.map((a:any)=>({employee_id:a.id,name:a.name})),
    ...admin
  }};
}

async function fetchRowsPaged(resource:string,select:string,order:string){
 const result:any[]=[];
 for(let offset=0;offset<5000;offset+=1000){
  const page=await request(resource+"?select="+select+"&order="+order+"&limit=1000&offset="+offset);
  result.push(...page);
  if(page.length<1000)return result;
 }
 throw new ApiError("Report exceeds 5,000 records; narrow reporting period before export",400);
}
async function adminReportData(report:string){
 const kind=String(report||"").toLowerCase();
 if(!["leave","ot","staff","al","ph","audit"].includes(kind))throw new ApiError("Invalid report");
 const base=await fetchRowsPaged("staff","id,employee_id,name,position,department,role,employment_status,active","name.asc");
 const people=new Map(base.map((x:any)=>[x.id,x]));
 const person=(id:string)=>people.get(id)||{};
 if(kind==="staff")return{
  columns:["Employee ID","Name","Position","Department","Role","Employment Status","Active"],
  rows:base.map((x:any)=>[x.employee_id,x.name,x.position,x.department,x.role,x.employment_status||"",x.active?"YES":"NO"])
 };
 if(kind==="leave"){
  const rr=await fetchRowsPaged("leave_requests",
   "request_code,staff_id,leave_type,duration,start_date,end_date,units,status,reason,admin_note,submitted_at,decided_at",
   "submitted_at.desc");
  return {columns:["Request Ref","Staff ID","Employee","Type","Duration","Start","End","Days","Status","Reason","Admin Note","Submitted","Decided"],
  rows:rr.map((x:any)=>[x.request_code,person(x.staff_id).employee_id||"",person(x.staff_id).name||"",x.leave_type,
    x.duration,x.start_date,x.end_date,x.units,x.status,x.reason,x.admin_note||"",x.submitted_at,x.decided_at||""])};
 }
 if(kind==="ot"){
  const rr=await fetchRowsPaged("overtime_requests",
   "staff_id,ot_date,shift_start,shift_end,total_shift_minutes,ot_minutes,claim_type,status,reason,admin_note,created_at,decided_at",
   "created_at.desc");
  return {columns:["Staff ID","Employee","OT Date","Shift Start","Shift End","Total Shift Hours","OT Hours","Claim Type","Status","Reason","Admin Note","Submitted","Decided"],
   rows:rr.map((x:any)=>[person(x.staff_id).employee_id||"",person(x.staff_id).name||"",x.ot_date,x.shift_start,
   x.shift_end,Number(x.total_shift_minutes)/60,Number(x.ot_minutes)/60,x.claim_type,x.status,x.reason,x.admin_note||"",x.created_at,x.decided_at||""])};
 }
 if(kind==="al"){
  const rr=await fetchRowsPaged("al_balances","staff_id,source_year,entitlement,carry_forward,adjustment,notes","source_year.desc");
  return {columns:["Staff ID","Employee","Year","Entitlement","Carry Forward","Adjustment","Allocated Total","Notes"],
   rows:rr.map((x:any)=>[person(x.staff_id).employee_id||"",person(x.staff_id).name||"",x.source_year,
   x.entitlement,x.carry_forward,x.adjustment,Number(x.entitlement)+Number(x.carry_forward)+Number(x.adjustment),x.notes||""])};
 }
 if(kind==="ph"){
  const rr=await fetchRowsPaged("ph_credits","staff_id,source_year,holiday_name,holiday_date,units,release_mode,active,notes","source_year.desc");
  return {columns:["Staff ID","Employee","Source Year","Holiday","Date","Credit Days","Unlock Mode","Active","Notes"],
   rows:rr.map((x:any)=>[person(x.staff_id).employee_id||"",person(x.staff_id).name||"",x.source_year,
    x.holiday_name,x.holiday_date||"",x.units,x.release_mode,x.active?"YES":"NO",x.notes||""])};
 }
 const rr=await fetchRowsPaged("audit_log","actor_staff_id,action,record_id,created_at","created_at.desc");
 return {columns:["Logged At","Actor ID","Actor Name","Action","Record ID"],
  rows:rr.map((x:any)=>[x.created_at,person(x.actor_staff_id).employee_id||"",person(x.actor_staff_id).name||"",x.action,x.record_id||""])};
}
function nextMonth(month:string){let [y,m]=month.split("-").map(Number);m++;if(m===13){m=1;y++}return y+"-"+String(m).padStart(2,"0")}
serve(async req=>{
  const origin=req.headers.get("origin");
  if(req.method==="OPTIONS")return new Response(null,{status:204,headers:cors(origin)});
  if(req.method!=="POST")return json({error:"Method not allowed"},405,origin);
  if(origin&&!ALLOWED.includes(origin))return json({error:"Origin not permitted"},403,origin);
  try{
    const input=await req.json();
    if(typeof input?.action!=="string")throw new ApiError("Invalid request");
    if(input.action==="login")return json(await login(input),200,origin);
    const staff=await authenticate(req);
    if(input.action==="bootstrap")return json(await bootstrap(staff),200,origin);
    if(input.action==="logout"){
      const hash=await sha256(req.headers.get("Authorization")!.replace(/^Bearer\s+/i,"").trim());
      await request("staff_sessions?token_hash=eq."+hash,"DELETE");
      return json({ok:true},200,origin);
    }
    if(input.action==="submitLeave"){
      const p=input.request||{};
      const code="LR-"+Date.now()+"-"+id().slice(0,6).toUpperCase();
      return json(await rpc("submit_leave_v2",{
        p_staff_id:staff.id,p_leave_type:p.leaveType,p_duration:p.duration,p_start:p.startDate,
        p_end:p.endDate,p_reason:p.reason,p_code:code
      }),200,origin);
    }
    if(input.action==="cancelLeave"){
      return json(await rpc("change_leave_status_v2",{p_actor:staff.id,p_request:input.requestId,p_status:"CANCELLED"}),200,origin);
    }
    if(input.action==="adminReport"){
      if(staff.role!=="ADMIN")throw new ApiError("Admin access required",403);
      return json(await adminReportData(String(input.report||"")),200,origin);
    }
    if(input.action==="adminChangeLeaveType"){
      if(staff.role!=="ADMIN")throw new ApiError("Admin access required",403);
      return json(await rpc("admin_change_leave_type_v2",{
        p_actor:staff.id,
        p_request:input.requestId,
        p_type:String(input.leaveType||""),
        p_note:String(input.note||"")
      }),200,origin);
    }
    if(input.action==="decideLeave"){
      if(staff.role!=="ADMIN")throw new ApiError("Admin access required",403);
      return json(await rpc("change_leave_status_v2",{p_actor:staff.id,p_request:input.requestId,p_status:input.status}),200,origin);
    }
    if(input.action==="decideOT"){
      if(staff.role!=="ADMIN")throw new ApiError("Admin access required",403);
      return json(await rpc("change_overtime_status_v2",{
        p_actor:staff.id,p_request:input.requestId,
        p_status:String(input.status||""),
        p_admin_note:String(input.note||"")
      }),200,origin);
    }
    if(input.action==="cancelOT"){
      return json(await rpc("change_overtime_status_v2",{
        p_actor:staff.id,p_request:input.requestId,p_status:"CANCELLED",p_admin_note:""
      }),200,origin);
    }
    if(input.action==="getOTTemplate"){
      return json(await rpc("get_ot_form_v2",{}),200,origin);
    }
    if(input.action==="adminUploadOTTemplate"){
      if(staff.role!=="ADMIN")throw new ApiError("Admin access required",403);
      const filename=String(input.filename||"");
      const base64=String(input.base64||"");
      if(!/^[a-zA-Z0-9._ -]{1,100}\.xlsx$/i.test(filename)||
          base64.length>2800000||base64.length<100||!/^[A-Za-z0-9+/]+={0,2}$/.test(base64))
        throw new ApiError("Upload a valid macro-free .xlsx template (max 2 MB)");
      return json(await rpc("admin_set_ot_form_v2",{
        p_actor:staff.id,p_filename:filename,p_b64:base64
      }),200,origin);
    }
    if(input.action==="submitOT"){
      const p=input.request||{};
      return json(await rpc("submit_overtime_v2",{
        p_staff_id:staff.id,p_date:p.date,p_start:p.start,p_end:p.end,p_claim_type:p.claimType,
        p_reason:p.reason,p_approver:p.approverId||null
      }),200,origin);
    }



    if(input.action==="adminBulkPH"){
      if(staff.role!=="ADMIN")throw new ApiError("Admin access required",403);
      const p=input.batch||{};
      if(!Array.isArray(p.staffIds)||!Array.isArray(p.holidays))
        throw new ApiError("Invalid batch selection");
      return json(await rpc("admin_apply_ph_schedule_v2",{
        p_actor:staff.id,p_year:p.year,p_staff_ids:p.staffIds,p_holidays:p.holidays
      }),200,origin);
    }
    if(input.action==="adminBulkHistoricalPH"){
      if(staff.role!=="ADMIN")throw new ApiError("Admin access required",403);
      const p=input.batch||{};
      if(!Array.isArray(p.balances))throw new ApiError("Invalid PH opening balance data");
      return json(await rpc("admin_save_ph_opening_balances_v2",{
        p_actor:staff.id,p_year:p.year,p_balances:p.balances
      }),200,origin);
    }
    if(input.action==="adminSaveAL"){
      if(staff.role!=="ADMIN")throw new ApiError("Admin access required",403);
      const p=input.allocation||{};
      return json(await rpc("admin_save_al_v2",{
        p_actor:staff.id,p_staff:p.staffId,p_year:p.year,
        p_entitlement:p.entitlement,p_carry_forward:p.carryForward,
        p_adjustment:p.adjustment,p_notes:String(p.notes||"")
      }),200,origin);
    }
    if(input.action==="adminSavePH"){
      if(staff.role!=="ADMIN")throw new ApiError("Admin access required",403);
      const p=input.credit||{};
      return json(await rpc("admin_save_ph_v2",{
        p_actor:staff.id,p_credit:p.id||null,p_staff:p.staffId,p_year:p.year,
        p_name:String(p.holidayName||""),p_holiday_date:p.holidayDate||null,
        p_units:p.units,p_release_mode:String(p.releaseMode||"AUTO_DATE"),
        p_notes:String(p.notes||"")
      }),200,origin);
    }
    if(input.action==="adminTogglePH"){
      if(staff.role!=="ADMIN")throw new ApiError("Admin access required",403);
      return json(await rpc("admin_toggle_ph_v2",{
        p_actor:staff.id,p_credit:input.creditId,p_active:input.active
      }),200,origin);
    }
    if(input.action==="adminCreateStaff"){
      if(staff.role!=="ADMIN")throw new ApiError("Admin access required",403);
      const p=input.employee||{};
      return json(await rpc("employee_create_v2",{
        p_actor:staff.id,p_employee_id:String(p.employeeId||""),
        p_name:String(p.name||""),p_position:String(p.position||""),
        p_department:String(p.department||"SkyBar"),p_pin:String(p.pin||"")
      }),200,origin);
    }
    if(input.action==="adminUpdateStaff"){
      if(staff.role!=="ADMIN")throw new ApiError("Admin access required",403);
      const p=input.employee||{};
      return json(await rpc("employee_update_v2",{
        p_actor:staff.id,p_target:p.id,
        p_employee_id:String(p.employeeId||""),p_name:String(p.name||""),
        p_position:String(p.position||""),p_department:String(p.department||"SkyBar")
      }),200,origin);
    }
    if(input.action==="adminSetStaffStatus"){
      if(staff.role!=="ADMIN")throw new ApiError("Admin access required",403);
      return json(await rpc("employee_status_v2",{
        p_actor:staff.id,p_target:input.staffId,
        p_status:String(input.status||""),
        p_last_working_date:input.lastWorkingDate||null,
        p_note:String(input.note||"")
      }),200,origin);
    }
    if(input.action==="adminResetStaffPin"){
      if(staff.role!=="ADMIN")throw new ApiError("Admin access required",403);
      return json(await rpc("employee_reset_pin_v2",{
        p_actor:staff.id,p_target:input.staffId,p_pin:String(input.newPin||"")
      }),200,origin);
    }
    if(input.action==="adminDeleteUnusedStaff"){
      if(staff.role!=="ADMIN")throw new ApiError("Admin access required",403);
      return json(await rpc("employee_delete_unused_v2",{
        p_actor:staff.id,p_target:input.staffId
      }),200,origin);
    }
    if(input.action==="changeOwnPin"){
      return json(await rpc("employee_change_own_pin_v2",{
        p_actor:staff.id,p_old_pin:String(input.currentPin||""),
        p_new_pin:String(input.newPin||"")
      }),200,origin);
    }
    throw new ApiError("Unknown action",404);
  }catch(e){
    const error=e instanceof Error?e.message:"Unexpected error";
    const code=e instanceof ApiError?e.code:400;
    return json({error},code,origin);
  }
});
