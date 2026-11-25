import { app, BrowserWindow, dialog, ipcMain, Menu, shell } from 'electron';
import * as fs from 'node:fs/promises';
import {existsSync} from 'node:fs';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {ArchiveError, perform, resolveSource, signature} from './engine.mjs';

const desktop = path.dirname(fileURLToPath(import.meta.url));
const ui = path.join(desktop,'..','ui');
const sources = new Map();
let mainWindow, chosenFolder, current, ready = false, sample, quitting = false;
let pending = [];
const executable = process.platform === 'win32' ? '7z.exe' : '7zz';
const bundled = path.join(process.resourcesPath,'engine',executable);
const base = path.join(desktop,'..','..','Vendor','7zip','7zz');
const decoder = process.env.QUICKUNZIP_7ZIP || [bundled,path.join(desktop,'..','engine',executable),process.platform==='darwin'&&base]
  .find(file=>file&&existsSync(file)) || executable;
const platform = {win32:'Windows', linux:'Ubuntu', darwin:'macOS'}[process.platform] || process.platform;

async function register(paths){
  const records=[];
  for(const input of paths){
    if(typeof input!=='string'||!path.isAbsolute(input))continue;
    try{
      const source=await resolveSource(input);
      const info=await fs.stat(source);
      if(!info.isFile())continue;
      let item=[...sources.entries()].find(([,name])=>name===source)?.[0];
      if(!item){item=randomUUID();sources.set(item,source);}
      records.push({id:item,name:path.basename(source),size:info.size,format:await signature(source)});
    }catch { /* unavailable paths are omitted from the queue */ }
  }
  return records;
}
async function enqueue(paths){
  const files=await register(paths);
  if(ready&&mainWindow&&!mainWindow.isDestroyed())mainWindow.webContents.send('qz:open',files);
  else pending.push(...files);
}
function argvFiles(argv) { return argv.slice(app.isPackaged?1:2).filter(item=>path.isAbsolute(item)); }

function errorReply(error) {
  if(error instanceof ArchiveError)return {error:error.code,detail:error.detail};
  return {error:error.code==='ENOENT'?'notFound':'operationFailed',detail:String(error.message||'').slice(0,500)};
}

async function handle(action,data){
  if(action==='info')return {native:false,platform,description:'7-Zip 26.06'};
  if(action==='pending'){ready=true;return pending.splice(0);}
  if(action==='pick'){
    const result=await dialog.showOpenDialog(mainWindow,{properties:['openFile','multiSelections']});
    return result.canceled?[]:register(result.filePaths);
  }
  if(action==='drop')return register(Array.isArray(data.paths)?data.paths:[]);
  if(action==='folder'){
    const result=await dialog.showOpenDialog(mainWindow,{properties:['openDirectory','createDirectory']});
    if(result.canceled)return null;
    chosenFolder=await fs.realpath(result.filePaths[0]);
    return chosenFolder;
  }
  if(action==='sample'){
    if(!sample){
      const dir=await fs.mkdtemp(path.join(app.getPath('temp'),'quickunzip-sample-'));
      sample=path.join(dir,'PackAtlas Sample.zip');
      await fs.copyFile(path.join(ui,'sample.zip'),sample);
    }
    return register([sample]);
  }
  if(action==='reveal'){
    if(typeof data.path!=='string'||!path.isAbsolute(data.path))throw new ArchiveError('notFound');
    await fs.stat(data.path);
    shell.showItemInFolder(data.path);
    return true;
  }
  if(action==='cancel'){
    if(current?.id===data.job)current.controller.abort();
    return true;
  }
  const source=sources.get(data.id);
  if(!source)throw new ArchiveError('notFound');
  if(current||!['list','extract','test'].includes(action))throw new ArchiveError('operationFailed');
  const controller=new AbortController();
  current={id:data.id,controller};
  const opts={...data,destination:data.destination===chosenFolder?chosenFolder:undefined};
  try {
    return await perform(decoder,source,action,opts,{signal:controller.signal,percent:value=>{
      if(!mainWindow.isDestroyed())mainWindow.webContents.send('qz:progress',{id:data.id,percent:value});
    }});
  } finally {current=undefined;if(quitting)app.quit();}
}

function startWindow() {
  mainWindow=new BrowserWindow({title:'PackAtlas',width:1190,height:845,minWidth:680,minHeight:550,backgroundColor:'#f7f1e4',
    webPreferences:{preload:path.join(desktop,'preload.cjs'),contextIsolation:true,sandbox:true,nodeIntegration:false}});
  Menu.setApplicationMenu(null);
  mainWindow.webContents.on('will-navigate',(event)=>event.preventDefault());
  mainWindow.webContents.setWindowOpenHandler(()=>({action:'deny'}));
  mainWindow.webContents.session.setPermissionRequestHandler((_contents,_permission,callback)=>callback(false));
  ipcMain.handle('qz:call',async(event,action,data)=>{
    if(event.senderFrame!==mainWindow.webContents.mainFrame || typeof action!=='string' || !data || typeof data!=='object')return {error:'operationFailed'};
    try{return await handle(action,data);}catch(error){return errorReply(error);}
  });
  mainWindow.on('close',()=>current?.controller.abort());
  mainWindow.loadFile(path.join(ui,'index.html'));
}
if(!app.requestSingleInstanceLock())app.quit();
else {
  app.on('second-instance',(_event,argv)=>{enqueue(argvFiles(argv));mainWindow?.focus();});
  app.on('open-file',(event,file)=>{event.preventDefault();enqueue([file]);});
  app.whenReady().then(()=>{startWindow();enqueue(argvFiles(process.argv));});
  app.on('window-all-closed',()=>app.quit());
  app.on('before-quit',event=>{
    if(current){event.preventDefault();quitting=true;current.controller.abort();}
  });
}
