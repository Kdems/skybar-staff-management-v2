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
const types={AL:'Annual Leave',PH:'Public Holiday',EL:'Emergency Leave',OFF:'Off Day (Admin Only)'};
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
function enter(){$('loginScreen').classList.add('hidden');$('appScreen').classList.remove('hidden');$('sidebarName').textContent=state.user.name;$('sidebarRole').textContent=state.user.position||state.user.role;$('avatar').textContent=state.user.name.slice(0,1).toUpperCase();$('adminNav').classList.toggle('hidden',state.user.role!=='ADMIN');$('balancesNav').classList.toggle('hidden',state.user.role!=='ADMIN');$('reportsNav').classList.toggle('hidden',state.user.role!=='ADMIN');$('modeBadge').textContent=state.preview?'PREVIEW':'CONNECTED';$('previewNotice').classList.toggle('hidden',!state.preview);$('todayLabel').textContent=fmt(myDate());render()}
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
function history(){
 const items=state.overview.requests||[],ots=state.overview.ot||[];
 return title('Leave requests')+'<div class="card table-wrap">'+(items.length?
  '<table><thead><tr><th>Date</th><th>Type</th><th>Units</th><th>Status</th><th>Action</th></tr></thead><tbody>'+
  items.map(r=>'<tr><td>'+fmt(r.start_date)+' – '+fmt(r.end_date)+'</td><td>'+esc(types[r.leave_type]||r.leave_type)+'</td><td>'+num(r.units)+'</td><td>'+status(r.status)+'</td><td>'+
  (r.status==='PENDING'?'<button class="ghost-btn" data-cancel="'+esc(r.id)+'">Cancel</button>':'—')+
  (r.admin_note?'<div class="muted">Admin: '+esc(r.admin_note)+'</div>':'')+'</td></tr>').join('')+'</tbody></table>':
  cardEmpty('No leave requests yet.'))+'</div>'+
 title('Overtime submissions')+'<div class="card table-wrap">'+(ots.length?
  '<table><thead><tr><th>Date</th><th>Shift</th><th>OT Hours</th><th>Status</th><th>Actions</th></tr></thead><tbody>'+
  ots.map(r=>'<tr><td>'+fmt(r.ot_date)+'</td><td>'+esc(r.shift_start)+' – '+esc(r.shift_end)+
  '</td><td>'+num(Number(r.ot_minutes)/60)+'</td><td>'+status(r.status)+
  (r.admin_note?'<div class="muted">Admin: '+esc(r.admin_note)+'</div>':'')+
  '</td><td><div class="staff-actions"><button class="ghost-btn" data-print-ot="'+esc(r.id)+'">Download OT Form</button>'+
  (r.status==='PENDING'?'<button class="ghost-btn" data-cancel-ot="'+esc(r.id)+'">Cancel</button>':'')+
  '</div></td></tr>').join('')+'</tbody></table>':cardEmpty('No overtime submissions yet.'))+'</div>';
}

const commonPH = ['Federal Territory Day','Chinese New Year','Nuzul Al-Quran','Hari Raya Aidilfitri','Labour Day','Wesak Day','Hari Raya Aidiladha','Agong Birthday','Awal Muharram','National Day','Malaysia Day','Maulidur Rasul','Deepavali','Christmas Day','Additional PH'];
function phStatus(credit){
 if(!credit.active)return 'INACTIVE';
 if(credit.release_mode==='AUTO_DATE' && credit.holiday_date>myDate())return 'LOCKED';
 return 'RELEASED';
}

