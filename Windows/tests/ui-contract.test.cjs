const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const renderer = path.join(__dirname, '..', 'src', 'renderer');

test('手动目录只保留自动应用层级控件和底部取消入口', () => {
  const html = fs.readFileSync(path.join(renderer, 'index.html'), 'utf8');
  const app = fs.readFileSync(path.join(renderer, 'app.mjs'), 'utf8');

  assert.match(html, /id="manualBatchLevel"/);
  assert.doesNotMatch(html, /id="applyManualBatchLevel"|id="manualPageShift"|id="shiftManualPages"/);
  assert.doesNotMatch(html, /id="pasteManualOutline"|id="closeManualOutline"/);
  assert.match(app, /\$\('#manualBatchLevel'\)\.onchange = applyManualBatchLevel/);
});

test('概要卡片使用紧凑列表间距且不保留 HTML 节点间空白', () => {
  const css = fs.readFileSync(path.join(renderer, 'styles.css'), 'utf8');

  assert.match(css, /\.outline-summary \{[^}]*white-space: normal;/s);
  assert.match(css, /\.outline-summary ul, \.outline-summary ol \{[^}]*padding-left: 18px;/s);
  assert.match(css, /\.outline-summary li \{[^}]*margin: 1px 0;/s);
});

test('AI 对话的两个加入笔记入口都提供保留原文和整理浓缩', () => {
  const html = fs.readFileSync(path.join(renderer, 'index.html'), 'utf8');
  const app = fs.readFileSync(path.join(renderer, 'app.mjs'), 'utf8');

  assert.doesNotMatch(html, /原文\s*30%/);
  assert.equal((html.match(/>保留原文</g) || []).length, 2);
  assert.equal((html.match(/>整理浓缩</g) || []).length, 2);
  assert.match(html, /id="chatNoteExportDialog"/);
  assert.match(html, /class="chat-note-export-cancel"[^>]*>取消<\/button>/);
  assert.match(fs.readFileSync(path.join(renderer, 'styles.css'), 'utf8'), /\.chat-note-export-actions \.chat-note-export-cancel \{[^}]*border: 0;/s);
  assert.match(app, /\$\('#addChatsToNotes'\)\.onclick = openChatNoteExportDialog/);
  assert.match(app, /addSelectedChatsToNotes\(\{ mode, collapsed \}\)/);
});

test('AI 模型和阅读模式使用可交互菜单并串行持久化', () => {
  const html = fs.readFileSync(path.join(renderer, 'index.html'), 'utf8');
  const css = fs.readFileSync(path.join(renderer, 'styles.css'), 'utf8');
  const app = fs.readFileSync(path.join(renderer, 'app.mjs'), 'utf8');

  assert.match(html, /id="modelMenuButton"[^>]*aria-haspopup="menu"/);
  assert.match(html, /id="depthMenuButton"[^>]*aria-haspopup="menu"/);
  assert.match(html, /id="modelSelector" class="hidden"/);
  assert.match(html, /id="depthSelector" class="hidden"/);
  assert.match(css, /\.ai-selector-menu \{[^}]*z-index: 40;/s);
  assert.match(app, /async function selectAIModel\(model\)[\s\S]*已切换模型/);
  assert.match(app, /async function selectReadingDepth\(value\)[\s\S]*已切换阅读模式/);
  assert.match(app, /settingsSaveChain = settingsSaveChain\.catch\(\(\) => \{\}\)\.then\(\(\) => api\.saveSettings\(snapshot\)\)/);
  assert.match(app, /const depthKey = currentReadingDepth\(\); const depth = DEPTHS\[depthKey\]/);
});

test('拖拽 PDF 使用 Electron 安全文件路径 API', () => {
  const preload = fs.readFileSync(path.join(__dirname, '..', 'src', 'main', 'preload.cjs'), 'utf8');
  const app = fs.readFileSync(path.join(renderer, 'app.mjs'), 'utf8');
  assert.match(preload, /webUtils/);
  assert.match(preload, /droppedFilePath: file => webUtils\.getPathForFile\(file\)/);
  assert.match(app, /api\.droppedFilePath\(file\)/);
  assert.match(app, /pdf-drop-target/);
});

