'use strict';
const {contextBridge,ipcRenderer,webUtils}=require('electron');
contextBridge.exposeInMainWorld('qz',{
  call:(action,data)=>ipcRenderer.invoke('qz:call',action,data),
  onOpen:listener=>ipcRenderer.on('qz:open',(_event,value)=>listener(value)),
  onProgress:listener=>ipcRenderer.on('qz:progress',(_event,value)=>listener(value)),
  drop:files=>ipcRenderer.invoke('qz:call','drop',{paths:files.map(file=>webUtils.getPathForFile(file)).filter(Boolean)})
});