function bulkStaff(){
 return (state.overview?.employees||[]).filter(p=>p.active&&p.role==='STAFF');
}
function parseHolidaySchedule(raw,year){
 const lines=String(raw||'').split(/\r?\n/).map(s=>s.trim()).filter(Boolean);
 if(lines.length<1||lines.length>40)throw Error('Enter between 1 and 40 PH holidays');
 const seen=new Set();
 return lines.map((line,i)=>{
  const p=(line.includes('\t')?line.split('\t'):line.split('|')).map(x=>x.trim());
  if(p.length!==3)throw Error('Line '+(i+1)+': use YYYY-MM-DD | Holiday Name | Days');
  const [date,name,amount]=p;
  if(!/^\d{4}-\d{2}-\d{2}$/.test(date)||Number(date.slice(0,4))!==Number(year))
   throw Error('Line '+(i+1)+': date must match selected year');
  const d=new Date(date+'T12:00:00');
  if(Number.isNaN(d.valueOf())||isoDay(d)!==date)
   throw Error('Line '+(i+1)+': invalid calendar date');
  const units=Number(amount);
  if(name.length<2||name.length>160||!Number.isFinite(units)||units<0.5||units>3||units*2!==Math.trunc(units*2))
   throw Error('Line '+(i+1)+': name required and days must be 0.5 to 3');
  const k=date+'|'+name.toLowerCase();
  if(seen.has(k))throw Error('Line '+(i+1)+': duplicate PH in the same list');
  seen.add(k);
  return {date,name,units};
 });
}
function openBulkPHDraft(saved=null){
 if(state.preview)return toast('Preview is read-only',true);
 const people=bulkStaff();
 if(!people.length)return toast('No active staff accounts to allocate PH',true);
 const checked=new Set(saved?.staffIds||people.map(p=>p.id));
 const year=Number(saved?.year||2027);
 const checkedHtml=people.map(p=>'<label class="bulk-staff-item"><input class="bulk-staff-check" type="checkbox" value="'+esc(p.id)+'" '+(checked.has(p.id)?'checked':'')+'><span><b>'+esc(p.name)+'</b><small>'+esc(p.employee_id)+' · '+esc(p.position||'Staff')+'</small></span></label>').join('');
 const yearOptions=[2025,2026,2027,2028,2029].map(y=>'<option value="'+y+'" '+(year===y?'selected':'')+'>'+y+'</option>').join('');
 const html='<div class="bulk-dialog"><p class="muted">Select staff once, paste the PH schedule, and allocate every holiday to every selected staff in one transaction. Matching existing credits will be skipped.</p>'+
 '<div class="field"><label for="bulkYear">Public holiday source year</label><select id="bulkYear">'+yearOptions+'</select></div>'+
 '<div class="section-bar"><div><h3>Staff to receive credits</h3><p>Active STAFF accounts only · '+people.length+' available</p></div><div class="staff-actions"><button class="ghost-btn" type="button" id="bulkAll">Select All</button><button class="ghost-btn" type="button" id="bulkNone">Clear</button></div></div>'+
 '<div class="bulk-staff-grid">'+checkedHtml+'</div>'+
 '<div class="field"><label for="bulkPHRows">PH schedule — one holiday per line</label>'+
 '<textarea id="bulkPHRows" rows="7" spellcheck="false" placeholder="YYYY-MM-DD | Holiday Name | Days\n2027-XX-XX | Holiday name | 1">'+esc(saved?.lines||'')+'</textarea>'+
 '<p class="muted" style="font-size:.76rem">Use actual hotel-approved holiday dates. Copy from Excel as 3 tab-separated columns, or use the | separator. Format: Date | Name | Days. Maximum 40 rows per batch.</p></div>'+
 '<div class="soft-note">Future dated PH remains LOCKED until its holiday date. This operation does not change staff PIN, AL, previous PH usage or leave history.</div></div>';
 customForm('Bulk PH — One Schedule, All Staff',html,'Review Bulk Allocation',async()=>{
  const staffIds=[...document.querySelectorAll('.bulk-staff-check:checked')].map(n=>n.value);
  const year=Number($('bulkYear').value);
  const lines=$('bulkPHRows').value;
  if(!staffIds.length)throw Error('Select at least one staff');
  const holidays=parseHolidaySchedule(lines,year);
  const draft={year,staffIds,lines};
  const count=staffIds.length*holidays.length;
  modal('Confirm PH Batch Allocation',
   'Apply '+holidays.length+' holidays to '+staffIds.length+' staff ('+count+' credit records maximum)? Existing matching holidays will be skipped, so repeat submissions do not double-credit.',
   [{text:'Edit selection',action:()=>openBulkPHDraft(draft)},
    {text:'Apply '+count+' Credits',primary:true,action:async()=>{
     try{
      const result=await call('adminBulkPH',{batch:{year,staffIds,holidays}});
      await reload();
      modal('Bulk PH Complete',
       'Created '+result.created+' credits, skipped '+result.skipped+' existing credits across '+result.staffCount+' staff. Future credits stay locked until their date.',
       [{text:'Done',primary:true}]);
     }catch(e){toast(e.message,true)}
    }}]);
 });
 $('bulkAll').onclick=()=>document.querySelectorAll('.bulk-staff-check').forEach(n=>n.checked=true);
 $('bulkNone').onclick=()=>document.querySelectorAll('.bulk-staff-check').forEach(n=>n.checked=false);
}
function openingBalanceYear(year){
 const people=bulkStaff(), credits=state.overview.phCredits||[];
 return people.map(p=>{
  const records=credits.filter(c=>c.staff_id===p.id&&Number(c.source_year)===year);
  const opening=records.find(c=>c.bulk_key==='OPENING:'+year || (c.holiday_name==='Opening PH Balance '+year&&c.release_mode==='MANUAL'));
  const other=records.filter(c=>c.active&&c.id!==opening?.id).reduce((n,c)=>n+Math.max(0,Number(c.units)-Number(c.reservedUnits||0)),0);
  return {p,opening:opening?.active?Number(opening.units):0,other};
 });
}
function openingBalanceMarkup(year,preset={},selected=new Set()){
 return '<div class="bulk-dialog">'+
 '<p class="muted">Enter the <b>additional approved outstanding PH balance</b> for each staff in '+year+'. It is recorded as a separate historical credit. Existing individual PH credits are shown so you can avoid double counting.</p>'+
 '<div class="field"><label for="openingYear">Source year</label><select id="openingYear">'+
 [2025,2026].map(y=>'<option value="'+y+'" '+(year===y?'selected':'')+'>'+y+'</option>').join('')+'</select></div>'+
 '<div class="section-bar"><div><h3>Select staff to update</h3><p>Only ticked staff will be saved. Unticked staff are not changed.</p></div><div class="staff-actions"><button class="ghost-btn" id="openingSelectAll" type="button">Select All</button><button class="ghost-btn" id="openingSelectNone" type="button">Clear</button></div></div>'+
 '<div class="bulk-fill"><div class="field"><label for="openingFillValue">Same PH balance for selected staff</label><input id="openingFillValue" type="number" min="0" max="30" step="0.5" placeholder="e.g. 2"></div><button class="ghost-btn" id="openingFillAll" type="button">Apply to Selected Staff</button></div>'+
 '<div class="table-wrap"><table class="bulk-ledger"><thead><tr><th>Select</th><th>Staff</th><th>Other PH already credited</th><th>Additional PH balance (days)</th></tr></thead><tbody>'+
 openingBalanceYear(year).map(({p,opening,other})=>
 '<tr><td><input type="checkbox" class="opening-select" data-opening-select="'+esc(p.id)+'" '+(selected.has(p.id)?'checked':'')+' aria-label="Include '+esc(p.name)+' in PH balance changes"></td><td><b>'+esc(p.name)+'</b><div class="muted">'+esc(p.employee_id)+'</div></td>'+
 '<td>'+num(other)+' day(s)</td><td><input type="number" data-opening-staff="'+esc(p.id)+'" min="0" max="30" step="0.5" required value="'+esc(preset[p.id]??opening)+'" aria-label="Historical PH balance for '+esc(p.name)+'"></td></tr>').join('')+
 '</tbody></table></div>'+
 '<div class="soft-note" style="margin-top:12px">Existing opening balances are prefilled. Saving again updates them instead of adding duplicates. Zero deactivates an unused opening credit; used credits cannot be zeroed. For current-year earned PH, the ledger stores the recording date as the as-of date, not as an official holiday.</div></div>';
}
function openHistoricalBulk(year=2025,preset={},selected=null){
 if(state.preview)return toast('Preview is read-only',true);
 if(!bulkStaff().length)return toast('No active staff accounts',true);
 const checked=new Set(selected||[]);
 customForm('Bulk Historical PH Balances',openingBalanceMarkup(year,preset,checked),'Review Historical Balances',async()=>{
  const chosen=Number($('openingYear').value);
  const picked=[...document.querySelectorAll('[data-opening-select]:checked')].map(el=>el.dataset.openingSelect);
  if(!picked.length)throw Error('Select at least one staff to save');
  const balances=picked.map(staffId=>{
   const el=[...document.querySelectorAll('[data-opening-staff]')].find(input=>input.dataset.openingStaff===staffId);
   return {staffId,units:Number(el.value)};
  });
  if(balances.some(b=>!Number.isFinite(b.units)||b.units<0||b.units>30||b.units*2!==Math.trunc(b.units*2)))
   throw Error('Balances must be 0–30 in 0.5-day increments');
  const snapshot=Object.fromEntries([...document.querySelectorAll('[data-opening-staff]')].map(el=>[el.dataset.openingStaff,Number(el.value)]));
  modal('Confirm Historical PH Balances',
   'Save '+chosen+' opening PH credits for '+balances.length+' SELECTED staff only? Other staff will not be changed. Existing individual credits will remain.',
   [{text:'Edit balances',action:()=>openHistoricalBulk(chosen,snapshot,picked)},
    {text:'Save '+balances.length+' Selected Staff',primary:true,action:async()=>{
      try{
       const result=await call('adminBulkHistoricalPH',{batch:{year:chosen,balances}});
       await reload();
       modal('Historical PH Saved',
         'Created '+result.created+', updated '+result.updated+', deactivated '+result.deactivated+' and skipped '+result.skipped+' staff opening records.',
         [{text:'Done',primary:true}]);
      }catch(e){toast(e.message,true)}
    }}]);
 });
 $('openingFillAll').onclick=()=>{
  const el=$('openingFillValue');
  if(!el.value.trim())return toast('Enter PH days before applying to all staff',true);
  const value=Number(el.value);
  if(!Number.isFinite(value)||value<0||value>30||value*2!==Math.trunc(value*2))
   return toast('Use whole or half-day values (0–30)',true);
  const selectedIds=[...document.querySelectorAll('[data-opening-select]:checked')].map(el=>el.dataset.openingSelect);
  if(!selectedIds.length)return toast('Select staff first',true);
  document.querySelectorAll('[data-opening-staff]').forEach(input=>{
   if(selectedIds.includes(input.dataset.openingStaff))input.value=String(value);
  });
  toast('Applied '+value+' day(s) to '+selectedIds.length+' selected staff. Review before saving.');
 };
 $('openingSelectAll').onclick=()=>document.querySelectorAll('[data-opening-select]').forEach(el=>el.checked=true);
 $('openingSelectNone').onclick=()=>document.querySelectorAll('[data-opening-select]').forEach(el=>el.checked=false);
 $('openingYear').onchange=()=>openHistoricalBulk(Number($('openingYear').value));
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
  '<div class="section-bar"><div><h2>Bulk PH Allocation</h2><p>One schedule to all selected staff, or one grid for historical balances.</p></div></div>'+
  '<div class="grid grid-2 bulk-quick-actions">'+
  '<button class="action-card" id="bulkPHBtn"><span class="action-icon">▦</span><span><b>Allocate Annual PH Schedule</b><small>Enter multiple holiday dates → apply to selected staff</small></span></button>'+
  '<button class="action-card" id="openingPHBtn"><span class="action-icon">☷</span><span><b>Historical PH Balances 2025 / 2026</b><small>One 13-staff table → save everything once</small></span></button></div>'+
  '<div class="section-bar"><div><h2>Public Holiday Credit Ledger</h2><p>2025 historical PH may be entered as earned. Future PH remains locked until its date.</p></div><button class="primary-btn" id="addPHBtn">+ Add PH Credit</button></div>'+
  '<div class="filter-bar"><select id="phYearSelector" class="toolbar-select">'+phYearOptions+'</select><select id="phStaffSelector" class="toolbar-select">'+phStaffOptions+'</select></div>'+
  '<div class="card table-wrap">'+(phRows.length?'<table><thead><tr><th>Staff</th><th>Year</th><th>Holiday</th><th>Holiday Date</th><th>Credit</th><th>Reserved</th><th>Status</th><th>Actions</th></tr></thead><tbody>'+phTable+'</tbody></table>':cardEmpty('No PH credits for these filters.'))+'</div>'+
  '<div class="soft-note" style="margin-top:16px">Admin can prepare credits now. Live leave submissions stay locked until 1 January 2027; PH is consumed oldest-first.</div>';
}

