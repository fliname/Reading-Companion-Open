const { app, BrowserWindow, Menu, dialog, ipcMain, shell, clipboard, safeStorage } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const { ReadingStore } = require('./store.cjs');
const { requestAI, cancelAI, listModels, detectOfficialProvider } = require('./ai-service.cjs');
const OCRService = require('./ocr-service.cjs');
const ObsidianService = require('./obsidian-service.cjs');

const windows = new Map();
const speechProcesses = new Map();
let store;

if (!app.isPackaged) app.setName('Reading Companion Windows Preview');

function isPublicEdition() {
  if (process.env.RC_PUBLIC_BUILD === '1') return true;
  try {
    const metadata = JSON.parse(fs.readFileSync(path.join(app.getAppPath(), 'package.json'), 'utf8'));
    return metadata.edition === 'public';
  } catch { return false; }
}

function installApplicationMenu() {
  const sendToWindow = (window, channel) => {
    if (window && !window.isDestroyed()) window.webContents.send(channel);
  };
  const template = [
    {
      label: '文件',
      submenu: [
        { label: '打开 PDF…', accelerator: 'CmdOrCtrl+O', click: (_item, window) => sendToWindow(window, 'menu:open-pdf') },
        { label: '新建窗口', accelerator: 'CmdOrCtrl+N', click: () => createWindow() },
        { type: 'separator' },
        { label: '关闭窗口', accelerator: 'CmdOrCtrl+W', role: 'close' },
        { type: 'separator' },
        { label: '退出', role: 'quit' }
      ]
    },
    {
      label: '编辑',
      submenu: [
        { label: '撤销', accelerator: 'CmdOrCtrl+Z', role: 'undo' },
        { label: '重做', accelerator: 'Shift+CmdOrCtrl+Z', role: 'redo' },
        { type: 'separator' },
        { label: '剪切', accelerator: 'CmdOrCtrl+X', role: 'cut' },
        { label: '复制', accelerator: 'CmdOrCtrl+C', role: 'copy' },
        { label: '粘贴', accelerator: 'CmdOrCtrl+V', role: 'paste' },
        { label: '删除', role: 'delete' },
        { type: 'separator' },
        { label: '全选', accelerator: 'CmdOrCtrl+A', role: 'selectAll' }
      ]
    },
    {
      label: '视图',
      submenu: [
        { label: '重新加载', accelerator: 'CmdOrCtrl+R', role: 'reload' },
        { label: '开发者工具', accelerator: 'CmdOrCtrl+Shift+I', role: 'toggleDevTools' },
        { type: 'separator' },
        { label: '实际大小', accelerator: 'CmdOrCtrl+0', role: 'resetZoom' },
        { label: '放大', accelerator: 'CmdOrCtrl+Plus', role: 'zoomIn' },
        { label: '缩小', accelerator: 'CmdOrCtrl+-', role: 'zoomOut' },
        { type: 'separator' },
        { label: '切换全屏', accelerator: 'F11', role: 'togglefullscreen' }
      ]
    },
    {
      label: '窗口',
      submenu: [
        { label: '最小化', role: 'minimize' },
        {
          label: '最大化/还原',
          click: (_item, window) => {
            if (!window || window.isDestroyed()) return;
            if (window.isMaximized()) window.unmaximize();
            else window.maximize();
          }
        },
        { label: '关闭窗口', role: 'close' },
        { type: 'separator' },
        { label: '置于前台', click: (_item, window) => { window?.show(); window?.focus(); } }
      ]
    }
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

function createWindow(initialProject = null) {
  const window = new BrowserWindow({
    width: 1500,
    height: 940,
    minWidth: 1080,
    minHeight: 680,
    backgroundColor: '#f4f3f7',
    title: isPublicEdition() ? 'Reading Companion Open' : 'Reading Companion',
    icon: path.join(__dirname, '..', '..', 'resources', 'AppIcon-1024.png'),
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      webviewTag: false,
      additionalArguments: ['--public-edition']
    }
  });

  windows.set(window.webContents.id, { window, initialProject });
  const webContentsID = window.webContents.id;
  window.on('closed', () => {
    stopSpeech(webContentsID);
    windows.delete(webContentsID);
  });
  window.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:|^obsidian:/.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
  window.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));
  return window;
}

