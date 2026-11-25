'use strict';
const el = id => document.getElementById(id);
const bridge = window.qz;
const saved = name => {
  try { return JSON.parse(localStorage.getItem('qz.' + name)); } catch { return null; }
};
const persist = (name, value) => {
  try { localStorage.setItem('qz.' + name, JSON.stringify(value)); } catch { /* ephemeral preview */ }
};
const prefs = { language:systemLanguage(navigator.language), layout:'smart', performance:'balanced', conflict:'rename', encoding:'automatic', ignoreMac:false, ...saved('preferences') };
if (!Object.hasOwn(languages,prefs.language)) prefs.language = 'en';
let history = saved('history');
if (!Array.isArray(history)) history = [];
const queue = [];
let view = 'desk', selected, activeJob, currentPreview, previewLoading = false, statusKey = 'ready', statusText = '';
let engineInfo = { native:false, description:'', platform:'preview' };
let destination = '';

const tr = key => dictionaries[prefs.language][key] || dictionaries.en[key] || key;
const flags = {
  layout: { smart:'smart',folder:'folder',here:'here' },
  performance: { balanced:'balanced',background:'background',fast:'fast' },
  conflict: { rename:'rename',skip:'skip' },
  encoding: { automatic:'automatic',utf8:'UTF-8',gb18030:'GB18030',big5:'Big5',japanese:'Shift-JIS',korean:'CP949' }
};

function tag(name, text, className) {
  const node = document.createElement(name);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}