function editAL(staffId){
 if(state.preview)return toast('Preview mode is read-only',true);
 const employee=staffById(staffId);
 if(!employee)return toast('Staff not found',true);
 const year=state.alYear;
 const a=(state.overview.alAllocations||[]).find(x=>x.staff_id===staffId&&Number(x.source_year)===year);
 const fields='<p class="muted"><b>'+esc(employee.name)+'</b> · '+esc(employee.employee_id)+' · '+year+'</p>'+
  '<div class="form-grid">'+
  formField('Yearly entitlement (days)','alEnt',a?.entitlement??0,'required min="0" max="365" step="0.5"','number')+
  formField('Carry-forward into '+year,'alCF',a?.carry_forward??0,'required min="0" max="365" step="0.5"','number')+
  formField('Adjustment (+/-)','alAdj',a?.adjustment??0,'required min="-365" max="365" step="0.5"','number')+
  '</div><div class="field"><label for="alNote">Reference / notes</label><textarea id="alNote" maxlength="500">'+esc(a?.notes||'')+'</textarea></div>'+
  '<div class="soft-note" style="margin-top:12px">2027 balances may be prepared now. Staff can use them from January 2027. Credits cannot be reduced below leave already reserved.</div>';
 customForm('Annual Leave '+year,fields,'Save AL',async()=>{
  const ent=Number($('alEnt').value),cf=Number($('alCF').value),adj=Number($('alAdj').value);
  const values=[ent,cf,adj];
  if(values.some(n=>!Number.isFinite(n)||n*2!==Math.trunc(n*2))||ent<0||cf<0||ent+cf+adj<0||ent+cf+adj>365)
    throw Error('AL must be in whole or half days; total must be 0–365.');
  await adminCommit('adminSaveAL',{allocation:{staffId,year,entitlement:ent,carryForward:cf,adjustment:adj,notes:$('alNote').value.trim()}},'AL balance saved');
 });
}
function editPH(creditId=null){
 if(state.preview)return toast('Preview mode is read-only',true);
 const item=creditId?(state.overview.phCredits||[]).find(p=>p.id===creditId):null;
 if(creditId&&!item)return toast('PH credit not found',true);
 const employees=state.overview.employees||[];
 if(!employees.length)return toast('Register a staff account first',true);
 const selectedStaff=item?.staff_id||(state.phStaff==='ALL'?employees[0].id:state.phStaff);
 const year=Number(item?.source_year||(state.phYear==='ALL'?2027:state.phYear));
 const staffOptions=employees.map(p=>'<option value="'+esc(p.id)+'" '+(p.id===selectedStaff?'selected':'')+'>'+esc(p.name)+' · '+esc(p.employee_id)+'</option>').join('');
 const yearOptions=[2025,2026,2027,2028,2029].map(n=>'<option value="'+n+'" '+(n===year?'selected':'')+'>'+n+'</option>').join('');
 const suggestions=commonPH.map(n=>'<option value="'+esc(n)+'"></option>').join('');
 const inputs='<div class="form-grid">'+
  '<div class="field"><label for="phEmployee">Employee</label><select id="phEmployee">'+staffOptions+'</select></div>'+
  '<div class="field"><label for="phSourceYear">Source year</label><select id="phSourceYear">'+yearOptions+'</select></div>'+
  '<div class="field full"><label for="phName">Holiday name</label><input id="phName" list="phList" value="'+esc(item?.holiday_name||'')+'" maxlength="160" placeholder="Name or Additional PH" required><datalist id="phList">'+suggestions+'</datalist></div>'+
  formField('Actual holiday date','phActualDate',item?.holiday_date||'','','date')+
  formField('PH credit (days)','phQuantity',item?.units??1,'min="0.5" max="30" step="0.5" required','number')+
  '<div class="field full"><label for="phReleaseType">Release method</label><select id="phReleaseType"><option value="AUTO_DATE">Auto-unlock on holiday date</option><option value="MANUAL">Already-earned historical PH</option></select></div></div>'+
  '<div class="field"><label for="phNote">Notes / reference</label><textarea id="phNote" maxlength="500">'+esc(item?.notes||'')+'</textarea></div>'+
  '<div class="soft-note" style="margin-top:12px">For 2027 and later PH, choose Auto-unlock and enter the correct date. Do not use Manual for future PH. Historical credits remain usable until consumed.</div>';
 customForm(item?'Edit PH Credit':'Add PH Credit',inputs,item?'Save PH':'Create PH',async()=>{
  const p={
   id:creditId,
   staffId:$('phEmployee').value,
   year:Number($('phSourceYear').value),
   holidayName:$('phName').value.trim(),
   holidayDate:$('phActualDate').value||null,
   units:Number($('phQuantity').value),
   releaseMode:$('phReleaseType').value,
   notes:$('phNote').value.trim()
  };
  if(p.holidayName.length<2||!Number.isFinite(p.units)||p.units<0.5||p.units>30||p.units*2!==Math.trunc(p.units*2))
    throw Error('Enter holiday name and PH days in half-day increments');
  if(p.releaseMode==='AUTO_DATE'&&!p.holidayDate)throw Error('Date required for automatic PH unlock');
  if(p.holidayDate&&Number(p.holidayDate.slice(0,4))!==p.year)throw Error('PH date and source year must match');
  await adminCommit('adminSavePH',{credit:p},'PH credit saved');
 });
 $('phReleaseType').value=item?.release_mode||(year<=2025?'MANUAL':'AUTO_DATE');
}
function togglePH(creditId){
 if(state.preview)return;
 const p=(state.overview.phCredits||[]).find(x=>x.id===creditId);
 if(!p)return toast('PH credit not found',true);
 const next=!p.active;
 modal((next?'Reactivate':'Deactivate')+' PH credit?',
  p.holiday_name+' ('+p.source_year+'). Existing pending or approved PH leave must be preserved.',
  [{text:'Back'},{text:'Confirm',primary:true,action:async()=>{
    try{await call('adminTogglePH',{creditId,active:next});await reload();toast('PH credit status updated')}
    catch(e){toast(e.message,true)}
  }}]);
}

