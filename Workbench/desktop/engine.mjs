import {spawn} from 'node:child_process';
import {createWriteStream} from 'node:fs';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import {tmpdir, setPriority, constants} from 'node:os';
import {pipeline} from 'node:stream/promises';

export class ArchiveError extends Error {
  constructor(code, detail = '') { super(detail || code); this.code = code; this.detail = detail; }
}

const signatures = [
  ['526172211a070100','RAR 5'],['526172211a0700','RAR'],['377abcaf271c','7Z'],
  ['504b0304','ZIP'],['504b0506','ZIP'],['504b0708','ZIP'],
  ['1f8b','GZIP'],['fd377a585a00','XZ'],['425a68','BZIP2'],['28b52ffd','ZSTD'],
  ['4d534346','CAB'],['45474741','EGG'],['414c5a01','ALZ'],['49735a21','ISZ'],
  ['42480507','BlakHole'],['7a5051','ZPAQ'],['4d5357494d','WIM']
];
const onlyMac = new Set(['ALZ','EGG','ISZ','BlakHole','ACE','PMA','ZPAQ','LZFSE','AES Crypt']);
const encodings = {utf8:65001,gb18030:936,big5:950,japanese:932,korean:949};
const isContainer = /^(gzip|xz|bzip2|zstd)$/i;
const limitBytes = 32 * 1024 * 1024;

export async function signature(source) {
  const file = await fs.open(source,'r');
  try {
    const prefix=Buffer.alloc(14);
    const {bytesRead}=await file.read(prefix);
    if(bytesRead>=14&&prefix.toString('ascii',7,14)==='**ACE**')return 'ACE';
    if(/^-pm[012]-$/.test(prefix.toString('ascii',2,7)))return 'PMA';
    if(/^bvx[12n-]/.test(prefix.toString('ascii',0,4)))return 'LZFSE';
    if(bytesRead>=7&&prefix.toString('ascii',0,3)==='AES'&&prefix[3]<=3)return 'AES Crypt';
    const hex=prefix.subarray(0,bytesRead).toString('hex');
    return signatures.find(([code])=>hex.startsWith(code))?.[1] || '';
  } finally { await file.close(); }
}

export async function resolveSource(input) {
  const parsed=path.parse(input);
  const match=/^(.*?(?:\.part|\.(?:zip|7z)\.))(\d+)(\.rar)?$/i.exec(parsed.base);
  let candidate;
  if(match)candidate=path.join(parsed.dir,match[1]+'1'.padStart(match[2].length,'0')+(match[3]||''));
  else if(/^\.r\d{2}$/i.test(parsed.ext))candidate=path.join(parsed.dir,parsed.name+'.rar');
  if(candidate)try{if((await fs.stat(candidate)).isFile())return fs.realpath(candidate);}catch(error){if(error.code!=='ENOENT')throw error;}
  return fs.realpath(input);
}