function button(text, call, className='button outline') {
  const node=tag('button',text,className);
  node.type='button';
  node.addEventListener('click',call);
  return node;
}
function units(n) {
  if (!Number.isFinite(n) || n < 0) return '—';
  const scale = n ? Math.min(4,Math.floor(Math.log(n)/Math.log(1024))) : 0;
  return Intl.NumberFormat(prefs.language,{maximumFractionDigits:scale===0?0:1}).format(n / (1024**scale)) + ' ' + ['B','KiB','MiB','GiB','TiB'][scale];
}
function listOptions(node, items, current, literal=false) {
  node.replaceChildren(...Object.entries(items).map(([value,label]) => new Option(literal ? label : tr(label),value)));
  if(!Object.hasOwn(items,current)) current=Object.keys(items)[0];
  node.value=current;
}
function setStatus(key, text='') {
  statusKey=key;statusText=text;
  el('status').textContent=[key && tr(key),text].filter(Boolean).join(' · ');
}
function renderRail() {
  el('queueCount').textContent = queue.length;
  if (!queue.length) { el('queue').replaceChildren(tag('p',tr('queueEmpty'),'rail-empty'));return; }
  el('queue').replaceChildren(...queue.map(job => {
    const choose = button(undefined,()=>{ selected=job;show('desk'); },'task'+(job===selected?' current':''));
    choose.dataset.job=job.id;choose.title=job.name;
    if (job===selected) choose.setAttribute('aria-current','true');
    const label = tag('span');
    const rest = job.state==='running' && job.progress!==undefined ? ' · '+job.progress+'%' : ' · '+units(job.size);
    label.append(tag('strong',job.name),tag('small',tr(job.state)+rest));
    choose.append(tag('span','','dot '+job.state),label);
    return choose;
  }));
}
function renderRecords(target,list) {
  if (!list.length) { target.replaceChildren(tag('p',tr('noHistory'),'blank'));return; }
  target.replaceChildren(...list.map(record=>{
    const row=tag('div',undefined,'row');
    const result=tr(record.mode==='test' && record.state==='done'?'tested':record.state);
    const mark=tag('span',result+' · '+new Date(record.at).toLocaleString(prefs.language,{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}));
    const heading=tag('strong',record.name);heading.title=record.detail||record.name;
    row.append(heading,mark);
    if(record.output && bridge)row.append(button(tr('openOutput'),()=>call('reveal',{path:record.output}).catch(showError)));
    return row;
  }));
}
window.redrawArchive=()=>inkSketch({format:selected?.format?.split(' · ')[0].slice(0,22),done:selected?.state==='done'});
function renderDesk() {
  const completed=history.filter(item=>item.state==='done');
  const stats={archive:queue.length,doneCount:completed.length,bytes:units(completed.reduce((sum,item)=>sum+(item.mode==='extract'?item.bytes||0:0),0))};
  el('stats').replaceChildren(...Object.entries(stats).map(([key,value])=>{
    const box=tag('div',undefined,'stat');box.append(tag('span',tr(key),'eyebrow'),tag('strong',value));return box;
  }));
  el('format').textContent=selected?.format || 'ZIP / RAR / 7Z';
  el('diagramTitle').textContent=selected?.name || tr('diagramEmpty');
  el('captionTitle').textContent=selected?(selected.detail||tr(selected.state)):tr('dropTitle');
  el('captionBody').replaceChildren();
  if (selected) {
    el('captionBody').append([units(selected.size),selected.format,selected.count!==undefined?selected.count+' '+tr('archive').toLowerCase():null].filter(Boolean).join(' · '));
    if (selected===activeJob) el('captionBody').append(' ',button(tr('cancel'),()=>call('cancel',{job:selected.id}).catch(showError),'text-button'));
    else el('captionBody').append(' ',button(tr('remove'),()=>remove(selected),'text-button'));
  } else {
    el('captionBody').append(tr('dropBody'),' ',button(tr('openSample'),openSample,'text-button'));
  }
  el('inspect').hidden=!selected;
  el('inspect').disabled=Boolean(activeJob)||previewLoading||(!bridge&&!selected?.example);
  el('extract').disabled=!selected||!bridge||Boolean(activeJob)||previewLoading;
  el('test').disabled=el('extract').disabled;
  el('destination').textContent=destination||tr('sourceFolder');
  el('destination').title=destination;
  el('clearDestination').hidden=!destination;
  window.redrawArchive();
}
function render() {
  document.documentElement.lang=prefs.language;
  for(const node of document.querySelectorAll('[data-text]'))node.textContent=tr(node.dataset.text);
  for(const node of document.querySelectorAll('[data-close]'))node.setAttribute('aria-label',tr('close'));
  el('clearDestination').setAttribute('aria-label',tr('reset'));
  el('search').placeholder=tr('search');
  el('search').setAttribute('aria-label',tr('search'));
  el('pageTitle').textContent=tr(view);
  for(const id of ['desk','history','settings'])el(id).hidden=id!==view;
  for(const node of el('nav').children) {
    if(node.dataset.view===view)node.setAttribute('aria-current','page');
    else node.removeAttribute('aria-current');
  }
  listOptions(el('language'),languages,prefs.language,true);
  for(const [name,items] of Object.entries(flags))listOptions(el(name),items,prefs[name]);
  el('ignoreMac').checked=prefs.ignoreMac;
  el('host').textContent=bridge?engineInfo.platform:tr('preview');
  el('engine').textContent=engineInfo.description||'—';
  el('platformNote').textContent=tr(!bridge?'previewNote':engineInfo.native?'nativeNote':'portableNote');
  renderRail();renderDesk();renderRecords(el('recent'),history.slice(0,4));renderRecords(el('records'),history);
  el('clearHistory').disabled=history.length===0;
  setStatus(statusKey,statusText);
  if(el('contents').open)renderMembers();
}
function show(name){ view=name;render(); }
function showError(failure) { setStatus(failure.code||'operationFailed',failure.detail||''); }
async function call(name, payload={}) {
  if(!bridge)throw {code:'previewNote'};
  const result=await bridge.call(name,payload);
  if(result?.error)throw {code:result.error,detail:result.detail};
  return result;
}
function add(items) {
  for(const item of items||[]) {
    if(!item?.id)continue;
    let existing=queue.find(job=>job.id===item.id);
    if(!existing){ existing={...item,state:'queued'};queue.push(existing); }
    selected=existing;
  }
  if(items?.length)show('desk');
}
function remove(job){
  const index=queue.indexOf(job);
  queue.splice(index,1);
  selected=queue[Math.min(index,queue.length-1)];
  render();
}
async function openSample() {
  if (bridge) { try { add(await call('sample')); } catch(error){ showError(error); } return; }
  add([{id:'demo',name:'sample.zip',format:'ZIP',size:628,example:true}]);
}
function describe(job,extra={}) {
  return { id:job.id, layout:prefs.layout, performance:prefs.performance, conflict:prefs.conflict, encoding:prefs.encoding, ignoreMac:prefs.ignoreMac, destination, ...extra };
}
function askPassword(job, wrong) {
  return new Promise(resolve => {
    const dialog=el('passwordDialog');
    el('passwordName').textContent=job.name+(wrong?' · '+tr('wrongPassword'):'');
    const input=el('passwordInput');input.value='';
    const form=el('passwordForm');
    let answer=null;
    form.onsubmit=event=>{ event.preventDefault();answer=input.value;dialog.close(); };
    dialog.addEventListener('close',()=>{ input.value='';form.onsubmit=null;resolve(answer); },{once:true});
    dialog.showModal();
  });
}
async function withPassword(job, action) {
  let password;
  for (;;) {
    try { return await action(password); }
    catch(error) {
      if(!['password','wrongPassword'].includes(error.code))throw error;
      password=await askPassword(job,error.code==='wrongPassword');
      if(password===null)throw {code:'cancelled'};
    }
  }
}
function renderMembers(){
  if(!currentPreview)return;
  const search=el('search').value.toLocaleLowerCase(prefs.language);
  const rows=[];
  const matches=currentPreview.items.filter(item=>item.path.toLocaleLowerCase(prefs.language).includes(search));
  for(const item of matches.slice(0,currentPreview.shown)){
    const check=document.createElement('input');check.type='checkbox';check.checked=currentPreview.selection.has(item.path);
    check.addEventListener('change',()=>{
      if(check.checked)currentPreview.selection.add(item.path);else currentPreview.selection.delete(item.path);
      el('extractSelected').disabled=!bridge||currentPreview.selection.size===0;
    });
    const row=tag('label',undefined,'member');
    const name=tag('b',(item.directory?'📁 ':'')+item.path);name.title=item.path;
    row.append(check,name,tag('small',item.directory?'—':units(item.size)));rows.push(row);
  }
  if(matches.length>currentPreview.shown)rows.push(button(tr('more'),()=>{currentPreview.shown+=500;renderMembers();}));
  el('members').replaceChildren(...(rows.length?rows:[tag('p',tr('empty'),'blank')]));
  el('extractSelected').disabled=!bridge||currentPreview.selection.size===0;
  el('more').hidden=!currentPreview.truncated;
  el('more').disabled=previewLoading;
}
async function inspect(job,limit=10000) {
  if(!job||previewLoading||activeJob)return;
  previewLoading=true;renderDesk();renderMembers();setStatus('loading',job.name);
  try {
    const result=job.example? {format:'ZIP',items:[{path:'notes.txt',size:97},{path:'data.csv',size:24},{path:'docs/readme.txt',size:28}],truncated:false}
        : await withPassword(job,password=>call('list',describe(job,{limit,password})));
    job.format=result.format;
    currentPreview={...result,job,limit,shown:500,selection:currentPreview?.job===job?currentPreview.selection:new Set()};
    el('contentsName').textContent=job.name;
    if(!el('contents').open){el('search').value='';el('contents').showModal();}
    setStatus('ready');
  } catch(error) { showError(error); }
  finally { previewLoading=false;render(); }
}
async function run(job, mode, selection=[]) {
  if(!job||activeJob||previewLoading||!bridge)return;
  activeJob=job;job.state='running';job.detail='';job.progress=undefined;render();setStatus('running',job.name);
  let result;
  try {
    result=await withPassword(job,password=>call(mode,describe(job,{password,selection})));
    job.format=result.format||job.format;job.state='done';setStatus(mode==='test'?'tested':'done',job.name);
  } catch(error) {
    job.state=error.code==='cancelled'?'cancelled':'failed';job.detail=tr(error.code||'operationFailed');
    showError(error);
  } finally {
    history.unshift({name:job.name,mode,state:job.state,at:Date.now(),bytes:result?.bytes||0,output:result?.output||null,detail:job.detail});
    history=history.slice(0,100);persist('history',history);
    activeJob=undefined;render();
  }
}
for(const node of el('nav').children)node.addEventListener('click',()=>show(node.dataset.view));
el('seeHistory').onclick=()=>show('history');
el('clearHistory').onclick=()=>{ if(confirm(tr('confirmClear'))){ history=[];persist('history',history);render(); } };
el('language').onchange=e=>{prefs.language=e.target.value;persist('preferences',prefs);render();};
for(const name of Object.keys(flags))el(name).onchange=e=>{prefs[name]=e.target.value;persist('preferences',prefs);};
el('ignoreMac').onchange=e=>{prefs.ignoreMac=e.target.checked;persist('preferences',prefs);};
el('add').onclick=async()=>{try{add(await call('pick'));}catch(error){showError(error);}};
el('destination').onclick=async()=>{try{const result=await call('folder');if(result){destination=result;renderDesk();}}catch(error){showError(error);}};
el('clearDestination').onclick=()=>{destination='';renderDesk();};
el('inspect').onclick=()=>inspect(selected);
el('extract').onclick=()=>run(selected,'extract');
el('test').onclick=()=>run(selected,'test');
el('search').oninput=()=>{ if(currentPreview)currentPreview.shown=500;renderMembers(); };
el('more').onclick=()=>inspect(currentPreview.job,currentPreview.limit+10000);
el('extractSelected').onclick=()=>{ el('contents').close();run(currentPreview.job,'extract',[...currentPreview.selection]); };
for(const node of document.querySelectorAll('[data-close]'))node.onclick=()=>el(node.dataset.close).close();
if(bridge){
  bridge.onOpen(add);
  bridge.onProgress(({id,percent})=>{
    if(activeJob?.id!==id)return;
    activeJob.progress=percent;
    setStatus('running',activeJob.name+' · '+percent+'%');
    const card=el('queue').querySelector('.task.current small');
    if(card&&selected===activeJob)card.textContent=tr('running')+' · '+percent+'%';
  });
  call('info').then(info=>{engineInfo=info;render();}).catch(showError);
  call('pending').then(add).catch(showError);
}
const drop=el('dropTarget');
for(const event of ['dragenter','dragover'])drop.addEventListener(event,e=>{if(e.dataTransfer?.types.includes('Files')){e.preventDefault();drop.classList.add('dragging');}});
drop.ondragleave=event=>{if(!drop.contains(event.relatedTarget))drop.classList.remove('dragging');};
window.addEventListener('dragover',event=>{if(event.dataTransfer?.types.includes('Files'))event.preventDefault();});
window.addEventListener('drop',async event=>{
  event.preventDefault();drop.classList.remove('dragging');
  if(!bridge?.drop||!event.dataTransfer?.files.length)return;
  try{add(await bridge.drop([...event.dataTransfer.files]));}catch(error){showError(error);}
});
window.addEventListener('keydown',event=>{
  if((event.metaKey||event.ctrlKey)&&event.key.toLowerCase()==='o'){event.preventDefault();el('add').click();}
});
render();
