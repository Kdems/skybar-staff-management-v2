(() => {
'use strict';
const cfg=window.SKYBAR_CONFIG||{};
const API=String(cfg.apiUrl||'').trim();
const TZ='Asia/Kuala_Lumpur';
const state={token:sessionStorage.getItem('sb_session')||'',user:null,overview:null,view:'overview',preview:false,alYear:2027,phYear:'ALL',phStaff:'ALL'};
const $=id=>document.getElementById(id);
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const myDate=()=>new Intl.DateTimeFormat('en-CA',{timeZone:TZ,year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
const isoDay=d=>{const y=d.getFullYear(),m=String(d.getMonth()+1).padStart(2,'0'),day=String(d.getDate()).padStart(2,'0');return y+'-'+m+'-'+day};
const fmt=d=>d?new Date(d+'T12:00:00').toLocaleDateString('en-MY',{day:'numeric',month:'short',year:'numeric'}):'—';
const num=n=>Number(n||0).toLocaleString('en-MY',{maximumFractionDigits:1});
const status=s=>'<span class="badge '+esc(String(s||'').toLowerCase())+'">'+esc(s||'—')+'</span>';
const types={AL:'Annual Leave',PH:'Public Holiday',EL:'Emergency Leave'};
let toastTimer;
function toast(s,error=false){const el=$('toast');el.textContent=s;el.className='toast show'+(error?' error':'');clearTimeout(toastTimer);toastTimer=setTimeout(()=>el.className='toast',4500)}
function modal(title,message,actions){$('modalTitle').textContent=title;$('modalContent').innerHTML='<p class="muted">'+esc(message)+'</p>';$('modalActions').replaceChildren();actions.forEach(a=>{const b=document.createElement('button');b.className=a.primary?'primary-btn':'ghost-btn';b.textContent=a.text;b.onclick=()=>{closeModal();a.action?.()};$('modalActions').append(b)});$('overlay').classList.remove('hidden')}
function closeModal(){$('overlay').classList.add('hidden')}
$('modalClose').onclick=closeModal;
$('overlay').addEventListener('click',e=>{if(e.target===$('overlay'))closeModal()});
async function call(action,payload={}){if(!API)throw Error('Supabase Edge Function not configured.');const r=await fetch(API,{method:'POST',headers:{'Content-Type':'application/json',...(state.token?{Authorization:'Bearer '+state.token}:{})},body:JSON.stringify({action,...payload})});let data;try{data=await r.json()}catch{throw Error('Invalid response from server')};if(!r.ok||data.error)throw Error(data.error||'Request failed');return data}
function setPreview(){state.preview=true;state.user={employee_id:'DEMO',name:'Preview Staff',role:'ADMIN',position:'Service Team'};state.overview={balances:{al:12,ph:3,locked:2},calendar:demoCalendar(),requests:[],ot:[],employees:[],pending:[]};enter()}
function demoCalendar(){const d=myDate();const prefix=d.slice(0,7);return {[prefix+'-12']:[{employee_name:'Natasya',status:'APPROVED'}],[prefix+'-16']:[{employee_name:'Roland',status:'PENDING'},{employee_name:'Fikhry',status:'APPROVED'}],[prefix+'-20']:[{employee_name:'Iman',status:'APPROVED'}]}}
async function login(e){e.preventDefault();const b=$('loginBtn');b.disabled=true;b.firstChild.textContent='Signing in… ';try{const r=await call('login',{employeeId:$('employeeId').value.trim(),pin:$('pin').value});state.token=r.token;sessionStorage.setItem('sb_session',r.token);state.user=r.user;await load();enter()}catch(err){toast(err.message,true)}finally{b.disabled=false;b.firstChild.textContent='Sign in '}}
async function load(){if(state.preview)return;const r=await call('bootstrap');state.user=r.user;state.overview=r.data}
function enter(){$('loginScreen').classList.add('hidden');$('appScreen').classList.remove('hidden');$('sidebarName').textContent=state.user.name;$('sidebarRole').textContent=state.user.position||state.user.role;$('avatar').textContent=state.user.name.slice(0,1).toUpperCase();$('adminNav').classList.toggle('hidden',state.user.role!=='ADMIN');$('balancesNav').classList.toggle('hidden',state.user.role!=='ADMIN');$('modeBadge').textContent=state.preview?'PREVIEW':'CONNECTED';$('previewNotice').classList.toggle('hidden',!state.preview);$('todayLabel').textContent=fmt(myDate());render()}
function showLogin(){$('appScreen').classList.add('hidden');$('loginScreen').classList.remove('hidden')}
function navigate(page){state.view=page;document.querySelectorAll('[data-page]').forEach(el=>el.classList.toggle('active',el.dataset.page===page));render()}
function title(s){return '<div class="section-bar"><h2>'+s+'</h2></div>'}
function metric(label,value,foot){return '<article class="card"><div class="metric-label">'+esc(label)+'</div><div class="metric-value">'+esc(value)+'</div><div class="metric-foot">'+esc(foot)+'</div></article>'}
function cardEmpty(s){return '<div class="empty-state">'+esc(s)+'</div>'}
function overview(){const b=state.overview.balances;const pending=(state.overview.requests||[]).filter(r=>r.status==='PENDING').length;return '<div class="hero"><div><span class="eyebrow">YOUR WORKSPACE</span><h2>Good to see you, '+esc(state.user.name.split(' ')[0])+'.</h2><p>Plan your leave, check your PH credits and record overtime. Everything stays organized in one place.</p></div><button class="primary-btn" data-go="leave">Request Leave ↗</button></div><div class="grid grid-4">'+metric('AL Available',num(b.al),'Days remaining')+metric('PH Available',num(b.ph),'Released credits')+metric('PH Locked',num(b.locked),'Future holidays')+metric('Pending Requests',pending,'Awaiting decision')+'</div>'+title('Quick access')+'<div class="grid grid-3"><button class="action-card" data-go="leave"><span class="action-icon">▦</span><span><b>Apply for leave</b><small>Current month only</small></span></button><button class="action-card" data-go="calendar"><span class="action-icon">▤</span><span><b>Team calendar</b><small>View names & availability</small></span></button><button class="action-card" data-go="overtime"><span class="action-icon">◷</span><span><b>Submit overtime</b><small>Automatic 9h deduction</small></span></button></div>'+title('Important rules')+'<div class="card"><p class="muted">Leave applications are restricted to the current month, with a maximum of two staff per date. Both pending and approved leave reserve a slot. Future PH credits unlock on their actual holiday date in Malaysia time.</p><div class="soft-note">Official live submissions open on 1 January 2027. Administrators can test with demo records before launch.</div></div>'}
function requestForm(){const today=myDate();const [y,m]=today.split('-').map(Number);const last=isoDay(new Date(y,m,0));const b=state.overview.balances;return '<div class="grid grid-4">'+metric('AL Balance',num(b.al),'Available')+metric('PH Balance',num(b.ph),'Available')+metric('PH Locked',num(b.locked),'Not yet released')+metric('Daily Limit','2','Staff per date')+'</div>'+title('New leave request')+'<div class="card"><form id="leaveForm"><div class="form-grid"><div class="field"><label for="leaveType">Leave Type</label><select id="leaveType" required><option value="AL">Annual Leave (AL)</option><option value="PH">Public Holiday (PH)</option><option value="EL">Emergency Leave (EL)</option></select></div><div class="field"><label for="leaveDuration">Duration</label><select id="leaveDuration"><option value="FULL">Full Day</option><option value="HALF_AM">Half Day — AM</option><option value="HALF_PM">Half Day — PM</option></select></div><div class="field"><label for="leaveStart">Start date</label><input type="date" id="leaveStart" min="'+today+'" max="'+last+'" value="'+today+'" required></div><div class="field"><label for="leaveEnd">End date</label><input type="date" id="leaveEnd" min="'+today+'" max="'+last+'" value="'+today+'" required></div><div class="field full"><label for="leaveReason">Reason for leave</label><textarea id="leaveReason" placeholder="Provide a brief reason" maxlength="500" required></textarea></div></div><div class="soft-note">Only '+esc(today.slice(0,7))+' dates are open. If a date already has two people, your request will be blocked. Pending and approved requests both count.</div><div class="form-actions"><button class="primary-btn" type="submit" '+(state.preview?'disabled':'')+'>Submit Request ↗</button></div></form></div>'}
function calendar(){const today=myDate(),[y,m]=today.split('-').map(Number),week=new Date(y,m-1,1).getDay(),days=new Date(y,m,0).getDate(),data=state.overview.calendar||{};let html='<div class="card"><div class="section-bar" style="margin:0 0 17px"><h2>'+new Date(y,m-1,1).toLocaleString('en-MY',{month:'long',year:'numeric'})+'</h2><span class="muted">2 staff maximum per day</span></div><div class="calendar-grid">';for(const d of ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'])html+='<div class="calendar-dow">'+d+'</div>';for(let i=0;i<week;i++)html+='<div class="calendar-day empty"></div>';for(let day=1;day<=days;day++){const date=isoDay(new Date(y,m-1,day)),names=data[date]||[];html+='<div class="calendar-day '+(names.length>=2?'full':'')+'"><div class="calendar-date">'+day+'</div>'+names.map(n=>'<div class="calendar-name '+esc(n.status?.toLowerCase())+'">'+esc(n.employee_name)+' · '+(n.status==='APPROVED'?'A':'P')+'</div>').join('')+'<div class="calendar-free">'+(names.length>=2?'FULL':(2-names.length)+' slot'+(names.length===1?'':'s')+' left')+'</div></div>'}return html+'</div><p class="muted" style="font-size:.78rem">A = Approved · P = Pending. All staff can see names and availability, not private leave reasons.</p></div>'}
function calculateOt(start,end){if(!start||!end)return null;const [sh,sm]=start.split(':').map(Number),[eh,em]=end.split(':').map(Number);let minutes=(eh*60+em)-(sh*60+sm);if(minutes<=0)minutes+=1440;const ot=Math.max(0,minutes-540),fmtTime=n=>String(Math.floor((n%(1440))/60)).padStart(2,'0')+':'+String(n%60).padStart(2,'0');return{hours:ot/60,otStart:ot?fmtTime(sh*60+sm+540):'—',otEnd:ot?end:'—',total:minutes/60}}
function overtime(){return title('Overtime submission')+'<div class="card"><form id="otForm"><div class="form-grid"><div class="field"><label>Staff name</label><input disabled value="'+esc(state.user.name)+'"></div><div class="field"><label for="otDate">OT date</label><input type="date" id="otDate" value="'+myDate()+'" required></div><div class="field"><label for="shiftStart">Current Shift — Start</label><input type="time" id="shiftStart" required></div><div class="field"><label for="shiftEnd">Shift End</label><input type="time" id="shiftEnd" required></div><div class="field"><label>Claim Type</label><select id="claimType"><option value="NORMAL">Normal Working Day · x1.5</option><option value="OFF">Off / Rest Day · x2.0</option><option value="PH">Compulsory PH · x3.0</option></select></div><div class="field"><label for="otApprover">Instructed by</label><select id="otApprover"><option value="">Select manager / supervisor</option>'+((state.overview.approvers||[]).map(a=>'<option value="'+esc(a.employee_id)+'">'+esc(a.name)+'</option>').join(''))+'</select></div><div class="field full"><label for="otReason">Reason for overtime</label><textarea id="otReason" placeholder="Describe the work completed" required maxlength="500"></textarea></div></div><div id="otCalc" class="soft-note">Enter shift start and shift end to calculate OT automatically. Normal shift = 9 hours.</div><div class="form-actions"><button type="submit" class="primary-btn" '+(state.preview?'disabled':'')+'>Submit Overtime ↗</button></div></form></div>'}
function history(){const items=(state.overview.requests||[]);const ots=(state.overview.ot||[]);return title('Leave requests')+'<div class="card table-wrap">'+(items.length?'<table><thead><tr><th>Date</th><th>Type</th><th>Units</th><th>Status</th><th>Action</th></tr></thead><tbody>'+items.map(r=>'<tr><td>'+fmt(r.start_date)+' – '+fmt(r.end_date)+'</td><td>'+esc(types[r.leave_type]||r.leave_type)+'</td><td>'+num(r.units)+'</td><td>'+status(r.status)+'</td><td>'+(r.status==='PENDING'?'<button class="ghost-btn" data-cancel="'+esc(r.id)+'">Cancel</button>':'—')+'</td></tr>').join('')+'</tbody></table>':cardEmpty('No leave requests yet.'))+'</div>'+title('Overtime submissions')+'<div class="card table-wrap">'+(ots.length?'<table><thead><tr><th>Date</th><th>Shift</th><th>OT hours</th><th>Status</th></tr></thead><tbody>'+ots.map(r=>'<tr><td>'+fmt(r.ot_date)+'</td><td>'+esc(r.shift_start)+' – '+esc(r.shift_end)+'</td><td>'+num(r.ot_minutes/60)+'</td><td>'+status(r.status)+'</td></tr>').join('')+'</tbody></table>':cardEmpty('No overtime submissions yet.'))+'</div>'}


const commonPH = ['Federal Territory Day','Chinese New Year','Nuzul Al-Quran','Hari Raya Aidilfitri','Labour Day','Wesak Day','Hari Raya Aidiladha','Agong Birthday','Awal Muharram','National Day','Malaysia Day','Maulidur Rasul','Deepavali','Christmas Day','Additional PH'];
function phStatus(credit){
 if(!credit.active)return 'INACTIVE';
 if(credit.release_mode==='AUTO_DATE' && credit.holiday_date>myDate())return 'LOCKED';
 return 'RELEASED';
}
function balances(){
 if(state.user.role!=='ADMIN')return cardEmpty('Admin access only.');
 const people=state.overview.employees||[];
 const allocations=state.overview.alAllocations||[];
 const credits=state.overview.phCredits||[];
 const year=state.alYear, now=myDate();
 const count=allocations.filter(a=>Number(a.source_year)===year).length;
 const locked=credits.filter(p=>p.active&&p.release_mode==='AUTO_DATE'&&p.holiday_date>now).reduce((n,p)=>n+Number(p.units),0);
 const released=credits.filter(p=>p.active&&(p.release_mode==='MANUAL'||p.holiday_date<=now)).reduce((n,p)=>n+Number(p.units)-(Number(p.reservedUnits)||0),0);
 const yearOptions=[2025,2026,2027,2028,2029].map(y=>'<option value="'+y+'" '+(y===year?'selected':'')+'>'+y+'</option>').join('');
 const alRows=people.map(p=>{
  const a=allocations.find(v=>v.staff_id===p.id&&Number(v.source_year)===year);
  const total=Number(a?.entitlement||0)+Number(a?.carry_forward||0)+Number(a?.adjustment||0);
  return '<tr><td><b>'+esc(p.employee_id)+'</b></td><td>'+esc(p.name)+'</td><td>'+num(a?.entitlement)+'</td><td>'+num(a?.carry_forward)+'</td><td>'+num(a?.adjustment)+'</td><td><b>'+num(total)+'</b></td><td><button class="ghost-btn" data-edit-al="'+esc(p.id)+'">'+(a?'Edit':'Set AL')+'</button></td></tr>';
 }).join('');
 const phRows=credits.filter(p=>(state.phYear==='ALL'||String(p.source_year)===state.phYear)&&(state.phStaff==='ALL'||p.staff_id===state.phStaff));
 const names=new Map(people.map(p=>[p.id,p]));
 const phTable=phRows.map(p=>{
  const employee=names.get(p.staff_id);
  return '<tr><td><b>'+esc(employee?.name||'Unknown')+'</b><div class="muted">'+esc(employee?.employee_id||'')+'</div></td><td>'+esc(p.source_year)+'</td><td>'+esc(p.holiday_name)+'</td><td>'+esc(p.holiday_date?fmt(p.holiday_date):'Historical')+'</td><td>'+num(p.units)+'</td><td>'+num(p.reservedUnits||0)+'</td><td>'+status(phStatus(p))+'</td><td><div class="staff-actions"><button class="ghost-btn" data-edit-ph="'+esc(p.id)+'">Edit</button><button class="ghost-btn" data-toggle-ph="'+esc(p.id)+'">'+(p.active?'Deactivate':'Reactivate')+'</button></div></td></tr>';
 }).join('');
 const phYearOptions=['ALL','2025','2026','2027','2028','2029'].map(y=>'<option value="'+y+'" '+(state.phYear===y?'selected':'')+'>'+(y==='ALL'?'All years':y)+'</option>').join('');
 const phStaffOptions='<option value="ALL">All staff</option>'+people.map(p=>'<option value="'+esc(p.id)+'" '+(state.phStaff===p.id?'selected':'')+'>'+esc(p.name)+' ('+esc(p.employee_id)+')</option>').join('');
 return '<div class="hero"><div><span class="eyebrow">ADMIN CONTROL</span><h2>Annual Leave & Public Holiday</h2><p>Prepare 2027 entitlements, record historical 2025–2026 PH, and schedule future PH credits with automatic unlock dates.</p></div></div>'+
  '<div class="grid grid-3">'+metric('AL Allocated ('+year+')',count,people.length+' staff accounts')+metric('Released PH',num(Math.max(0,released)),'Available units, across staff')+metric('Locked Future PH',num(locked),'Awaiting holiday dates')+'</div>'+
  '<div class="section-bar"><div><h2>Annual Leave Allocation</h2><p>Each year is separate. Carry-forward into 2027 belongs in the 2027 row.</p></div><select id="alYearSelector" class="toolbar-select">'+yearOptions+'</select></div>'+
  '<div class="card table-wrap"><table><thead><tr><th>ID</th><th>Employee</th><th>Entitlement</th><th>Carry-forward</th><th>Adjustment</th><th>Total Days</th><th>Action</th></tr></thead><tbody>'+(alRows||'<tr><td colspan="7">No employees.</td></tr>')+'</tbody></table></div>'+
  '<div class="section-bar"><div><h2>Public Holiday Credit Ledger</h2><p>2025 historical PH may be entered as earned. Future PH remains locked until its date.</p></div><button class="primary-btn" id="addPHBtn">+ Add PH Credit</button></div>'+
  '<div class="filter-bar"><select id="phYearSelector" class="toolbar-select">'+phYearOptions+'</select><select id="phStaffSelector" class="toolbar-select">'+phStaffOptions+'</select></div>'+
  '<div class="card table-wrap">'+(phRows.length?'<table><thead><tr><th>Staff</th><th>Year</th><th>Holiday</th><th>Holiday Date</th><th>Credit</th><th>Reserved</th><th>Status</th><th>Actions</th></tr></thead><tbody>'+phTable+'</tbody></table>':cardEmpty('No PH credits for these filters.'))+'</div>'+
  '<div class="soft-note" style="margin-top:16px">Admin can prepare credits now. Live leave submissions stay locked until 1 January 2027; PH is consumed oldest-first.</div>';
}
function admin(){
  if(state.user.role!=='ADMIN')return cardEmpty('Admin access only.');
  const people=state.overview.employees||[];
  const pend=state.overview.pending||[];
  return '<div class="grid grid-3">'+metric('Registered Staff',people.length,'Active and archived')+
    metric('Pending Approval',pend.length,'Leave requests')+
    metric('Go-live','01 Jan 2027','Submission lock active')+'</div>'+
    '<div class="section-bar"><h2>Employee Management</h2><button class="primary-btn" id="addStaffBtn" '+(state.preview?'disabled':'')+'>+ Register Staff</button></div>'+
    '<div class="card table-wrap">'+(people.length?
      '<table><thead><tr><th>Staff ID</th><th>Name</th><th>Position</th><th>Status</th><th>Actions</th></tr></thead><tbody>'+
      people.map(p=>'<tr><td><b>'+esc(p.employee_id)+'</b></td><td>'+esc(p.name)+'</td><td>'+esc(p.position||'—')+
      '<div class="muted">'+esc(p.department||'SkyBar')+'</div></td><td>'+status(p.employment_status||(p.active?'ACTIVE':'INACTIVE'))+
      (p.last_working_date?'<div class="muted">'+fmt(p.last_working_date)+'</div>':'')+'</td><td><div class="staff-actions">'+
      '<button class="ghost-btn" data-edit-staff="'+esc(p.id)+'">Edit</button>'+
      (p.role!=='ADMIN'?'<button class="ghost-btn" data-staff-status="'+esc(p.id)+'">Status</button>':'')+
      '<button class="ghost-btn" data-reset-staff-pin="'+esc(p.id)+'">Reset PIN</button>'+
      (p.role!=='ADMIN'?'<button class="ghost-btn danger-text" data-delete-staff="'+esc(p.id)+'">Delete</button>':'')+
      '</div></td></tr>').join('')+'</tbody></table>':cardEmpty('No employee records yet.'))+'</div>'+
    title('Pending Leave Approvals')+'<div class="card table-wrap">'+
    (pend.length?'<table><thead><tr><th>Staff</th><th>Dates</th><th>Type</th><th>Reason</th><th>Action</th></tr></thead><tbody>'+
      pend.map(r=>'<tr><td>'+esc(r.employee_name)+'</td><td>'+fmt(r.start_date)+' – '+fmt(r.end_date)+'</td><td>'+esc(types[r.leave_type]||r.leave_type)+'</td><td>'+esc(r.reason)+'</td><td><div class="staff-actions"><button class="ghost-btn" data-decision="'+esc(r.id)+'" data-status="APPROVED">Approve</button><button class="ghost-btn" data-decision="'+esc(r.id)+'" data-status="REJECTED">Reject</button></div></td></tr>').join('')+'</tbody></table>':
      cardEmpty('No pending requests.'))+'</div>'+
    title('Next modules')+'<div class="card"><p class="muted">AL yearly balances, PH bulk calendar and carry-forward, OT approval and downloadable HR Excel form are being migrated to V2. We will test these modules before the January launch.</p></div>';
}
function staffById(id){return(state.overview?.employees||[]).find(p=>p.id===id)}
function formField(label,id,value='',extra='',type='text'){
  return '<div class="field"><label for="'+esc(id)+'">'+esc(label)+'</label><input id="'+esc(id)+'" type="'+type+'" value="'+esc(value)+'" '+extra+'></div>';
}
function customForm(title,html,label,submit){
  $('modalTitle').textContent=title;
  $('modalContent').innerHTML=html;
  $('modalActions').replaceChildren();
  const close=document.createElement('button');close.className='ghost-btn';close.textContent='Back';close.onclick=closeModal;
  const save=document.createElement('button');save.className='primary-btn';save.textContent=label;
  save.onclick=async()=>{
    save.disabled=true;save.textContent='Saving…';
    try{await submit()}catch(e){toast(e.message,true)}finally{save.disabled=false;save.textContent=label}
  };
  $('modalActions').append(close,save);
  $('overlay').classList.remove('hidden');
}
async function adminCommit(action,payload,message){
  if(state.preview)throw Error('Preview is read-only');
  await call(action,payload);
  closeModal();
  await reload();
  toast(message);
}
function employeePayload(){
  const p={employeeId:$('eId').value.trim().toUpperCase(),
    name:$('eName').value.trim(),position:$('ePosition').value.trim(),
    department:$('eDepartment').value.trim()};
  if(!/^[A-Z0-9_-]{2,32}$/.test(p.employeeId)||p.name.length<2||p.position.length<2||p.department.length<2){
    throw Error('Enter a valid Staff ID, Name, Position and Department');
  }
  return p;
}
function editStaff(id=null){
  if(state.preview)return toast('Preview is read-only',true);
  const p=id?staffById(id):null;
  if(id&&!p)return toast('Employee not found',true);
  const isAdmin=p?.role==='ADMIN';
  const fields='<div class="form-grid">'+
    formField('Employee ID','eId',p?.employee_id||'',isAdmin?'disabled':'required maxlength="32"')+
    formField('Full Name','eName',p?.name||'','required maxlength="120"')+
    formField('Position','ePosition',p?.position||'','required maxlength="120"')+
    formField('Department','eDepartment',p?.department||'SkyBar','required maxlength="120"')+
    (!p?formField('Initial PIN (8 digits)','ePin','','required inputmode="numeric" maxlength="8"','password'):'')+
    '</div>'+
    '<div class="soft-note" style="margin-top:15px">'+(p?
      'Staff ID changes preserve existing Leave, PH and OT history. PIN is managed separately.':
      'A unique 8-digit PIN is required. New accounts start as STAFF and Active.')+'</div>';
  customForm(p?'Edit Employee':'Register Staff',fields,p?'Save Changes':'Create Staff',async()=>{
    const data=employeePayload();
    if(p){await adminCommit('adminUpdateStaff',{employee:{id:p.id,...data}},'Employee profile updated')}
    else{
      const pin=$('ePin').value;
      if(!/^\d{8}$/.test(pin))throw Error('Enter a unique 8-digit PIN');
      await adminCommit('adminCreateStaff',{employee:{...data,pin}},'Staff account created');
    }
  });
}
function changeStaffStatus(id){
  const p=staffById(id);
  if(!p||state.preview)return;
  const html='<p class="muted">Update employment status for <b>'+esc(p.name)+'</b> ('+esc(p.employee_id)+'). Resigned and Inactive staff cannot login, but their records remain.</p>'+
    '<div class="field"><label for="staffNewStatus">New Status</label><select id="staffNewStatus"><option value="ACTIVE">Active</option><option value="INACTIVE">Inactive</option><option value="RESIGNED">Resigned</option></select></div>'+
    formField('Last Working Date (required for Resigned)','staffLastDay',p.last_working_date||myDate(),'','date')+
    '<div class="field"><label for="staffStatusNote">Reason / Note</label><textarea id="staffStatusNote" maxlength="500"></textarea></div>';
  customForm('Employee Status',html,'Confirm Status',async()=>{
    const status=$('staffNewStatus').value;
    if(status==='RESIGNED'&&!$('staffLastDay').value)throw Error('Enter last working date');
    await adminCommit('adminSetStaffStatus',{
      staffId:p.id,status,lastWorkingDate:status==='RESIGNED'?$('staffLastDay').value:null,
      note:$('staffStatusNote').value
    },'Employee status updated');
  });
  $('staffNewStatus').value=p.employment_status||'ACTIVE';
}
function resetStaffPin(id){
  const p=staffById(id);if(!p||state.preview)return;
  customForm('Reset Staff PIN',
    '<p class="muted">Reset PIN for <b>'+esc(p.name)+'</b>. Previous login sessions will be invalidated.</p>'+
    formField('New 8-Digit PIN','staffResetPin','','required inputmode="numeric" maxlength="8"','password'),
    'Reset PIN',async()=>{
      const pin=$('staffResetPin').value;
      if(!/^\d{8}$/.test(pin))throw Error('PIN must be exactly 8 digits');
      await adminCommit('adminResetStaffPin',{staffId:p.id,newPin:pin},'Staff PIN reset');
    });
}
function deleteUnusedStaff(id){
  const p=staffById(id);if(!p||state.preview)return;
  modal('Delete Unused Staff Account?',
    'Permanently delete '+p.name+' ('+p.employee_id+')? This is permitted only if no Leave, PH, AL, OT or audit history exists. Otherwise, mark Resigned.',
    [{text:'Keep Account'},{text:'Delete Account',primary:true,action:async()=>{
      try{await call('adminDeleteUnusedStaff',{staffId:p.id});await reload();toast('Unused employee deleted')}
      catch(e){toast(e.message,true)}
    }}]);
}
function changeOwnPinModal(){
  if(state.preview)return toast('Preview is read-only',true);
  customForm('Change My PIN',
    formField('Current PIN','ownCurrentPin','','required inputmode="numeric" maxlength="8"','password')+
    formField('New PIN (8 digits)','ownNewPin','','required inputmode="numeric" maxlength="8"','password')+
    '<div class="soft-note" style="margin-top:12px">Changing your PIN signs you out from all devices.</div>',
    'Change PIN',async()=>{
      const currentPin=$('ownCurrentPin').value,newPin=$('ownNewPin').value;
      if(!/^\d{8}$/.test(newPin))throw Error('New PIN must be 8 digits');
      await call('changeOwnPin',{currentPin,newPin});
      closeModal();state.token='';sessionStorage.removeItem('sb_session');showLogin();
      toast('PIN changed. Please sign in again.');
    });
}
function render(){const names={overview:'Overview',leave:'Leave Request',calendar:'Leave Calendar',overtime:'Overtime',history:'My Requests',balances:'AL & PH Management',admin:'Administration'};$('pageHeading').textContent=names[state.view]||'Overview';$('view').innerHTML=({overview,leave:requestForm,calendar,overtime,history,balances,admin}[state.view]||overview)();document.querySelectorAll('[data-go]').forEach(x=>x.addEventListener('click',()=>navigate(x.dataset.go)));$('leaveForm')?.addEventListener('submit',onLeave);$('otForm')?.addEventListener('submit',onOt);$('shiftStart')?.addEventListener('input',refreshOt);$('shiftEnd')?.addEventListener('input',refreshOt);document.querySelectorAll('[data-cancel]').forEach(x=>x.onclick=()=>modal('Cancel leave request?','This pending leave request will be cancelled and its daily slots released.',[{text:'Keep request'},{text:'Cancel request',primary:true,action:async()=>{try{await call('cancelLeave',{requestId:x.dataset.cancel});await reload();toast('Request cancelled')}catch(e){toast(e.message,true)}}}]));$('addStaffBtn')?.addEventListener('click',()=>editStaff());
document.querySelectorAll('[data-edit-staff]').forEach(x=>x.onclick=()=>editStaff(x.dataset.editStaff));
document.querySelectorAll('[data-staff-status]').forEach(x=>x.onclick=()=>changeStaffStatus(x.dataset.staffStatus));
document.querySelectorAll('[data-reset-staff-pin]').forEach(x=>x.onclick=()=>resetStaffPin(x.dataset.resetStaffPin));
document.querySelectorAll('[data-delete-staff]').forEach(x=>x.onclick=()=>deleteUnusedStaff(x.dataset.deleteStaff));
document.querySelectorAll('[data-decision]').forEach(x=>x.onclick=()=>modal(x.dataset.status==='APPROVED'?'Approve leave?':'Reject leave?','This decision will be recorded in the staff leave history.',[{text:'Back'},{text:'Confirm',primary:true,action:async()=>{try{await call('decideLeave',{requestId:x.dataset.decision,status:x.dataset.status});await reload();toast('Decision saved')}catch(e){toast(e.message,true)}}}]))}
async function reload(){await load();render()}
function onLeave(e){e.preventDefault();if(state.preview)return;const p={leaveType:$('leaveType').value,duration:$('leaveDuration').value,startDate:$('leaveStart').value,endDate:$('leaveEnd').value,reason:$('leaveReason').value.trim()};if(p.endDate<p.startDate)return toast('End date cannot be before start date',true);modal('Confirm leave request','Apply for '+(types[p.leaveType]||p.leaveType)+' from '+fmt(p.startDate)+' to '+fmt(p.endDate)+'?', [{text:'Back'},{text:'Submit',primary:true,action:async()=>{try{const r=await call('submitLeave',{request:p});await reload();modal('Request submitted','Your request '+r.requestCode+' is now pending approval.',[{text:'View requests',primary:true,action:()=>navigate('history')}])}catch(e){toast(e.message,true)}}}])}
function refreshOt(){const calc=calculateOt($('shiftStart').value,$('shiftEnd').value);$('otCalc').textContent=calc?'Total shift: '+calc.total.toFixed(2)+'h · Normal 9h · OT: '+calc.otStart+' – '+calc.otEnd+' ('+calc.hours.toFixed(2)+'h)':'Enter shift start and shift end to calculate OT automatically.'}
function onOt(e){e.preventDefault();if(state.preview)return;const calc=calculateOt($('shiftStart').value,$('shiftEnd').value);if(!calc||calc.hours<=0)return toast('No overtime detected after 9 working hours.',true);const request={date:$('otDate').value,start:$('shiftStart').value,end:$('shiftEnd').value,claimType:$('claimType').value,approverId:$('otApprover').value,reason:$('otReason').value.trim()};modal('Submit overtime?','Calculated overtime: '+calc.hours.toFixed(2)+' hours. Details will be verified by the server.',[{text:'Back'},{text:'Submit',primary:true,action:async()=>{try{await call('submitOT',{request});await reload();modal('Overtime submitted','Your OT claim was recorded and is pending approval.',[{text:'View requests',primary:true,action:()=>navigate('history')}])}catch(e){toast(e.message,true)}}}])}
document.querySelectorAll('[data-page]').forEach(x=>x.onclick=()=>navigate(x.dataset.page));
$('loginForm').addEventListener('submit',login);
$('changePinButton')?.addEventListener('click',changeOwnPinModal);
$('previewBtn').onclick=setPreview;
$('logoutBtn').onclick=async()=>{try{if(!state.preview)await call('logout')}catch{}state.token='';state.preview=false;sessionStorage.removeItem('sb_session');showLogin()};
if(!API){$('setupNote').classList.remove('hidden');$('previewBtn').classList.remove('hidden')}
if(state.token&&API){load().then(()=>enter()).catch(()=>{sessionStorage.removeItem('sb_session');state.token='';showLogin()})}
})();