function resourcePath(name) {
  const base = app.isPackaged ? process.resourcesPath : path.join(__dirname, '..', '..', 'resources');
  return path.join(base, name);
}

function stopSpeech(webContentsID) {
  const child = speechProcesses.get(webContentsID);
  if (!child) return false;
  speechProcesses.delete(webContentsID);
  try { child.kill(); } catch {}
  return true;
}

function sendIfAlive(sender, channel, payload) {
  if (!sender || sender.isDestroyed()) return false;
  try { sender.send(channel, payload); return true; } catch { return false; }
}

function registerIPC() {
  ipcMain.handle('dialog:open-pdf', async event => {
    const result = await dialog.showOpenDialog(BrowserWindow.fromWebContents(event.sender), {
      title: '选择要伴读的 PDF',
      properties: ['openFile'],
      filters: [{ name: 'PDF', extensions: ['pdf'] }]
    });
    return result.canceled ? null : result.filePaths[0];
  });

  ipcMain.handle('dialog:open-folder', async event => {
    const result = await dialog.showOpenDialog(BrowserWindow.fromWebContents(event.sender), {
      title: '选择 Obsidian Vault',
      properties: ['openDirectory', 'createDirectory']
    });
    return result.canceled ? null : result.filePaths[0];
  });

  ipcMain.handle('pdf:read', (_event, sourcePath) => {
    if (!sourcePath || path.extname(sourcePath).toLowerCase() !== '.pdf') throw new Error('目前只支持 PDF 文件。');
    return fs.readFileSync(sourcePath);
  });
  ipcMain.handle('file:stat', (_event, target) => {
    const value = fs.statSync(target);
    return { size: value.size, modifiedAt: value.mtimeMs };
  });

  ipcMain.handle('ocr:recognize', async (event, payload) => OCRService.recognize(
    payload,
    app.isPackaged ? process.resourcesPath : path.join(__dirname, '..', '..', 'resources'),
    progress => {
      if (!event.sender.isDestroyed()) event.sender.send('ocr:progress', { jobId: payload.jobId, ...progress });
    }
  ));
  ipcMain.handle('ocr:cancel', (_event, jobId) => OCRService.cancel(jobId));

  ipcMain.handle('project:initial', event => windows.get(event.sender.id)?.initialProject || null);
  ipcMain.handle('project:list', () => store.listProjects());
  ipcMain.handle('project:load', (_event, sourcePath) => store.loadProject(sourcePath));
  ipcMain.handle('project:save', (_event, { sourcePath, state }) => {
    store.saveProject(sourcePath, state);
    store.registerProject(sourcePath, state.documentTitle || path.basename(sourcePath, '.pdf'));
    return true;
  });
  ipcMain.handle('project:delete', (_event, sourcePath) => {
    store.deleteProject(sourcePath);
    return true;
  });
  ipcMain.handle('project:open', (event, { sourcePath, currentPath }) => {
    if (!currentPath) {
      event.sender.send('project:open-in-place', sourcePath);
      return { destination: 'current-window' };
    }
    if (path.resolve(currentPath) === path.resolve(sourcePath)) return { destination: 'already-open' };
    createWindow(sourcePath);
    return { destination: 'new-window' };
  });

  ipcMain.handle('derived:load', (_event, sourcePath) => store.loadDerived(sourcePath));
  ipcMain.handle('derived:save', (_event, { sourcePath, value }) => {
    store.saveDerived(sourcePath, value);
    return true;
  });

  ipcMain.handle('settings:load', () => store.loadSettings());
  ipcMain.handle('settings:save', (_event, settings) => {
    store.saveSettings(settings);
    return true;
  });
  ipcMain.handle('ai:list-models', (_event, settings) => listModels(settings));
  ipcMain.handle('ai:detect-provider', (_event, apiKey) => detectOfficialProvider(apiKey));
  ipcMain.handle('ai:request', async (event, request) => requestAI(request, delta => {
    if (!event.sender.isDestroyed()) event.sender.send('ai:progress', { id: request.id, delta });
  }));
  ipcMain.handle('ai:cancel', (_event, id) => cancelAI(id));

  ipcMain.handle('speech:start', (event, language = 'zh-CN') => {
    const sender = event.sender;
    const senderID = sender.id;
    stopSpeech(senderID);
    if (process.platform !== 'win32') return { started: false, reason: 'Windows 语音输入只能在 Windows 上测试。' };
    const script = resourcePath('windows-speech.ps1');
    const child = spawn('powershell.exe', ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script, '-Language', language], {
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe']
    });
    speechProcesses.set(senderID, child);
    let pending = '';
    child.stdout.on('data', chunk => {
      pending += chunk.toString('utf8');
      const lines = pending.split(/\r?\n/);
      pending = lines.pop() || '';
      for (const line of lines) {
        try { sendIfAlive(sender, 'speech:result', JSON.parse(line)); } catch {}
      }
    });
    child.stderr.on('data', chunk => sendIfAlive(sender, 'speech:result', { error: chunk.toString('utf8').trim() }));
    child.on('error', error => {
      speechProcesses.delete(senderID);
      sendIfAlive(sender, 'speech:result', { error: `无法启动 Windows 语音输入：${error.message}` });
    });
    child.on('exit', () => speechProcesses.delete(senderID));
    return { started: true };
  });
  ipcMain.handle('speech:stop', event => stopSpeech(event.sender.id));

  ipcMain.handle('clipboard:read', () => clipboard.readText());
  ipcMain.handle('clipboard:write', (_event, text) => { clipboard.writeText(String(text || '')); return true; });
  ipcMain.handle('file:write-text', (_event, { target, content }) => {
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, content, 'utf8');
    return true;
  });
  ipcMain.handle('file:read-text', (_event, target) => fs.readFileSync(target, 'utf8'));
  ipcMain.handle('file:exists', (_event, target) => fs.existsSync(target));
  ipcMain.handle('shell:open-path', (_event, target) => shell.openPath(target));
  ipcMain.handle('shell:open-external', (_event, target) => shell.openExternal(target));
  const obsidianRegistryPath = () => path.join(app.getPath('appData'), 'obsidian', 'obsidian.json');
  ipcMain.handle('obsidian:list-vaults', () => ObsidianService.registeredVaults(obsidianRegistryPath()));
  ipcMain.handle('obsidian:resolve-vault', (_event, candidate) => {
    const registered = ObsidianService.registeredVaults(obsidianRegistryPath());
    return ObsidianService.exactVault(candidate, registered);
  });
  ipcMain.handle('obsidian:open-note', async (_event, { vaultPath, notePath }) => {
    const registered = ObsidianService.registeredVaults(obsidianRegistryPath());
    const configured = ObsidianService.exactVault(vaultPath, registered);
    const vault = configured && ObsidianService.containingVault(notePath, [configured])
      ? configured
      : ObsidianService.containingVault(notePath, registered);
    if (!vault) {
      const list = registered.length ? registered.join('\n') : '没有检测到已注册 Vault';
      throw new Error(`当前笔记不在 Obsidian 已注册的 Vault 中。请先在 Obsidian 中使用“打开文件夹作为仓库”，再在设置中选择该 Vault。\n\n已注册 Vault：\n${list}`);
    }
    const url = ObsidianService.openURL(vault, notePath);
    if (!url) throw new Error('笔记路径不在所选 Obsidian Vault 内。');
    await shell.openExternal(url);
    return { opened: true, url, vaultPath: vault };
  });
  ipcMain.handle('system:documents-path', () => app.getPath('documents'));
  ipcMain.handle('system:join-path', (_event, parts) => path.join(...parts.map(String)));
  ipcMain.handle('system:resource-path', (_event, name) => resourcePath(name));
  ipcMain.handle('system:sha256', (_event, value) => crypto.createHash('sha256').update(String(value), 'utf8').digest('hex'));
}

app.whenReady().then(() => {
  store = new ReadingStore(app.getPath('userData'), safeStorage);
  registerIPC();
  installApplicationMenu();
  createWindow(process.env.RC_TEST_PDF || null);
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});

app.on('window-all-closed', async () => {
  await OCRService.terminate();
  app.quit();
});