function reports(){
 if(state.user.role!=='ADMIN')return cardEmpty('Admin only');
 const items=[
  ['staff','Employee Directory','Staff details and employment status','users'],
  ['leave','Leave Application Register','AL, PH, EL and Off Day corrections','calendar-days'],
  ['ot','Overtime Register','OT hours, decisions and notes','clock'],
  ['al','Annual Leave Allocation','Entitlement, carry-forward and adjustments','calendar-check'],
  ['ph','Public Holiday Credit Ledger','Historical and future PH credits','calendar-range'],
  ['audit','Admin Activity & Audit','Administration actions and change history','shield-check']
 ];
 return '<div class="hero"><div><span class="eyebrow">ADMIN REPORTING</span><h2>Reports & Audit</h2>'+
  '<p>Download native Excel XLSX reports for operational reconciliation and management review. All data is requested securely from the server.</p></div></div>'+
  '<div class="grid grid-3">'+items.map(([id,label,desc])=>
   '<div class="card"><h3>'+esc(label)+'</h3><p class="muted">'+esc(desc)+'</p>'+
   '<button class="primary-btn" data-admin-report="'+id+'">Export Excel</button></div>').join('')+'</div>'+
  '<div class="soft-note" style="margin-top:20px">Only Admin can generate these reports. Audit records are not editable. CSV exports can be opened in Excel. Restrict report downloads to authorized management and store them securely.</div>';
}
async function exportAdminReport(report){
 if(state.preview||state.user?.role!=='ADMIN')return toast('Admin only',true);
 try{
  toast('Preparing '+report.toUpperCase()+' report…');
  const result=await call('adminReport',{report});
  if(!result.rows?.length)return toast('No records to export');
  downloadTableXlsx('SkyBar_'+report.toUpperCase()+'_'+myDate()+'.xlsx',result.columns,result.rows);
  toast('Report downloaded: '+result.rows.length+' record(s)');
 }catch(e){toast(e.message,true)}
}
function admin(){
  if(state.user.role!=='ADMIN')return cardEmpty('Admin access only.');
  const people=state.overview.employees||[];
  const pend=state.overview.pending||[];
  const adminOt=state.overview.adminOt||[];
  const otRows=adminOt.map(r=>'<tr><td><b>'+esc(r.employee_name)+'</b></td><td>'+fmt(r.ot_date)+'</td>'+
   '<td>'+esc(r.shift_start)+' – '+esc(r.shift_end)+'</td><td>'+num(Number(r.ot_minutes)/60)+'</td>'+
   '<td>'+esc(r.claim_type)+'</td><td>'+status(r.status)+'</td><td><div class="staff-actions">'+
   '<button class="ghost-btn" data-print-admin-ot="'+esc(r.id)+'">Download Form</button>'+
   (r.status==='PENDING'?'<button class="ghost-btn" data-ot-action="'+esc(r.id)+'" data-ot-decision="APPROVED">Approve</button>'+
    '<button class="ghost-btn" data-ot-action="'+esc(r.id)+'" data-ot-decision="REJECTED">Reject</button>':'')+
   '</div></td></tr>').join('');
  const allLeaves=(state.overview.adminLeaves||[]).filter(r=>['PENDING','APPROVED'].includes(r.status));
  const leaveRows=allLeaves.map(r=>'<tr><td><b>'+esc(r.employee_name)+'</b><div class="muted">'+esc(r.request_code||'')+'</div></td>'+
  '<td>'+fmt(r.start_date)+' – '+fmt(r.end_date)+'</td><td>'+esc(types[r.leave_type]||r.leave_type)+'</td>'+
  '<td>'+num(r.units)+'</td><td>'+status(r.status)+'</td><td><button class="ghost-btn" data-edit-leave-type="'+esc(r.id)+'">Edit Type</button></td></tr>').join('');
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
      pend.map(r=>'<tr><td>'+esc(r.employee_name)+'</td><td>'+fmt(r.start_date)+' – '+fmt(r.end_date)+'</td><td>'+esc(types[r.leave_type]||r.leave_type)+'</td><td>'+esc(r.reason)+'</td><td><div class="staff-actions"><button class="ghost-btn" data-decision="'+esc(r.id)+'" data-status="APPROVED">Approve</button><button class="ghost-btn" data-decision="'+esc(r.id)+'" data-status="REJECTED">Reject</button><button class="ghost-btn" data-edit-leave-type="'+esc(r.id)+'">Edit Type</button></div></td></tr>').join('')+'</tbody></table>':
      cardEmpty('No pending requests.'))+'</div>'+
    title('Admin Leave Corrections')+
    '<p class="muted">Only Admin may convert Pending/Approved leave into AL, PH, EL or Off Day (OFF). OFF does not deduct AL or PH but still counts towards the daily two-person limit.</p>'+
    '<div class="card table-wrap">'+(leaveRows?
    '<table><thead><tr><th>Employee / Ref</th><th>Leave Dates</th><th>Type</th><th>Days</th><th>Status</th><th>Admin Action</th></tr></thead><tbody>'+leaveRows+'</tbody></table>':
    cardEmpty('No pending or approved leave requests yet.'))+'</div>'+
    '<div class="section-bar"><h2>OT Approval & Reporting</h2><button id="exportOTBtn" class="primary-btn">Export OT Excel</button></div>'+
    '<div class="card table-wrap">'+(adminOt.length?'<table><thead><tr><th>Staff</th><th>Date</th><th>Shift</th><th>OT Hours</th><th>Claim Type</th><th>Status</th><th>Actions</th></tr></thead><tbody>'+otRows+'</tbody></table>':
      cardEmpty('No overtime submissions yet.'))+'</div>'+
    '<div class="section-bar"><div><h3>HR Overtime Form Template</h3><p>One approved template for every staff OT download.</p></div><button id="uploadOTTemplateBtn" class="ghost-btn">Upload / Replace Template</button></div>'+
    '<div class="soft-note" style="margin:16px 0">Admin can approve or reject pending OT, download original-layout monthly OT forms, or export Excel reports. Upload an approved, macro-free .xlsx form once to activate the shared download template.</div>';
}