test('自动升级支持提示、稍后提醒和忽略版本', () => {
  const main = fs.readFileSync(path.join(__dirname, '..', 'src', 'main', 'main.cjs'), 'utf8');
  assert.match(main, /checkForWindowsUpdate\(app\.getVersion\(\)\)/);
  assert.match(main, /\['立即升级', '稍后提醒', '忽略此版本'\]/);
  assert.match(main, /downloadWindowsUpdate/);
  assert.match(main, /shell\.openPath\(target\)/);
});

test('0.44 首次导入必须选择类型，虚构类具备人物与页码概要完整入口', () => {
  const html = fs.readFileSync(path.join(renderer, 'index.html'), 'utf8');
  const app = fs.readFileSync(path.join(renderer, 'app.mjs'), 'utf8');
  const css = fs.readFileSync(path.join(renderer, 'styles.css'), 'utf8');
  assert.match(html, /id="importCategoryDialog"/);
  assert.match(html, /data-book-category="nonfiction"/);
  assert.match(html, /data-book-category="fiction"/);
  assert.match(html, /id="charactersTabButton"/);
  assert.match(html, /id="characterManagementPanel"/);
  assert.match(app, /AI 伴读 · \$\{categoryLabel\}/);
  assert.match(app, /renderFictionSummaryPanel/);
  assert.match(app, /characterOccurrenceWindow\(records\)/);
  assert.match(app, /pdf\.goToTextOccurrence/);
  assert.match(css, /\.pdf-character-highlight\.first/);
});

test('全文搜索提交不移动阅读页，点击结果才做精确命中导航', () => {
  const app = fs.readFileSync(path.join(renderer, 'app.mjs'), 'utf8');
  const pdf = fs.readFileSync(path.join(renderer, 'pdf-controller.mjs'), 'utf8');
  assert.match(app, /searchMatchRanges\(query, source\)\.forEach/);
  assert.match(app, /state\.reflowReader\?\.goToSearch/);
  assert.match(app, /pdf\.goToTextOccurrence\(result\.pageIndex, query, result\.occurrenceIndex\)/);
  assert.match(pdf, /goToTextOccurrence\(pageIndex, query, occurrenceIndex = 0\)/);
  assert.match(pdf, /markSearchTarget\(mark, pageIndex, occurrenceIndex\)/);
});

test('书架文件夹删除只在批量管理中出现并要求确认', () => {
  const library = fs.readFileSync(path.join(renderer, 'library-view.mjs'), 'utf8');
  assert.match(library, /书籍类型/);
  assert.match(library, /folderIDs/);
  assert.match(library, /remove-from-folder/);
  assert.match(library, /_showProjectContextMenu/);
  assert.match(library, /onDeleteFolder/);
  assert.match(library, /if \(this\.isSelecting\) \{[\s\S]*folder-delete/);
  assert.match(library, /confirm\(`删除文件夹/);
  assert.doesNotMatch(library, /_showFolderContextMenu/);
});

test('四个方向键全局翻页且电子书已有划线可重新打开浮窗', () => {
  const app = fs.readFileSync(path.join(renderer, 'app.mjs'), 'utf8');
  const pdf = fs.readFileSync(path.join(renderer, 'pdf-controller.mjs'), 'utf8');
  const reflow = fs.readFileSync(path.join(renderer, 'reflow-reader.mjs'), 'utf8');
  const template = fs.readFileSync(path.join(renderer, 'reflow-template.mjs'), 'utf8');
  assert.match(app, /ArrowDown'[\s\S]*ArrowRight'[\s\S]*reflowReader\?\.turn\(1\)/);
  assert.match(app, /ArrowUp'[\s\S]*ArrowLeft'[\s\S]*reflowReader\?\.turn\(-1\)/);
  assert.match(pdf, /ArrowDown'[\s\S]*ArrowRight'[\s\S]*this\.nextPage\(\)/);
  assert.match(pdf, /ArrowUp'[\s\S]*ArrowLeft'[\s\S]*this\.previousPage\(\)/);
  assert.match(reflow, /case 'reader:mark'/);
  assert.match(reflow, /onMark\(callback\)/);
  assert.match(template, /markHitRects/);
  assert.match(template, /type:'reader:mark'/);
  assert.match(app, /function handleReflowMark\(payload\)/);
  assert.match(app, /toolbar\.style\.top = `\$\{Math\.max\(8, below\)\}px`/);
});
