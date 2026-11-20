/* SkyBar OT Excel generator: uses the original-layout, macro-free workbook template.
 * All assembly happens in the user's browser. No remote spreadsheet service.
 * Template is retrieved from the authenticated Supabase Edge API after Admin upload.
 * Preserve every original workbook part/format/logo exactly as in Excel-saved .xlsx; only OT data cells change. VBA from legacy .xls is excluded.
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
 let eocd=-1;
 // The central directory is authoritative even when Excel uses ZIP data descriptors.
 for(let i=raw.length-22;i>=Math.max(0,raw.length-65557);i--){
  if(uint32(view,i)===0x06054b50){eocd=i;break}
 }
 if(eocd<0)throw Error('Invalid Excel ZIP file');
 const count=uint16(view,eocd+10),offset=uint32(view,eocd+16);
 if(count>1000||offset>=raw.length)throw Error('Invalid Excel ZIP directory');
 let pos=offset,total=0;
 for(let i=0;i<count;i++){
  if(pos+46>raw.length||uint32(view,pos)!==0x02014b50)throw Error('Invalid workbook ZIP entry');
  const method=uint16(view,pos+10);
  const csize=uint32(view,pos+20),usize=uint32(view,pos+24);
  const namelen=uint16(view,pos+28),extlen=uint16(view,pos+30),comment=uint16(view,pos+32);
  const localOffset=uint32(view,pos+42);
  const name=td.decode(raw.slice(pos+46,pos+46+namelen));
  pos+=46+namelen+extlen+comment;
  if(!name||name.endsWith('/'))continue;
  if(usize>10000000||(total+=usize)>30000000)throw Error('OT workbook exceeds safe size limit');
  if(localOffset+30>raw.length||uint32(view,localOffset)!==0x04034b50)
    throw Error('Invalid OT workbook data offset');
  const localNameLength=uint16(view,localOffset+26);
  const localExtraLength=uint16(view,localOffset+28);
  const start=localOffset+30+localNameLength+localExtraLength;
  const end=start+csize;
  if(end>raw.length)throw Error('Truncated OT workbook');
  const bytes=raw.slice(start,end);
  let body;
  if(method===0)body=bytes;
  else if(method===8){
   if(typeof DecompressionStream==='undefined')throw Error('Download requires modern Chrome or Edge');
   try{
    const stream=new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
    body=new Uint8Array(await new Response(stream).arrayBuffer());
   }catch{throw Error('Cannot unpack workbook. Save the original template as .xlsx using Excel.')}
  }else throw Error('Unsupported workbook compression method '+method);
  if(body.length!==usize)throw Error('Incomplete OT template content');
  files.push({name,data:body});
 }
 if(!files.some(f=>f.name==='xl/worksheets/sheet1.xml'))throw Error('OT template must have its main sheet in sheet1.xml');
 return files;
}
async function validateTemplate(buffer){
 const files=await unpack(buffer);
 const sheet=files.find(f=>f.name==='xl/worksheets/sheet1.xml');
 const drawings=files.some(f=>f.name.startsWith('xl/drawings/'));
 const logo=files.some(f=>/^xl\/media\/[^/]+\.(png|jpe?g)$/i.test(f.name));
 const margins=files.some(f=>f.name==='xl/styles.xml');
 if(!drawings||!logo||!margins)throw Error('OT template must retain original hotel logo, drawings and Excel styles');
 const root=new DOMParser().parseFromString(td.decode(sheet.data),'application/xml');
 if(root.querySelector('parsererror'))throw Error('Invalid OT sheet XML');
 const merges=new Set([...root.getElementsByTagNameNS(NS,'mergeCell')].map(el=>el.getAttribute('ref')));
 for(const ref of ['A15:A30','A31:A45','A12:B14','C12:D13','G12:I13','C8:E8','C10:E10','R8:U8']){
  if(!merges.has(ref))throw Error('This workbook does not match the original 16th–15th OT sheet layout ('+ref+')');
 }
 const cells=[...root.getElementsByTagNameNS(NS,'c')];
 const headerCell=cells.find(el=>el.getAttribute('r')==='A6');
 let title=headerCell?.textContent?.trim()||'';
 if(headerCell?.getAttribute('t')==='s'){
  const strings=files.find(f=>f.name==='xl/sharedStrings.xml');
  if(!strings)throw Error('Source workbook is missing shared strings');
  const doc=new DOMParser().parseFromString(td.decode(strings.data),'application/xml');
  const si=[...doc.getElementsByTagNameNS(NS,'si')];
  const idx=Number(headerCell.getElementsByTagNameNS(NS,'v')[0]?.textContent);
  title=si[idx]?.textContent?.trim()||'';
 }
 if(!/^OVERTIME\s*\(OT\)$/i.test(title))throw Error('Upload the actual HR OT template saved from the original .xls; reconstructed layouts are not accepted');
 if(!root.getElementsByTagNameNS(NS,'pageMargins').length||
    !root.getElementsByTagNameNS(NS,'pageSetup').length)
  throw Error('Original Excel print margins or page setup are missing. Re-save the original .xls in Microsoft Excel.');
 return {files,title,mergedCells:merges.size};
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
 // EXACT original HR form: 16th of first month to 15th of following month.
 const from=new Date(d.getFullYear(),d.getMonth()-(d.getDate()<16?1:0),16);
 const to=new Date(from.getFullYear(),from.getMonth()+1,15);
 const nextMonth=new Date(from.getFullYear(),from.getMonth()+1,1);
 return {from,to,nextMonth};
}
function excelDate(date){
 return (Date.UTC(date.getFullYear(),date.getMonth(),date.getDate())-Date.UTC(1899,11,30))/86400000;
}
function originalTime(value){
 const t=time(value);if(!t)return '';
 const [h,m]=t.split(':').map(Number);
 const suffix=h===0&&m===0?'mn':h<12?'am':'pm';
 const hour=h%12||12;
 return hour+'.'+String(m).padStart(2,'0')+suffix;
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
 const {from,to,nextMonth}=getPeriod(selected.ot_date);
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
 const {files}=await validateTemplate(raw.buffer);
 const sheet=files.find(f=>f.name==='xl/worksheets/sheet1.xml');
 // Keep the original Excel sheet, logo, fonts, colors, borders, merge ranges,
 // original HR wording, approval signatures and print settings unchanged.
 // Only replace input cells that the HR form expects us to fill.
 const filled={
  N6:niceDate(from),S6:niceDate(to),
  C8:employee?.name||selected.employee_name||'',I8:employee?.position||'',
  R8:preparedBy||'',C10:employee?.employee_id||'',
  I10:employee?.department||'SkyBar',R10:niceDate(new Date()),
  A15:excelDate(from),A31:excelDate(nextMonth)
 };
 const otColumns=['C','D','E','F','G','H','I','K','L','M','N','P','R','S','U'];
 // Remove sample/manual entries in the approved master, not formatting.
 for(let rn=15;rn<=45;rn++){
  filled['B'+rn]='';
  for(const col of otColumns)filled[col+rn]='';
 }
 // Source form fixes rows 15-30 to day 16-31 of first month and
 // rows 31-45 to day 01-15 of next month. Blank unused days to retain
 // EVERY original merge range and row height for short months.
 const firstMonthLast=new Date(from.getFullYear(),from.getMonth()+1,0).getDate();
 for(let day=16;day<=firstMonthLast;day++){
  const date=new Date(from.getFullYear(),from.getMonth(),day);
  const rn=15+(day-16);
  filled['B'+rn]=day;
  const row=byDay.get(toISO(date));
  if(row)fillRow(rn,row);
 }
 for(let day=1;day<=15;day++){
  const date=new Date(nextMonth.getFullYear(),nextMonth.getMonth(),day);
  const rn=30+day;
  filled['B'+rn]=day;
  const row=byDay.get(toISO(date));
  if(row)fillRow(rn,row);
 }
 function fillRow(rn,row){
  const standardEnd=plusNine(row.shift_start);
  filled['C'+rn]=originalTime(row.shift_start);
  filled['D'+rn]=originalTime(standardEnd);
  filled['E'+rn]=originalTime(standardEnd);
  filled['F'+rn]=originalTime(row.shift_end);
  const hours=Math.round(Number(row.ot_minutes||0)/60*100)/100;
  const claim=String(row.claim_type||'').toUpperCase();
  if(claim==='OFF'){filled['H'+rn]=hours;filled['R'+rn]=1}
  else if(claim==='PH'){filled['I'+rn]=hours;filled['S'+rn]=1}
  else filled['G'+rn]=hours;
  // Split shift / night shift / Certified By remain blank if not recorded.
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
window.SKYBAR_OT_FORM_GENERATOR=Object.freeze({download,validateTemplate});
})();