function memberPath(raw) {
  const name=raw.replace(/\\/g,'/').replace(/^\.\//,'').replace(/\/$/,'');
  const invalid=name.startsWith('/')||name.length>8192||name.split('/').some(part=>!part||part==='.'||part==='..'||
    /[<>:"|?*\x00-\x1f\x7f]/.test(part)||/[ .]$/.test(part)||
    /^(?:con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])(?:\.|$)/i.test(part));
  if(invalid)throw new ArchiveError('unsafe',raw);
  return name;
}

function present(value) { return !['','-','0','false','no'].includes((value||'').trim().toLowerCase()); }

export function parseListing(text) {
  const lines=text.replace(/\r\n/g,'\n');
  const marker=lines.indexOf('\n----------\n');
  if(marker<0)throw new ArchiveError('operationFailed','7-Zip: archive directory was unavailable.');
  const format=/^Type = (.+)$/m.exec(lines.slice(0,marker))?.[1]||'Archive';
  const members=[];
  const seen=new Set();
  for(const record of lines.slice(marker+12).split(/\n\n+/)) {
    if(!record.trim())continue;
    const fields=Object.create(null);
    for(const line of record.trimStart().split('\n').filter(Boolean)){
      if(/^Warnings: \d+$/.test(line))continue;
      const end=line.indexOf(' = ');
      const key=line.slice(0,end);
      if(end<1||!/^[- A-Za-z0-9]+$/.test(key)||Object.hasOwn(fields,key))throw new ArchiveError('unsafe','7-Zip: ambiguous listing.');
      fields[key]=line.slice(end+3);
    }
    if(!Object.hasOwn(fields,'Path'))throw new ArchiveError('unsafe','7-Zip: missing member name.');
    const mode=fields.Mode||'';
    const attributes=fields.Attributes||'';
    const unix=attributes.split(/\s+/).at(-1);
    if(['Symbolic Link','Hard Link','Link','Reparse','Alternate Stream','Is Alt Stream'].some(key=>present(fields[key]))||
       /^[lbcps]/.test(mode)||/^[lbcps][rwxstST-]{9}/.test(unix))throw new ArchiveError('unsafe',fields.Path);
    const directory=fields.Folder==='+'||attributes.startsWith('D')||unix?.startsWith('d')||mode.startsWith('d');
    if(directory&&/^(?:\.)?[\\/]?$/.test(fields.Path))continue;
    const relative=memberPath(fields.Path);
    const key=relative.normalize('NFC').toLowerCase();
    if(seen.has(key))throw new ArchiveError('unsafe',relative);
    seen.add(key);
    const size=Number(fields.Size||0);
    if(!Number.isSafeInteger(size)||size<0)throw new ArchiveError('unsafe',relative);
    members.push({path:relative,raw:fields.Path,size,directory,encrypted:fields.Encrypted==='+'});
  }
  const nonDirectories=new Set(members.filter(x=>!x.directory).map(x=>x.path.normalize('NFC').toLowerCase()));
  for(const entry of members){
    let ancestor=path.posix.dirname(entry.path);
    while(ancestor!=='.'){
      if(nonDirectories.has(ancestor.normalize('NFC').toLowerCase()))throw new ArchiveError('unsafe',entry.path);
      ancestor=path.posix.dirname(ancestor);
    }
  }
  return {format,members};
}

function diagnostic(text, password) {
  if(/wrong password|password is incorrect|data error in encrypted|enter password/i.test(text))
    return new ArchiveError(password===undefined?'password':'wrongPassword');
  const detail=text.split(/[\r\n]+/).filter(line=>/error|cannot|unsupported/i.test(line)).slice(-3).join('\n').slice(0,750);
  return new ArchiveError('operationFailed',detail);
}

async function invoke(exe,args,{signal,password,percent,output}={}){
  signal?.throwIfAborted();
  let proc;
  // No shell and no command-line password. Decoder stdin receives the user-entered line.
  if(password!==undefined && /[\n\r\0]/.test(password))throw new ArchiveError('wrongPassword');
  const env={...process.env,LANG:'en_US.UTF-8',LC_ALL:'C.UTF-8'};
  proc=spawn(exe,args,{env,windowsHide:true,stdio:['pipe','pipe','pipe'],signal});
  try { setPriority(proc.pid,constants.priority.PRIORITY_BELOW_NORMAL); } catch { /* compatible with user limits */ }
  proc.stdin.on('error',()=>{});
  proc.stdin.end((password??'')+'\n','utf8');
  let bytes=0,last=-1,overflow=false;
  const chunks=[];
  function data(chunk){
    if(percent){
      const match=[...chunk.toString().matchAll(/(?:^|\s)(\d{1,3})%/g)].at(-1);
      if(match){const next=Math.min(99,Number(match[1]));if(next>last)percent(last=next);}
    }
    bytes+=chunk.length;
    if(bytes<=limitBytes)chunks.push(chunk);
    else{overflow=true;proc.kill();}
  }
  proc.stderr.on('data',data);
  if(!output)proc.stdout.on('data',data);
  const completion=new Promise((accept,reject)=>{
    let failure;
    proc.once('error',error=>{failure=error;});
    proc.once('close',code=>failure?reject(failure):accept(code));
  });
  try {
    const transfer=output?pipeline(proc.stdout,createWriteStream(output,{flags:'wx'}),{signal}).catch(error=>{proc.kill();throw error;}):Promise.resolve();
    const [code,written]=await Promise.allSettled([completion,transfer]);
    if(signal?.aborted)throw new ArchiveError('cancelled');
    if(code.status==='rejected')throw code.reason;
    if(written.status==='rejected')throw written.reason;
    if(overflow)throw new ArchiveError('unsafe','7-Zip: listing exceeded 32 MiB.');
    const text=Buffer.concat(chunks).toString('utf8');
    if(code.value!==0)throw diagnostic(text,password);
    return text;
  }catch(error){
    if(signal?.aborted)throw new ArchiveError('cancelled');
    if(error.code==='ENOENT')throw new ArchiveError('engineMissing');
    throw error;
  }
}

function options(cmd){return ['-sccUTF-8',...(Object.hasOwn(encodings,cmd.encoding)?['-mcp='+encodings[cmd.encoding]]:[])];}
function writerArgs(cmd){ const threads=cmd.performance==='fast'?4:cmd.performance==='background'?1:2;return [...options(cmd),'-mmt='+threads,'-bsp2','-bso0','-y'];}
function isMetadata(item){return item.path.split('/').some(name=>name==='__MACOSX'||name==='.DS_Store'||name.startsWith('._'));}
function fullPath(base,item){return path.join(base,...item.split('/'));}
function archiveName(source){
  const base=path.basename(source).replace(/(?:\.part\d+\.rar|\.(?:zip|7z)\.\d{3}|\.tar\.(?:gz|xz|bz2|zst)|\.[^.]+)$/i,'');
  try{return memberPath(base||'archive');}catch{return 'archive';}
}

async function validate(stage,members,signal){
  const wanted=new Map(members.map(x=>[x.path,x]));
  const parents=new Set();
  for(const item of wanted.keys()){
    let parent=path.posix.dirname(item);
    while(parent!=='.'){parents.add(parent);parent=path.posix.dirname(parent);}
  }
  async function walk(relative=''){
    for(const name of await fs.readdir(relative?fullPath(stage,relative):stage)){
      signal?.throwIfAborted();
      const key=relative?relative+'/'+name:name;
      const entry=wanted.get(key);
      const stat=await fs.lstat(fullPath(stage,key));
      if(stat.isDirectory()&&(entry?.directory||parents.has(key))){wanted.delete(key);await walk(key);}
      else if(stat.isFile()&&stat.nlink===1&&entry&&!entry.directory&&stat.size===entry.size)wanted.delete(key);
      else throw new ArchiveError('unsafe',key);
    }
  }
  await walk();
  if(wanted.size)throw new ArchiveError('operationFailed','7-Zip: output did not match the member list.');
}

async function publish(stage,dest,source,cmd){
  const tops=await fs.readdir(stage);
  const stem=archiveName(source);
  const grouped=cmd.layout==='folder'||(cmd.layout!=='here'&&tops.length!==1);
  const entries=grouped?[[stage,stem,true]]:await Promise.all(tops.map(async name=>{
    const item=path.join(stage,name);return [item,name,(await fs.lstat(item)).isDirectory()];
  }));
  const created=[];
  try{
    for(const [item,name,directory] of entries){
      for(let count=0;count<10000;count++){
        const ext=directory?'':path.extname(name);
        const candidate=path.join(dest,count?name.slice(0,name.length-ext.length)+' ('+(count+1)+')'+ext:name);
        try {
          if(directory)await fs.mkdir(candidate,{mode:0o755});
          else await fs.link(item,candidate);
        }catch(error){
          if(error.code!=='EEXIST')throw error;
          if(cmd.conflict==='skip')break;
          if(count===9999)throw new ArchiveError('operationFailed','Too many existing output names.');
          continue;
        }
        created.push(candidate);
        if(directory)for(const child of await fs.readdir(item))await fs.rename(path.join(item,child),path.join(candidate,child));
        break;
      }
    }
  }catch(error){
    for(const candidate of created.reverse())await fs.rm(candidate,{recursive:true,force:true});
    throw error;
  }
  return created;
}

export async function perform(exe,source,mode,cmd={},job={}) {
  if(!['list','extract','test'].includes(mode))throw new ArchiveError('operationFailed');
  const start=Date.now();
  const detected=await signature(source);
  if(onlyMac.has(detected))throw new ArchiveError('unsupported',detected);
  const {signal}=job;
  const config={...job,password:cmd.password};
  const read=async file=>parseListing(await invoke(exe,['l','-slt',...options(cmd),'--',file],{...config,percent:undefined}));
  let archive=source, scratch;
  try {
    let listing=await read(archive);
    let label=detected||listing.format;
    if(isContainer.test(listing.format)&&listing.members.length===1&&
       (/\.tar$/i.test(listing.members[0].path)||/\.(?:tgz|tbz2?|txz|tzst)$/i.test(source))){
      scratch=await fs.mkdtemp(path.join(tmpdir(),'quickunzip-tar-'));
      archive=path.join(scratch,'payload.tar');
      await invoke(exe,['x','-so','-bso0','-bsp0',...options(cmd),'--',source],{...config,percent:undefined,output:archive});
      listing=await read(archive);
      if(listing.format.toLowerCase()!=='tar')throw new ArchiveError('operationFailed','The inner stream is not a TAR archive.');
      label='TAR · '+label;
    }
    const members=listing.members;
    const limit=Math.min(200000,Math.max(1,Number(cmd.limit)||10000));
    if(mode==='list')return {format:label,items:members.slice(0,limit),truncated:members.length>limit&&limit<200000};
    const selected=Array.isArray(cmd.selection)?cmd.selection:[];
    const filtered=mode==='extract'?members.filter(m=>(!cmd.ignoreMac||!isMetadata(m))&&
      (!selected.length||selected.some(p=>m.path===p||m.path.startsWith(p+'/')))):members;
    if(selected.length&&!filtered.length)throw new ArchiveError('notFound');
    if(cmd.password===undefined&&filtered.some(m=>m.encrypted))throw new ArchiveError('password');
    const bytes=filtered.reduce((total,m)=>total+(m.directory?0:m.size),0);
    if(!Number.isSafeInteger(bytes))throw new ArchiveError('unsafe');
    if(mode==='test'){
      await invoke(exe,['t',...writerArgs(cmd),'--',archive],config);
      return {format:label,bytes,seconds:(Date.now()-start)/1000};
    }
    const destination=await fs.realpath(cmd.destination||path.dirname(source));
    const space=await fs.statfs(destination);
    if(bytes>space.bavail*space.bsize)throw new ArchiveError('operationFailed','Insufficient disk space.');
    const work=await fs.mkdtemp(path.join(destination,'.quickunzip-'));
    try {
      const stage=path.join(work,'payload');
      await fs.mkdir(stage,{mode:0o700});
      if(filtered.length!==members.length){
        // Selecting a directory in 7-Zip includes its entire subtree. Use literal file paths,
        // and recreate the validated empty directories separately.
        const files=filtered.filter(m=>!m.directory);
        if(files.length){
          const list=path.join(work,'selection.txt');
          await fs.writeFile(list,files.map(m=>m.raw).join('\n')+'\n',{mode:0o600});
          await invoke(exe,['x',...writerArgs(cmd),'-o'+stage,'-spd','-scsUTF-8','-i@'+list,'--',archive],config);
        }
        for(const item of filtered.filter(m=>m.directory))await fs.mkdir(fullPath(stage,item.path),{recursive:true});
      }else if(members.length)await invoke(exe,['x',...writerArgs(cmd),'-o'+stage,'--',archive],config);
      await validate(stage,filtered,signal);
      signal?.throwIfAborted();
      const outputs=await publish(stage,destination,source,cmd);
      return {format:label,bytes,output:outputs.length===1?outputs[0]:destination,seconds:(Date.now()-start)/1000};
    } finally { await fs.rm(work,{recursive:true,force:true}); }
  } catch (error) {
    if(signal?.aborted||error.name==='AbortError')throw new ArchiveError('cancelled');
    if(error.code==='ENOENT'||error.code==='ENOTDIR')throw new ArchiveError('notFound');
    throw error;
  } finally { if(scratch)await fs.rm(scratch,{recursive:true,force:true}); }
}
