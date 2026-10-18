// Coconut POS Stand alone for Windows: runs the shop's local server and shows the POS in its own window.
// Other devices on the same Wi-Fi/LAN open http://<this computer's address>:<port> in a browser.
'use strict';
const { app, BrowserWindow, dialog, ipcMain, Menu, shell, clipboard } = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');

const APP_DIR = path.join(__dirname, 'app');
const WWW = path.join(APP_DIR, 'www').replace('app.asar', 'app.asar.unpacked');
const { createServer } = require(path.join(APP_DIR, 'server', 'server.js'));

if (!app.requestSingleInstanceLock()) { app.quit(); }

let win = null, srv = null, info = null, quitting = false;
const dataDir = path.join(app.getPath('documents'), 'CoconutPOS');
const cfgFile = path.join(dataDir, 'config.json');
function readCfg() { try { return JSON.parse(fs.readFileSync(cfgFile, 'utf8')); } catch (e) { return {}; } }
function writeCfg(c) { try { fs.mkdirSync(dataDir, { recursive: true }); fs.writeFileSync(cfgFile, JSON.stringify(c, null, 2)); } catch (e) {} }

async function startServer() {
  const cfg = readCfg();
  const ports = [cfg.port || 8080].concat([8080, 8081, 8082, 8083, 8084, 8085, 8086, 8087, 8088, 8089, 8090].filter((p) => p !== (cfg.port || 8080)));
  let lastErr = null;
  for (const port of ports) {
    const s = createServer({ dataDir, wwwDir: WWW, port, platform: 'windows', version: app.getVersion(), deviceName: os.hostname() });
    try { info = await s.start(); srv = s; if (cfg.port !== port) writeCfg(Object.assign(cfg, { port })); return; }
    catch (e) { lastErr = e; await s.stop().catch(() => {}); if (e.code !== 'EADDRINUSE') break; }
  }
  throw lastErr || new Error('cannot start');
}

function lanText() {
  const i = srv ? srv.info() : info;
  const list = (i.lan || []).map((a) => `http://${a}:${i.port}`);
  return list.length ? list : [`http://localhost:${i.port}`];
}

function buildMenu() {
  const tpl = [
    { label: 'Coconut POS', submenu: [
      { label: 'ที่อยู่สำหรับเครื่องอื่นในร้าน', click: () => { const l = lanText(); dialog.showMessageBox(win, { type: 'info', title: 'ใช้งานหลายเครื่อง', message: 'ให้เครื่องอื่นที่ต่อ Wi-Fi/LAN เดียวกันเปิดเบราว์เซอร์ไปที่', detail: l.join('\n') + '\n\nกด "คัดลอก" เพื่อคัดลอกที่อยู่', buttons: ['คัดลอก', 'ปิด'] }).then((r) => { if (r.response === 0) clipboard.writeText(l[0]); }); } },
      { label: 'เปิดโฟลเดอร์ข้อมูลและไฟล์สำรอง', click: () => shell.openPath(dataDir) },
      { type: 'separator' },
      { label: 'เปิดอัตโนมัติเมื่อเปิดเครื่อง', type: 'checkbox', checked: app.getLoginItemSettings().openAtLogin, click: (m) => app.setLoginItemSettings({ openAtLogin: m.checked }) },
      { type: 'separator' },
      { label: 'ออกจากโปรแกรม', click: () => { quitting = false; win && win.close(); } },
    ] },
    { label: 'มุมมอง', submenu: [
      { label: 'โหลดใหม่', accelerator: 'F5', click: () => win && win.reload() },
      { label: 'เต็มจอ', accelerator: 'F11', click: () => win && win.setFullScreen(!win.isFullScreen()) },
      { role: 'zoomIn', label: 'ขยาย' }, { role: 'zoomOut', label: 'ย่อ' }, { role: 'resetZoom', label: 'ขนาดปกติ' },
      { type: 'separator' }, { role: 'toggleDevTools', label: 'เครื่องมือนักพัฒนา' },
    ] },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(tpl));
}

function createWindow() {
  win = new BrowserWindow({
    width: 1366, height: 860, minWidth: 900, minHeight: 600, title: 'Coconut POS', backgroundColor: '#F3F7FB',
    icon: path.join(__dirname, 'build', 'icon.png'), autoHideMenuBar: true,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: true, spellcheck: false },
  });
  win.loadURL(`http://localhost:${info.port}/`);
  win.webContents.setWindowOpenHandler(({ url }) => { if (/^https?:\/\//.test(url) && !url.startsWith(`http://localhost:${info.port}`)) shell.openExternal(url); return { action: 'deny' }; });
  win.webContents.on('will-navigate', (e, url) => { if (!url.startsWith(`http://localhost:${info.port}`)) { e.preventDefault(); shell.openExternal(url); } });
  win.on('close', (e) => {
    if (quitting) return;
    e.preventDefault();
    dialog.showMessageBox(win, { type: 'question', buttons: ['ปิดโปรแกรม', 'ยกเลิก'], defaultId: 1, cancelId: 1, title: 'ปิด Coconut POS',
      message: 'ปิดโปรแกรม Coconut POS?', detail: 'เครื่องนี้เป็นเครื่องหลักที่เก็บข้อมูล ถ้าปิด เครื่องอื่นในร้านจะใช้งานไม่ได้จนกว่าจะเปิดใหม่' })
      .then((r) => { if (r.response === 0) { quitting = true; win.close(); } });
  });
  win.on('closed', () => { win = null; });
}

// Silent printing to the default printer: receipts and kitchen tickets come out with no dialog.
ipcMain.handle('coconut:print', async (_e, html) => {
  if (typeof html !== 'string' || html.length > 5 * 1024 * 1024) return false;
  const pw = new BrowserWindow({ show: false, webPreferences: { preload: path.join(__dirname, 'print-preload.js'), contextIsolation: false, sandbox: false } });
  const done = () => { if (!pw.isDestroyed()) pw.close(); };
  setTimeout(done, 60000);
  await pw.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(html), { baseURLForDataURL: `http://localhost:${info.port}/` }).catch(() => {});
  return true;
});
ipcMain.on('coconut:do-print', (e) => {
  const pw = BrowserWindow.fromWebContents(e.sender);
  if (!pw) return;
  pw.webContents.print({ silent: true, printBackground: true, margins: { marginType: 'none' } }, () => { if (!pw.isDestroyed()) pw.close(); });
});
ipcMain.handle('coconut:info', () => ({ platform: 'windows', version: app.getVersion(), dataDir, lan: lanText() }));
ipcMain.handle('coconut:open-data', () => shell.openPath(dataDir));

app.on('second-instance', () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });
app.whenReady().then(async () => {
  const cfg = readCfg();
  if (!cfg.loginItemSet) { app.setLoginItemSettings({ openAtLogin: true }); writeCfg(Object.assign(cfg, { loginItemSet: true })); }
  try { await startServer(); }
  catch (e) {
    dialog.showErrorBox('Coconut POS เปิดไม่ได้', 'เริ่มระบบไม่สำเร็จ: ' + (e && e.message) + '\nลองปิดโปรแกรมอื่นที่ใช้พอร์ต 8080-8090 แล้วเปิดใหม่');
    app.quit(); return;
  }
  buildMenu();
  createWindow();
});
app.on('before-quit', () => { quitting = true; });
app.on('window-all-closed', async () => { if (srv) await srv.stop().catch(() => {}); app.quit(); });