function uploadOTTemplate(){
 if(state.user?.role!=='ADMIN'||state.preview)return toast('Admin only',true);
 const html='<p class="muted">Upload the original HR <b>Overtime Form.xls</b> through Microsoft Excel <b>Save As → .xlsx</b> (no macros). The system checks the original layout, 16th–15th period sections, logo and print settings, then uses the same template for every staff. Maximum 2 MB.</p>'+
 '<div class="field"><label for="otMasterFile">Approved OT Excel template (.xlsx)</label><input type="file" id="otMasterFile" accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" required></div>'+
 '<div class="soft-note">Do not upload the previously recreated approximation. Save the ORIGINAL .xls using Microsoft Excel to preserve its native layout. The source workbook contains VBA; only a macro-free .xlsx is allowed. A template replacement is audited.</div>';
 customForm('Admin · Replace HR Overtime Form Template',html,'Upload & Activate Template',async()=>{
   const file=$('otMasterFile').files?.[0];
   if(!file||!file.name.toLowerCase().endsWith('.xlsx'))throw Error('Select an .xlsx file');
   if(file.size<300||file.size>2097152)throw Error('Template must be 300 bytes to 2 MB');
   const bytes=new Uint8Array(await file.arrayBuffer());
   if(bytes[0]!==80||bytes[1]!==75||bytes[2]!==3||bytes[3]!==4)throw Error('Invalid Excel XLSX format');
   if(!window.SKYBAR_OT_FORM_GENERATOR)throw Error('OT template validator missing');
   await window.SKYBAR_OT_FORM_GENERATOR.validateTemplate(bytes.buffer);
   let text='';
   for(let i=0;i<bytes.length;i+=12000)text+=String.fromCharCode(...bytes.subarray(i,i+12000));
   const base64=btoa(text);
   await adminCommit('adminUploadOTTemplate',{filename:file.name,base64},'HR OT template updated for all staff');
 });
}
async function printOT(id,admin=false){
 if(state.preview)return toast('Preview is read-only',true);
 const all=admin?(state.overview.adminOt||[]):(state.overview.ot||[]);
 const selected=all.find(r=>r.id===id);
 if(!selected)return toast('OT request not found',true);
 const employee=admin?staffById(selected.staff_id):state.user;
 if(!employee)return toast('Employee profile not found',true);
 try{
  if(!window.SKYBAR_OT_FORM_GENERATOR)throw Error('OT form exporter is not loaded');
  toast('Preparing original-layout OT Excel form…');
  const result=await window.SKYBAR_OT_FORM_GENERATOR.download({
    selected,records:all,employee,preparedBy:state.user.name,
    loadTemplate:()=>call('getOTTemplate')
  });
  toast('OT form ready: '+result.count+' claim(s) · '+result.periodStart+' to '+result.periodEnd);
 }catch(e){toast(e?.message||'Failed to create OT form',true)}
}
function otStatusAction(id,decision){
 if(state.preview||state.user?.role!=='ADMIN')return toast('Admin access only',true);
 const item=(state.overview.adminOt||[]).find(x=>x.id===id);
 if(!item||item.status!=='PENDING')return toast('Only pending OT may be decided',true);
 if(!['APPROVED','REJECTED'].includes(decision))return;
 const form='<p class="muted">'+esc(item.employee_name)+' · '+fmt(item.ot_date)+' · '+num(item.ot_minutes/60)+' OT hours</p>'+
 '<div class="field"><label for="otNote">Admin note '+(decision==='REJECTED'?'(required)':'(optional)')+'</label><textarea id="otNote" maxlength="500"></textarea></div>';
 customForm((decision==='APPROVED'?'Approve':'Reject')+' Overtime',form,'Confirm Decision',async()=>{
  const note=$('otNote').value.trim();
  if(decision==='REJECTED'&&note.length<3)throw Error('Rejection requires a reason');
  await adminCommit('decideOT',{requestId:id,status:decision,note},'Overtime '+decision.toLowerCase());
 });
}
function cancelOT(id){
 modal('Cancel pending overtime?','This will cancel the pending OT record, not delete it.',[
  {text:'Keep OT'},
  {text:'Cancel OT',primary:true,action:async()=>{
   try{await call('cancelOT',{requestId:id});await reload();toast('OT cancelled')}
   catch(e){toast(e.message,true)}
  }}
 ]);
}

