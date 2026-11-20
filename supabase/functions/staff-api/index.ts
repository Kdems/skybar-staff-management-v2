// Supabase Edge Function: staff-api
// Deploy with verify_jwt=false. All access is authenticated with a hashed, server-side staff session.
// Never return or log SUPABASE_SERVICE_ROLE_KEY.
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const URL = Deno.env.get("SUPABASE_URL") || "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const ORIGIN = Deno.env.get("SKYBAR_ALLOWED_ORIGIN") || "https://kdems.github.io";
const ALLOWED = [ORIGIN, "https://kdems.github.io"].filter(Boolean);

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
type Staff = {id:string;employee_id:string;name:string;position:string;role:string;active:boolean};
async function authenticate(req:Request):Promise<Staff>{
  const token=(req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"").trim();
  if(!/^[a-f0-9]{64}$/.test(token))throw new ApiError("Session expired. Please sign in again.",401);
  const rows=await request("staff_sessions?token_hash=eq."+encodeURIComponent(await sha256(token))+"&expires_at=gt."+encodeURIComponent(new Date().toISOString())+"&select=staff_id&limit=1");
  if(!rows.length)throw new ApiError("Session expired. Please sign in again.",401);
  const people=await request("staff?id=eq."+encodeURIComponent(rows[0].staff_id)+"&active=eq.true&select=id,employee_id,name,position,role,active&limit=1");
  if(!people.length)throw new ApiError("Account is inactive.",403);
  return people[0];
}
async function login(payload:any){
  const employeeId=String(payload.employeeId||"").trim().toUpperCase();
  const pin=String(payload.pin||"");
  if(!/^[A-Z0-9_-]{2,32}$/.test(employeeId)||!/^[0-9]{6,8}$/.test(pin))throw new ApiError("Invalid Employee ID or PIN");
  const u=await rpc("login_staff",{p_employee_id:employeeId,p_pin:pin});
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
    request("al_balances?staff_id=eq."+staff.id+"&source_year=lte."+year+"&select=entitlement,carry_forward,adjustment"),
    request("ph_credits?staff_id=eq."+staff.id+"&active=eq.true&select=id,units,release_mode,holiday_date,source_year"),
    request("leave_requests?staff_id=eq."+staff.id+"&select=id,leave_type,duration,start_date,end_date,units,status,reason,request_code&order=submitted_at.desc&limit=150"),
    request("leave_days?leave_date=gte."+prefix+"-01&leave_date=lt."+nextMonth(prefix)+"-01&status=in.(PENDING,APPROVED)&select=leave_date,status,staff_id,staff(name)"),
    request("overtime_requests?staff_id=eq."+staff.id+"&select=id,ot_date,shift_start,shift_end,ot_minutes,status&order=created_at.desc&limit=150"),
    request("staff?active=eq.true&role=eq.ADMIN&select=id,employee_id,name,position")
  ]);
  const reserved= requests.filter((r:any)=>r.status==="APPROVED"||r.status==="PENDING");
  const alGranted=als.reduce((n:number,r:any)=>n+Number(r.entitlement)+Number(r.carry_forward)+Number(r.adjustment),0);
  const alUsed=reserved.filter((r:any)=>r.leave_type==="AL").reduce((n:number,r:any)=>n+Number(r.units),0);
  // Include all active requests across the database for PH credit consumption, not just the last 150.
  const usage=await request("ph_usage?credit_id=in.("+credits.map((c:any)=>c.id).join(",")+")&select=credit_id,units,leave_requests!inner(status)");
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
    const [employees,pending]=await Promise.all([
      request("staff?select=id,employee_id,name,position,role,active&order=name.asc"),
      request("leave_requests?status=eq.PENDING&select=id,staff_id,leave_type,start_date,end_date,reason,units&order=submitted_at.asc")
    ]);
    const names=new Map(employees.map((e:any)=>[e.id,e.name]));
    admin={employees,pending:pending.map((r:any)=>({...r,employee_name:names.get(r.staff_id)||"Staff"}))};
  }
  return {user:staff,data:{
    balances:{al:Math.max(0,alGranted-alUsed),ph,locked},
    calendar:byDate,requests,ot:ots,approvers:approvers.map((a:any)=>({employee_id:a.id,name:a.name})),
    ...admin
  }};
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
    if(input.action==="decideLeave"){
      if(staff.role!=="ADMIN")throw new ApiError("Admin access required",403);
      return json(await rpc("change_leave_status_v2",{p_actor:staff.id,p_request:input.requestId,p_status:input.status}),200,origin);
    }
    if(input.action==="submitOT"){
      const p=input.request||{};
      return json(await rpc("submit_overtime_v2",{
        p_staff_id:staff.id,p_date:p.date,p_start:p.start,p_end:p.end,p_claim_type:p.claimType,
        p_reason:p.reason,p_approver:p.approverId||null
      }),200,origin);
    }
    throw new ApiError("Unknown action",404);
  }catch(e){
    const error=e instanceof Error?e.message:"Unexpected error";
    const code=e instanceof ApiError?e.code:400;
    return json({error},code,origin);
  }
});
