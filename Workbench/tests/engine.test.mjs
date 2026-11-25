import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import * as fs from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import {fileURLToPath} from 'node:url';
import {parseListing, perform, resolveSource, signature} from '../desktop/engine.mjs';

const base=fileURLToPath(new URL('../../',import.meta.url));
const platformName=process.platform==='win32'?'7z.exe':'7zz';
const exe=process.env.QUICKUNZIP_7ZIP||[path.resolve(base,'Workbench/engine',platformName),
  path.resolve(base,'Vendor/7zip',platformName)].find(existsSync)||platformName;
const work=async()=>fs.realpath(await fs.mkdtemp(path.join(tmpdir(),'quickunzip-test-')));
const make=(where,...args)=>execFileSync(exe,args,{cwd:where,stdio:'pipe'});

test('ZIP, wrong extension, selected output, conflicts and test',async t=>{
  const root=await work();t.after(()=>fs.rm(root,{force:true,recursive:true}));
  await fs.mkdir(path.join(root,'notes'));
  await fs.writeFile(path.join(root,'notes','说明.txt'),'quick unzip\n');
  await fs.writeFile(path.join(root,'notes','demo.txt'),'other member');
  make(root,'a','-tzip','data.zip','notes');
  const source=path.join(root,'odd.data');
  await fs.rename(path.join(root,'data.zip'),source);
  assert.equal(await signature(source),'ZIP');
  const index=await perform(exe,source,'list',{limit:2});
  assert.equal(index.items.length,2);
  assert.equal(index.truncated,true);
  const result=await perform(exe,source,'extract',{layout:'here',selection:['notes/说明.txt']});
  assert.equal(await fs.readFile(path.join(result.output,'说明.txt'),'utf8'),'quick unzip\n');
  assert.equal(result.output,path.join(root,'notes (2)'));
  const skipped=await perform(exe,source,'extract',{layout:'smart',conflict:'skip'});
  assert.equal(skipped.output,root);
  assert.equal((await perform(exe,source,'test')).format,'ZIP');
});

test('encrypted 7Z, wrong password and cancelled decoder',async t=>{
  const root=await work();t.after(()=>fs.rm(root,{force:true,recursive:true}));
  await fs.writeFile(path.join(root,'private.txt'),'test only');
  make(root,'a','-t7z','-ptest-fixture','-mhe=on','protected.7z','private.txt');
  const source=path.join(root,'protected.7z');
  await assert.rejects(perform(exe,source,'list'),{code:'password'});
  await assert.rejects(perform(exe,source,'test',{password:'wrong'}),{code:'wrongPassword'});
  assert.equal((await perform(exe,source,'test',{password:'test-fixture'})).bytes,9);
  const cancelled=new AbortController();cancelled.abort();
  await assert.rejects(perform(exe,source,'list',{}, {signal:cancelled.signal}),{code:'cancelled'});
});

test('tar.gz lists and extracts inner members',async t=>{
  const root=await work();t.after(()=>fs.rm(root,{force:true,recursive:true}));
  await fs.writeFile(path.join(root,'a.txt'),'hello');
  make(root,'a','-ttar','outer.tar','a.txt');
  make(root,'a','-tgzip','outer.tar.gz','outer.tar');
  const source=path.join(root,'outer.tar.gz');
  const result=await perform(exe,source,'list');
  assert.equal(result.format,'TAR · GZIP');
  assert.equal(result.items[0].path,'a.txt');
  const extracted=await perform(exe,source,'extract',{layout:'folder'});
  assert.equal(await fs.readFile(path.join(extracted.output,'a.txt'),'utf8'),'hello');
});

test('split archive resolves to first volume and tests contents',async t=>{
  const root=await work();t.after(()=>fs.rm(root,{force:true,recursive:true}));
  const body=Buffer.from(Array.from({length:9000},(_,i)=>i%256));
  await fs.writeFile(path.join(root,'file.bin'),body);
  make(root,'a','-t7z','-mx=0','-v4k','split.7z','file.bin');
  const first=await resolveSource(path.join(root,'split.7z.002'));
  assert.equal(path.basename(first),'split.7z.001');
  assert.equal((await perform(exe,first,'test')).bytes,body.length);
});

test('directory metadata policy and visible test status',()=>{
  const listing=p=>'Type = zip\n----------\nPath = '+p+'\nSize = 2\nEncrypted = -\n';
  assert.throws(()=>parseListing(listing('bad:stream')),{code:'unsafe'});
  assert.throws(()=>parseListing(listing('work/con.txt')),{code:'unsafe'});
  assert.throws(()=>parseListing(listing('file')+'Symbolic Link = target\n'),{code:'unsafe'});
  assert.equal(parseListing(listing('normal')+'Links = 1\nAlternate Stream = -\n').members.length,1);
});

test('six locale dictionaries are complete',async ()=>{
  const code=await fs.readFile(path.resolve(base,'Workbench/ui/locale.js'),'utf8');
  const data=vm.runInNewContext(code+'\n({languages,dictionaries,defaultLocale:systemLanguage("zh-Hant-HK")})');
  const keys=Object.keys(data.dictionaries.en);
  assert.equal(Object.keys(data.languages).length,6);
  assert.equal(data.defaultLocale,'zh-TW');
  for(const value of Object.values(data.dictionaries)){
    assert.deepEqual(Object.keys(value),keys);
    assert.ok(Object.values(value).every(Boolean));
  }
});