function xlsxBlob(headers,rows){
 const enc=new TextEncoder(),xml=s=>String(s??'').replace(/[&<>"']/g,v=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[v]));
 const column=n=>{let s='';do{s=String.fromCharCode(65+n%26)+s;n=Math.floor(n/26)-1}while(n>=0);return s};
 const data=[headers,...rows];
 const table=data.map((line,i)=>'<row r="'+(i+1)+'">'+line.map((v,j)=>{
  const ref=column(j)+(i+1);
  return typeof v==='number'&&Number.isFinite(v)?
   '<c r="'+ref+'"><v>'+v+'</v></c>':
   '<c r="'+ref+'"'+(i===0?' s="1"':'')+' t="inlineStr"><is><t xml:space="preserve">'+xml(v)+'</t></is></c>';
 }).join('')+'</row>').join('');
 const head='<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
 const main='http://schemas.openxmlformats.org/spreadsheetml/2006/main';
 const worksheet=head+'<worksheet xmlns="'+main+'"><dimension ref="A1:'+column(headers.length-1)+data.length+'"/>'+
 '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>'+
 '<cols>'+headers.map((_,i)=>'<col min="'+(i+1)+'" max="'+(i+1)+'" width="22" customWidth="1"/>').join('')+'</cols>'+
 '<sheetData>'+table+'</sheetData><autoFilter ref="A1:'+column(headers.length-1)+data.length+'"/></worksheet>';
 const styles=head+'<styleSheet xmlns="'+main+'"><fonts count="2"><font><sz val="11"/><name val="Aptos"/></font><font><b/><color rgb="FFFFFFFF"/><sz val="11"/><name val="Aptos"/></font></fonts>'+
 '<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF10223B"/><bgColor indexed="64"/></patternFill></fill></fills>'+
 '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'+
 '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'+
 '<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/></cellXfs>'+
 '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>';
 const entries=[
 ['[Content_Types].xml',head+'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>'],
 ['_rels/.rels',head+'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'],
 ['xl/workbook.xml',head+'<workbook xmlns="'+main+'" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="SkyBar Report" sheetId="1" r:id="rId1"/></sheets></workbook>'],
 ['xl/_rels/workbook.xml.rels',head+'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>'],
 ['xl/worksheets/sheet1.xml',worksheet],['xl/styles.xml',styles]
 ];
 const crcTable=new Uint32Array(256);for(let i=0;i<256;i++){let v=i;for(let k=0;k<8;k++)v=(v&1)?(0xedb88320^(v>>>1)):(v>>>1);crcTable[i]=v>>>0}
 const crc32=b=>{let c=0xffffffff;for(const n of b)c=crcTable[(c^n)&255]^(c>>>8);return(c^0xffffffff)>>>0};
 const u16=(a,v)=>a.push(v&255,(v>>>8)&255),u32=(a,v)=>a.push(v&255,(v>>>8)&255,(v>>>16)&255,(v>>>24)&255);
 const chunks=[],central=[];let offset=0;
 for(const [name,value] of entries){
  const n=enc.encode(name),b=enc.encode(value),crc=crc32(b),local=[],dir=[];
  u32(local,0x04034b50);u16(local,20);u16(local,0x800);u16(local,0);u16(local,0);u16(local,0);
  u32(local,crc);u32(local,b.length);u32(local,b.length);u16(local,n.length);u16(local,0);
  chunks.push(Uint8Array.from(local),n,b);
  u32(dir,0x02014b50);u16(dir,20);u16(dir,20);u16(dir,0x800);u16(dir,0);u16(dir,0);u16(dir,0);
  u32(dir,crc);u32(dir,b.length);u32(dir,b.length);u16(dir,n.length);u16(dir,0);u16(dir,0);
  u16(dir,0);u16(dir,0);u32(dir,0);u32(dir,offset);
  central.push(Uint8Array.from(dir),n);offset+=local.length+n.length+b.length;
 }
 const dirSize=central.reduce((acc,b)=>acc+b.length,0),end=[];
 u32(end,0x06054b50);u16(end,0);u16(end,0);u16(end,entries.length);u16(end,entries.length);
 u32(end,dirSize);u32(end,offset);u16(end,0);
 return new Blob([...chunks,...central,Uint8Array.from(end)],
  {type:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'});
}
function downloadTableXlsx(filename,headers,rows){
 const blob=xlsxBlob(headers,rows),url=URL.createObjectURL(blob);
 const el=document.createElement('a');el.href=url;el.download=filename;document.body.append(el);el.click();el.remove();
 setTimeout(()=>URL.revokeObjectURL(url),5000);
}
function safeCsvCell(value){
 let s=String(value??'');
 if(/^\s*[=+\-@\t\r]/.test(s))s="'"+s;
 return '"'+s.replace(/"/g,'""')+'"';
}
function downloadTableCsv(filename,headers,rows){
 const body='\uFEFF'+[headers,...rows].map(r=>r.map(safeCsvCell).join(',')).join('\r\n');
 const blob=new Blob([body],{type:'text/csv;charset=utf-8'});
 const url=URL.createObjectURL(blob),el=document.createElement('a');
 el.href=url;el.download=filename;document.body.appendChild(el);el.click();el.remove();
 setTimeout(()=>URL.revokeObjectURL(url),5000);
}
function exportOT(){
 if(state.preview||state.user?.role!=='ADMIN')return toast('Admin only',true);
 const data=state.overview.adminOt||[];
 if(!data.length)return toast('No OT records to export',true);
 downloadTableXlsx('SkyBar_OT_'+myDate()+'.xlsx',
  ['Employee ID','Employee','OT Date','Shift Start','Shift End','Total Shift (hours)','OT Hours','Claim Type','Status','Reason','Admin Note'],
  data.map(r=>{const p=staffById(r.staff_id);return[
    p?.employee_id||'',r.employee_name||'',r.ot_date,r.shift_start,r.shift_end,
    (Number(r.total_shift_minutes)/60).toFixed(2),(Number(r.ot_minutes)/60).toFixed(2),
    r.claim_type,r.status,r.reason,r.admin_note||''
  ]}));
 toast('OT report exported as Excel XLSX');
}
function editLeaveType(requestId){
 if(state.preview)return toast('Preview is read-only',true);
 if(state.user?.role!=='ADMIN')return toast('Admin access only',true);
 const r=(state.overview?.adminLeaves||[]).find(x=>x.id===requestId);
 if(!r)return toast('Leave request not found',true);
 if(!['PENDING','APPROVED'].includes(r.status))return toast('Only active requests can be edited',true);
 const options=['AL','PH','EL','OFF'].map(t=>'<option value="'+t+'" '+(r.leave_type===t?'selected':'')+'>'+esc(types[t])+'</option>').join('');
 const html='<div class="soft-note">Employee: <b>'+esc(r.employee_name)+'</b> · '+esc(r.request_code||'')+
 '<div>Leave dates: '+fmt(r.start_date)+' – '+fmt(r.end_date)+' · '+num(r.units)+' day(s) · '+esc(r.status)+'</div></div>'+
 '<div class="field"><label for="adminLeaveType">Correct leave type</label><select id="adminLeaveType">'+options+'</select></div>'+
 '<div class="field"><label for="leaveAdminReason">Reason for Admin correction (required)</label>'+
 '<textarea id="leaveAdminReason" maxlength="500" placeholder="Reason for changing leave classification"></textarea></div>'+
 '<div class="soft-note">AL uses available AL days; PH uses oldest eligible credits; Off Day (OFF) uses neither. Approval status and calendar slot are preserved. Staff cannot select OFF.</div>';
 customForm('Admin · Edit Leave Type',html,'Review Change',async()=>{
   const leaveType=$('adminLeaveType').value, note=$('leaveAdminReason').value.trim();
   if(leaveType===r.leave_type)throw Error('Choose a different leave type');
   if(note.length<3)throw Error('Enter admin reason (at least 3 characters)');
   modal('Confirm Leave Reclassification',
    r.employee_name+': '+types[r.leave_type]+' → '+types[leaveType]+'. AL/PH credits will be recalculated and '+r.status+' status kept. Reason: '+note,
    [{text:'Back',action:()=>editLeaveType(requestId)},
     {text:'Confirm Change',primary:true,action:async()=>{
      try{
       const result=await call('adminChangeLeaveType',{requestId,leaveType,note});
       await reload();
       toast('Leave type updated: '+result.previousType+' → '+result.newType);
      }catch(e){toast(e.message,true)}
     }}]);
 });
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
function render(){const names={overview:'Overview',leave:'Leave Request',calendar:'Leave Calendar',overtime:'Overtime',history:'My Requests',balances:'AL & PH Management',reports:'Reports & Audit',admin:'Administration'};$('pageHeading').textContent=names[state.view]||'Overview';$('view').innerHTML=({overview,leave:requestForm,calendar,overtime,history,balances,reports,admin}[state.view]||overview)();document.querySelectorAll('[data-go]').forEach(x=>x.addEventListener('click',()=>navigate(x.dataset.go)));$('leaveForm')?.addEventListener('submit',onLeave);$('otForm')?.addEventListener('submit',onOt);$('shiftStart')?.addEventListener('input',refreshOt);$('shiftEnd')?.addEventListener('input',refreshOt);document.querySelectorAll('[data-cancel]').forEach(x=>x.onclick=()=>modal('Cancel leave request?','This pending leave request will be cancelled and its daily slots released.',[{text:'Keep request'},{text:'Cancel request',primary:true,action:async()=>{try{await call('cancelLeave',{requestId:x.dataset.cancel});await reload();toast('Request cancelled')}catch(e){toast(e.message,true)}}}]));$('alYearSelector')?.addEventListener('change',e=>{state.alYear=Number(e.target.value);render()});
$('phYearSelector')?.addEventListener('change',e=>{state.phYear=e.target.value;render()});
$('phStaffSelector')?.addEventListener('change',e=>{state.phStaff=e.target.value;render()});
$('bulkPHBtn')?.addEventListener('click',()=>openBulkPHDraft());
$('openingPHBtn')?.addEventListener('click',()=>openHistoricalBulk());
$('addPHBtn')?.addEventListener('click',()=>editPH());
document.querySelectorAll('[data-edit-al]').forEach(x=>x.onclick=()=>editAL(x.dataset.editAl));
document.querySelectorAll('[data-edit-ph]').forEach(x=>x.onclick=()=>editPH(x.dataset.editPh));
document.querySelectorAll('[data-toggle-ph]').forEach(x=>x.onclick=()=>togglePH(x.dataset.togglePh));
document.querySelectorAll('[data-edit-leave-type]').forEach(x=>x.onclick=()=>editLeaveType(x.dataset.editLeaveType));
document.querySelectorAll('[data-admin-report]').forEach(el=>el.onclick=()=>exportAdminReport(el.dataset.adminReport));
$('exportOTBtn')?.addEventListener('click',exportOT);
document.querySelectorAll('[data-ot-action]').forEach(el=>el.onclick=()=>otStatusAction(el.dataset.otAction,el.dataset.otDecision));
$('uploadOTTemplateBtn')?.addEventListener('click',uploadOTTemplate);
document.querySelectorAll('[data-print-admin-ot]').forEach(el=>el.onclick=()=>printOT(el.dataset.printAdminOt,true));
document.querySelectorAll('[data-print-ot]').forEach(el=>el.onclick=()=>printOT(el.dataset.printOt,false));
document.querySelectorAll('[data-cancel-ot]').forEach(el=>el.onclick=()=>cancelOT(el.dataset.cancelOt));
$('addStaffBtn')?.addEventListener('click',()=>editStaff());
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