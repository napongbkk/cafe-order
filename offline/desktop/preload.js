// Tells the POS page it runs on the shop's main machine (Windows) and gives it silent printing.
'use strict';
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('COCONUT_HOST', {
  platform: 'windows',
  print: (html) => ipcRenderer.invoke('coconut:print', String(html)),
  info: () => ipcRenderer.invoke('coconut:info'),
  openData: () => ipcRenderer.invoke('coconut:open-data'),
});
