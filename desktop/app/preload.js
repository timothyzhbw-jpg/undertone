// 界面能用的接口（contextIsolation 下只暴露这些）。
'use strict';
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('undertone', {
  settings: () => ipcRenderer.invoke('settings:get'),
  save: patch => ipcRenderer.invoke('settings:set', patch),
  analyze: (context, latest) => ipcRenderer.invoke('analyze', { context, latest }),
  checkDraft: (context, draft) => ipcRenderer.invoke('draft', { context, draft }),
  parseTranscript: text => ipcRenderer.invoke('transcript:parse', text),
  activeFlags: report => ipcRenderer.invoke('flags:active', report),
  windows: () => ipcRenderer.invoke('windows:list'),
  chooseWindow: (id, name) => ipcRenderer.invoke('windows:choose', { id, name }),
  ocr: (png, live) => ipcRenderer.invoke('ocr', { png, live }),
  copy: text => ipcRenderer.invoke('clipboard:write', text),
  clipboardImage: () => ipcRenderer.invoke('clipboard:readImage'),
  open: url => ipcRenderer.invoke('open', url),
  replayFrames: () => ipcRenderer.invoke('replay:frames'),
});
