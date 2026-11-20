/* SkyBar OT Excel generator: uses the original-layout, macro-free workbook template.
 * All assembly happens in the user's browser. No remote spreadsheet service.
 * Template is retrieved from the authenticated Supabase Edge API after Admin upload.
 * Template rebuilt from user-supplied legacy .xls; original VBA is intentionally excluded.
 */
(() => {
'use strict';
const NS='http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const te=new TextEncoder();
const td=new TextDecoder('utf-8');
const uint16=(v,o)=>v.getUint16(o,true),uint32=(v,o)=>v.getUint32(o,true);
const write16=(arr,n)=>arr.push(n&255,(n>>>8)&255);
const write32=(arr,n)=>arr.push(n&255,(n>>>8)&255,(n>>>16)&255,(n>>>24)&255);
const crcTable=Array.from({length:256},(_,k)=>{
 let v=k;for(let i=0;i<8;i++)v=(v&1)?((v>>>1)^0xedb88320):(v>>>1);return v>>>0
});
const crc32=bytes=>{
 let c=0xffffffff;for(let i=0;i<bytes.length;i++)c=crcTable[(c^bytes[i])&255]^(c>>>8);
 return (c^0xffffffff)>>>0;
};
const concat=chunks=>{
 const bytes=chunks.reduce((s,a)=>s+a.length,0),out=new Uint8Array(bytes);
 let p=0;for(const x of chunks){out.set(x,p);p+=x.length}return out;
};
async function unpack(buf){
 const raw=new Uint8Array(buf),view=new DataView(buf),files=[];
 let pos=0;
 while(pos+30<=raw.length && uint32(view,pos)===0x04034b50){
  const method=uint16(view,pos+8),flags=uint16(view,pos+6);
  const compressedSize=uint32(view,pos+18);
  const filenameLength=uint16(view,pos+26),extraLength=uint16(view,pos+28);
  if(flags&8)throw Error('Unsupported OT template ZIP descriptor');
  const start=pos+30+filenameLength+extraLength;
  const end=start+compressedSize;
  if(end>raw.length)throw Error('Truncated OT workbook');
  const name=td.decode(raw.slice(pos+30,pos+30+filenameLength));
  const bytes=raw.slice(start,end);
  let content;
  if(method===0)content=bytes;
  else if(method===8){
   if(typeof DecompressionStream==='undefined')throw Error('Browser requires ZIP decompression support');
   const output=new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
   content=new Uint8Array(await new Response(output).arrayBuffer());
  } else throw Error('Unsupported OT workbook compression: '+method);
  files.push({name,data:content});
  pos=end;
 }
 if(!files.some(f=>f.name==='xl/worksheets/sheet1.xml'))throw Error('Original OT worksheet missing');
 return files;
}
function pack(files){
 const content=[],directory=[];
 let offset=0;
 for(const {name,data} of files){
  const nm=te.encode(name),body=data instanceof Uint8Array?data:te.encode(data),crc=crc32(body);
  const local=[],central=[];
  write32(local,0x04034b50);write16(local,20);write16(local,0x800);
  write16(local,0);write16(local,0);write16(local,0);
  write32(local,crc);write32(local,body.length);write32(local,body.length);
  write16(local,nm.length);write16(local,0);
  content.push(Uint8Array.from(local),nm,body);
  write32(central,0x02014b50);write16(central,20);write16(central,20);
  write16(central,0x800);write16(central,0);write16(central,0);write16(central,0);
  write32(central,crc);write32(central,body.length);write32(central,body.length);
  write16(central,nm.length);write16(central,0);write16(central,0);
  write16(central,0);write16(central,0);write32(central,0);write32(central,offset);
  directory.push(Uint8Array.from(central),nm);
  offset+=local.length+nm.length+body.length;
 }
 const directorySize=directory.reduce((n,b)=>n+b.length,0),end=[];
 write32(end,0x06054b50);write16(end,0);write16(end,0);
 write16(end,files.length);write16(end,files.length);
 write32(end,directorySize);write32(end,offset);write16(end,0);
 return new Blob([...content,...directory,Uint8Array.from(end)],{
  type:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
 });
}
function toISO(date){
 const y=date.getFullYear(),m=String(date.getMonth()+1).padStart(2,'0');
 const d=String(date.getDate()).padStart(2,'0');
 return y+'-'+m+'-'+d;
}
function niceDate(date){
 return date.toLocaleDateString('en-MY',{day:'2-digit',month:'short',year:'numeric'});
}
function time(value){
 if(!value)return '';
 const text=String(value).slice(0,5);
 return /^\d{2}:\d{2}$/.test(text)?text:'';
}
function plusNine(start){
 const s=time(start);if(!s)return '';
 const [h,m]=s.split(':').map(Number),t=(h*60+m+540)%1440;
 return String(Math.floor(t/60)).padStart(2,'0')+':'+String(t%60).padStart(2,'0');
}
function getPeriod(dateText){
 const d=new Date(dateText+'T12:00:00');
 if(Number.isNaN(d.getTime()))throw Error('Invalid OT date');
 const from=new Date(d.getFullYear(),d.getMonth()-(d.getDate()<=10?1:0),11);
 const to=new Date(from.getFullYear(),from.getMonth()+1,10);
 return {from,to,dates:Array.from({length:31},(_,i)=>{
  const day=new Date(from.getFullYear(),from.getMonth(),from.getDate()+i);
  return day<=to?day:null
 }).filter(Boolean)};
}
function updateSheet(xml,entries){
 const doc=new DOMParser().parseFromString(xml,'application/xml');
 if(doc.querySelector('parsererror'))throw Error('Invalid OT worksheet XML');
 const sheetData=doc.getElementsByTagNameNS(NS,'sheetData')[0];
 if(!sheetData)throw Error('Missing worksheet cells');
 const rows=new Map([...sheetData.getElementsByTagNameNS(NS,'row')].map(e=>[Number(e.getAttribute('r')),e]));
 const xmlSpace='http://www.w3.org/XML/1998/namespace';
 const parseCell=ref=>{const m=/^([A-Z]+)([1-9]\d*)$/.exec(ref);if(!m)throw Error('Invalid cell '+ref);return Number(m[2])};
 const set=(ref,v)=>{
  const rn=parseCell(ref);
  let row=rows.get(rn);
  if(!row){row=doc.createElementNS(NS,'row');row.setAttribute('r',String(rn));sheetData.append(row);rows.set(rn,row)}
  let cell=[...row.children].find(x=>x.localName==='c'&&x.getAttribute('r')===ref);
  if(!cell){cell=doc.createElementNS(NS,'c');cell.setAttribute('r',ref);row.append(cell)}
  // Keep original cell style, borders, merges, formulas on unaffected cells, and print settings.
  while(cell.firstChild)cell.removeChild(cell.firstChild);
  if(v===null||v===undefined||v===''){cell.removeAttribute('t');return;}
  if(typeof v==='number'&&Number.isFinite(v)){
   cell.removeAttribute('t');
   const node=doc.createElementNS(NS,'v');node.textContent=String(v);cell.append(node);
  }else{
   cell.setAttribute('t','inlineStr');
   const i=doc.createElementNS(NS,'is'),t=doc.createElementNS(NS,'t');
   t.setAttributeNS(xmlSpace,'xml:space','preserve');t.textContent=String(v);
   i.append(t);cell.append(i);
  }
 };
 for(const [ref,val] of Object.entries(entries))set(ref,val);
 return new XMLSerializer().serializeToString(doc);
}
async function download({selected,records,employee,preparedBy,loadTemplate}){
 if(!selected?.ot_date)throw Error('OT record not found');
 const {from,to,dates}=getPeriod(selected.ot_date);
 const source=(records||[]).filter(r=>
  r.staff_id===selected.staff_id &&
  r.ot_date>=toISO(from)&&r.ot_date<=toISO(to)&&r.status!=='CANCELLED'
 );
 const byDay=new Map();
 for(const row of source){
  const day=row.ot_date;
  if(byDay.has(day))throw Error('Multiple OT claims on '+day+'. Use OT Excel report to avoid omitting any claim.');
  byDay.set(day,row);
 }
 if(typeof loadTemplate!=='function')throw Error('OT template service not configured');
 const template=await loadTemplate();
 const encoded=String(template?.base64||'').replace(/\s/g,'');
 if(!encoded||encoded.length>2800000)throw Error('Missing or oversized HR OT template');
 let raw;
 try{raw=Uint8Array.from(atob(encoded),v=>v.charCodeAt(0))}
 catch{throw Error('Corrupted HR OT template');}
 const files=await unpack(raw.buffer);
 const sheet=files.find(f=>f.name==='xl/worksheets/sheet1.xml');
 const filled={
  N6:'From * '+niceDate(from),S6:'To * '+niceDate(to),
  C8:employee?.name||selected.employee_name||'',I8:employee?.position||'',
  R8:preparedBy||'',C10:employee?.employee_id||'',I10:employee?.department||'SkyBar',
  R10:niceDate(new Date()),
  A15:from.toLocaleDateString('en-MY',{month:'short',year:'numeric'}),
  A36:to.toLocaleDateString('en-MY',{month:'short',year:'numeric'})
 };
 for(let i=0;i<31;i++){
  const rn=15+i,date=dates[i];
  if(!date)continue;
  const key=toISO(date),row=byDay.get(key);
  filled['B'+rn]=date.getDate();
  if(!row)continue;
  filled['C'+rn]=time(row.shift_start);
  filled['D'+rn]=time(row.shift_end);
  filled['E'+rn]=plusNine(row.shift_start);
  filled['F'+rn]=time(row.shift_end);
  const hours=Math.round(Number(row.ot_minutes||0)/60*100)/100;
  const claim=String(row.claim_type||'').toUpperCase();
  if(claim==='OFF'){filled['H'+rn]=hours;filled['R'+rn]=1}
  else if(claim==='PH'){filled['I'+rn]=hours;filled['S'+rn]=1}
  else filled['G'+rn]=hours;
  // No night-shift, split-shift or certification values are fabricated.
 }
 sheet.data=te.encode(updateSheet(td.decode(sheet.data),filled));
 const result=pack(files),url=URL.createObjectURL(result);
 const name=(employee?.employee_id||'STAFF').replace(/[^A-Za-z0-9_-]/g,'');
 const filename='SkyBar_Original_OT_Form_'+name+'_'+toISO(from)+'_to_'+toISO(to)+'.xlsx';
 const a=document.createElement('a');a.href=url;a.download=filename;
 document.body.append(a);a.click();a.remove();
 setTimeout(()=>URL.revokeObjectURL(url),5000);
 return {filename,count:source.length,periodStart:toISO(from),periodEnd:toISO(to)};
}
window.SKYBAR_OT_FORM_GENERATOR=Object.freeze({download});
})();