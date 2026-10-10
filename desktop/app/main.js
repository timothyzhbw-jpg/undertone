// 桌面版的主进程：窗口、设置、调本地模型、列出可看的窗口、OCR。
// 界面在 renderer/，分析逻辑在 core/（和 Mac 版一致）。
'use strict';

const { app, BrowserWindow, ipcMain, desktopCapturer, shell, clipboard, session } = require('electron');
const fs = require('fs');
const path = require('path');
const core = require('../core/undertone');
const ocr = require('./ocr');

// 和 Mac 版（Swift）的数据目录分开：两个都叫 Undertone
app.setPath('userData', path.join(app.getPath('appData'), 'Undertone Desktop'));
const settingsFile = () => path.join(app.getPath('userData'), 'settings.json');
const DEFAULTS = {
  ui: null,                       // 'en' | 'zh'；null 表示跟系统语言
  explanation: null,              // 解释用的语言；null 表示跟界面语言
  relationship: '不确定',
  ollamaURL: 'http://127.0.0.1:11434',
  model: 'qwen3.5:4b',
  alwaysOnTop: true,
  mode: 'paste',                  // 'live' | 'paste'
  windowName: null,               // 实时模式看的窗口（按标题记住，窗口 id 每次启动都会变）
  cropTop: 12,                    // 实时模式：去掉窗口顶部（标题、联系人名字）和底部（输入框）的百分比
  cropBottom: 18,
  interval: 2,
};

function loadSettings() {
  try { return { ...DEFAULTS, ...JSON.parse(fs.readFileSync(settingsFile(), 'utf8')) }; }
  catch { return { ...DEFAULTS }; }
}
let settings;

function saveSettings(patch) {
  settings = { ...settings, ...patch };
  fs.mkdirSync(path.dirname(settingsFile()), { recursive: true });
  fs.writeFileSync(settingsFile(), JSON.stringify(settings, null, 2));
  if ('alwaysOnTop' in patch && panel) panel.setAlwaysOnTop(!!settings.alwaysOnTop, 'floating');
  return settings;
}

const uiLanguage = () => settings.ui || (app.getLocale().startsWith('zh') ? 'zh' : 'en');
const explanation = () => settings.explanation || uiLanguage();
const ollama = () => ({ baseURL: settings.ollamaURL, model: settings.model });

let panel;

function createPanel() {
  panel = new BrowserWindow({
    width: 390, height: 760, minWidth: 340, minHeight: 520,
    title: 'Undertone',
    alwaysOnTop: !!settings.alwaysOnTop,
    backgroundColor: '#f4f5f7',
    autoHideMenuBar: true,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false, sandbox: true },
  });
  if (settings.alwaysOnTop) panel.setAlwaysOnTop(true, 'floating');
  panel.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  // 链接用系统浏览器打开，不在面板里跳转
  panel.webContents.setWindowOpenHandler(({ url }) => { shell.openExternal(url); return { action: 'deny' }; });
}

// 实时模式：界面用 getDisplayMedia 取选中窗口的画面，这里告诉 Chromium 选哪一个
function setupCapture() {
  session.defaultSession.setDisplayMediaRequestHandler(async (_request, callback) => {
    const sources = await desktopCapturer.getSources({ types: ['window'] });
    const source = sources.find(s => s.id === pendingSourceId) || sources.find(s => s.name === settings.windowName);
    callback(source ? { video: source } : {});
  });
}
let pendingSourceId = null;

ipcMain.handle('settings:get', () => ({ ...settings, uiResolved: uiLanguage(), explanationResolved: explanation(),
  languages: core.EXPLANATION_LANGUAGES, vocabulary: core.vocabulary, flags: core.flags, version: app.getVersion(), platform: process.platform }));
ipcMain.handle('settings:set', (_e, patch) => saveSettings(patch));

ipcMain.handle('analyze', async (_e, { context, latest }) => {
  try {
    return { report: await core.analyze({ context, latest, explanation: explanation(), relationship: settings.relationship, ollama: ollama() }) };
  } catch (error) { return { error: error.message }; }
});

ipcMain.handle('draft', async (_e, { context, draft }) => {
  try {
    return { review: await core.checkDraft({ context, draft, explanation: explanation(), relationship: settings.relationship, ollama: ollama() }) };
  } catch (error) { return { error: error.message }; }
});

ipcMain.handle('transcript:parse', (_e, text) => core.parseTranscript(text));
ipcMain.handle('flags:active', (_e, report) => core.activeFlags(report));

// 列出可以看的窗口（不含自己）；缩略图给界面里的选择列表用
ipcMain.handle('windows:list', async () => {
  const sources = await desktopCapturer.getSources({ types: ['window'], thumbnailSize: { width: 240, height: 160 } });
  return sources.filter(s => s.name && s.name !== 'Undertone')
    .map(s => ({ id: s.id, name: s.name, thumbnail: s.thumbnail.isEmpty() ? null : s.thumbnail.toDataURL() }));
});
ipcMain.handle('windows:choose', (_e, { id, name }) => { pendingSourceId = id; saveSettings({ windowName: name }); return true; });

// OCR：png 是 data URL；live 为 true 时只要消息列表，否则还要拼好的粘贴文字
ipcMain.handle('ocr', async (_e, { png, live }) => {
  try {
    const result = await ocr.read(Buffer.from(png.split(',')[1], 'base64'));
    return live ? { messages: result.messages } : { ...result, transcript: core.screenshotTranscript(result.messages, result.lines) };
  } catch (error) { return { error: error.message }; }
});

// 测试用：UNDERTONE_REPLAY=一个放着聊天截图（PNG）的目录时，实时模式按文件名顺序把它们当成窗口画面，不截屏
ipcMain.handle('replay:frames', () => {
  const dir = process.env.UNDERTONE_REPLAY;
  if (!dir) return null;
  return fs.readdirSync(dir).filter(f => f.endsWith('.png')).sort()
    .map(f => 'data:image/png;base64,' + fs.readFileSync(path.join(dir, f)).toString('base64'));
});

ipcMain.handle('clipboard:write', (_e, text) => { clipboard.writeText(text); return true; });
ipcMain.handle('clipboard:readImage', () => {
  const image = clipboard.readImage();
  return image.isEmpty() ? null : image.toDataURL();
});
ipcMain.handle('open', (_e, url) => { if (/^https:\/\//.test(url)) shell.openExternal(url); });

app.whenReady().then(() => {
  settings = loadSettings();
  setupCapture();
  createPanel();
  app.on('activate', () => { if (!BrowserWindow.getAllWindows().length) createPanel(); });
});

app.on('window-all-closed', () => app.quit());
app.on('before-quit', () => ocr.close());
