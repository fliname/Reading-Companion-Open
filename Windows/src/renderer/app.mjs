import { marked } from './vendor/marked.esm.js';
import { PDFController } from './pdf-controller.mjs';
import { DEPTHS, makeChunks, normalizeText, prepareForPrompt, promptContext, renderMarkdown as renderDocumentMarkdown, retrieveForReading, estimatedTokens, searchMatchRanges } from '../shared/retrieval.mjs';
import { buildTOCText, calibrateManualTOC, detectTOCPages, inferHierarchy, manualCalibrationPageIndices, parseAutomaticTOC, parseManualTOC, resolveTOCPages } from '../shared/toc.mjs';
import { aiBlock, chapterForPage, ensureOutline, highlightBlock, insertUnderChapter, safeFileName, skeleton } from '../shared/notes.mjs';
import { markMatchesQuery } from '../shared/mark-search.mjs';
import { normalizeGroupedSelectionText } from '../shared/selection-group.mjs';

const $ = selector => document.querySelector(selector);
const $$ = selector => [...document.querySelectorAll(selector)];
const api = window.readingCompanion;

const state = {
  sourcePath: null,
  title: '',
  fingerprint: '',
  pages: [],
  chunks: [],
  outline: [],
  nativeOutline: [],
  nativeOutlineChecked: false,
  bookmarks: [],
  highlights: [],
  apiChats: [],
  summaries: {},
  answerCache: {},
  exportedMarkIDs: [],
  exportedChatIDs: [],
  lastPageIndex: 0,
  selectedText: '',
  selectedFragments: [],
  selectedMarkID: null,
  selectedQuick: null,
  currentRequest: null,
  lastUsage: null,
  manualPreview: [],
  manualTOCPageIndices: [],
  notePath: null,
  thumbnailGeneration: 0
};

let settings = {};
let speechActive = false;
let speechTranscript = '';
let pendingAnnotation = null;
let outlineSummariesVisible = false;
let highlightFilter = 'all';
let highlightSearchActive = false;
let fullSearchActive = false;
const expandedSummaryIDs = new Set();
const loadingSummaryIDs = new Set();

const pdf = new PDFController({
  container: $('#viewerContainer'),
  viewer: $('#pdfViewer'),
  onPageChange: pageIndex => {
    state.lastPageIndex = pageIndex;
    $('#pageField').value = pageIndex + 1;
    updateBookmarkButton();
    updateCurrentThumbnail();
    persistSoon();
  },
  onSelection: (event, selection) => { state.selectedMarkID = null; showSelectionToolbar(event, selection); },
  onStatus: message => setStatus(message),
  onOCRProgress: progress => setIndexStatus(progress),
  onScaleChange: () => updateZoom()
});
pdf.callbacks.onCreateMark = record => createMark(record);
pdf.callbacks.onMarkClick = (mark, event) => {
  state.selectedText = mark.text;
  state.selectedFragments = mark.fragments;
  state.selectedMarkID = mark.id;
  showSelectionToolbar(event, { text: mark.text, fragments: mark.fragments });
};

initialize().catch(showError);

async function initialize() {
  marked.setOptions({ gfm: true, breaks: true });
  settings = await api.loadSettings() || {};
  const registeredVaults = await api.listObsidianVaults();
  const configuredVault = settings.vaultPath ? await api.resolveObsidianVault(settings.vaultPath) : null;
  if (configuredVault) settings.vaultPath = configuredVault;
  else if (registeredVaults.length) settings.vaultPath = registeredVaults[0];
  else if (!settings.vaultPath) settings.vaultPath = await api.joinPath(await api.documentsPath(), 'Obsidian');
  if (!settings.vaultFolder) settings.vaultFolder = 'Reading Companion';
  await api.saveSettings(settings);
  bindUI();
  applyEdition();
  populateSettings();
  applySavedLayout();
  updateOutlineStatus();
  api.onOpenProjectInPlace(openDocument);
  api.onMenuOpenPDF(async () => { const path = await api.openPDFDialog(); if (path) await openOrNew(path); });
  api.onAIProgress(handleAIProgress);
  api.onOCRProgress(progress => {
    if (progress.status) setIndexStatus(`OCR · ${Math.round((progress.progress || 0) * 100)}%`);
  });
  api.onSpeech(handleSpeechResult);
  const initial = await api.getInitialProject();
  if (initial) await openDocument(initial);
}

function bindUI() {
  $('#openPDF').onclick = $('#emptyOpenPDF').onclick = async () => { const path = await api.openPDFDialog(); if (path) await openOrNew(path); };
  $('#openBookshelf').onclick = showBookshelf;
  $('#toggleSidebar').onclick = () => $('.workspace').classList.toggle('sidebar-hidden');
  $('#toggleAssistant').onclick = () => $('.workspace').classList.toggle('assistant-hidden');
  bindColumnResizers();
  $('#fitMode').onchange = event => { if (event.target.value !== 'custom') pdf.setScale(event.target.value); };
  $('#zoomOut').onclick = () => { pdf.zoom(-0.1); updateZoom(); };
  $('#zoomIn').onclick = () => { pdf.zoom(0.1); updateZoom(); };
  $('#rotatePage').onclick = () => pdf.rotate();
  $('#lockScroll').onclick = () => {
    pdf.setLocked(!pdf.locked);
    $('#viewerContainer').classList.toggle('locked', pdf.locked);
    $('#lockScroll').classList.toggle('active', pdf.locked);
    $('#lockScroll').title = pdf.locked ? '解除页面锁定' : '锁定左右滑动与缩放';
  };
  $('#toggleBookmark').onclick = toggleBookmark;
  $('#highlightMode').onclick = () => {
    pdf.highlightMode = !pdf.highlightMode;
    $('#highlightMode').classList.toggle('active', pdf.highlightMode);
  };
  $$('[data-highlight-color]').forEach(button => button.onclick = () => {
    pdf.highlightColor = button.dataset.highlightColor;
    $$('[data-highlight-color]').forEach(item => item.classList.toggle('selected', item === button));
  });
  $('#openNotes').onclick = () => { renderNotesSummary(); openDialog('notesDialog'); };
  $('#openSettings').onclick = () => { switchSettingsTab('api'); openDialog('settingsDialog'); };
  $('#previousPage').onclick = () => pdf.previousPage();
  $('#nextPage').onclick = () => pdf.nextPage();
  $('#pageField').onchange = event => pdf.goToPage(Number(event.target.value || 1) - 1);
  $$('.sidebar-tabs button').forEach(button => button.onclick = () => {
    switchSidebar(button.dataset.sidebarTab);
    if (button.dataset.sidebarTab === 'outline') setOutlineToolsVisible(true);
  });
  $('#toggleOutlineTools').onclick = () => setOutlineToolsVisible($('#outlineTools').classList.contains('hidden'));
  $('#recognizeOutline').onclick = recognizeOutline;
  $('#manualOutline').onclick = openManualOutlinePanel;
  $('#restoreEmbeddedOutline').onclick = restoreEmbeddedOutline;
  $('#toggleOutlineSummaries').onclick = () => {
    outlineSummariesVisible = !outlineSummariesVisible;
    if (!outlineSummariesVisible) expandedSummaryIDs.clear();
    $('#toggleOutlineSummaries').classList.toggle('active', outlineSummariesVisible);
    $('#toggleOutlineSummaries').title = outlineSummariesVisible ? '隐藏章节概要' : '显示章节概要的展开按钮';
    renderOutline();
  };
  $('#parseManualOutline').onclick = () => parseManual().catch(showError);
  $('#applyManualOutline').onclick = applyManual;
  $('#closeManualOutline').onclick = closeManualOutlinePanel;
  $('#cancelManualOutline').onclick = closeManualOutlinePanel;
  $('#pasteManualOutline').onclick = pasteManualOutline;
  $('#addManualEntry').onclick = addManualEntry;
  $('#selectAllManual').onchange = event => { state.manualPreview.forEach(entry => entry.selected = event.target.checked); renderManualPreview(); };
  $('#applyManualBatchLevel').onclick = applyManualBatchLevel;
  $('#shiftManualPages').onclick = shiftManualPages;
  $('#manualPageShift').oninput = updateManualSelectionState;
  $('#deleteManualEntries').onclick = deleteSelectedManualEntries;
  $('#createNotebook').onclick = createNotebook;
  $('#addOutlineToNotes').onclick = addOutlineToNotebook;
  $('#openNotebook').onclick = openNotebook;
  $('#selectAllMarks').onchange = event => $$('#highlightList input[type=checkbox]').forEach(input => input.checked = event.target.checked);
  $('#deleteMarks').onclick = deleteSelectedMarks;
  $('#mergeMarks').onclick = mergeSelectedMarks;
  $('#addMarksToNotes').onclick = addSelectedMarksToNotes;
  $$('[data-filter]').forEach(button => button.onclick = () => {
    highlightFilter = button.dataset.filter;
    renderHighlights();
    syncPageSearchHighlight();
  });
  $('#runHighlightSearch').onclick = toggleHighlightSearch;
  $('#highlightSearchInput').onkeydown = event => {
    if (event.key === 'Enter') { event.preventDefault(); activateHighlightSearch(); }
    if (event.key === 'Escape' && highlightSearchActive) cancelHighlightSearch();
  };
  $('#highlightSearchInput').oninput = () => { if (highlightSearchActive) { renderHighlights(); syncPageSearchHighlight(); } };
  $('#runSearch').onclick = toggleFullSearch;
  $('#searchInput').onkeydown = event => {
    if (event.key === 'Enter') { event.preventDefault(); activateFullSearch(); }
    if (event.key === 'Escape' && fullSearchActive) cancelFullSearch();
  };
  $('#searchInput').oninput = () => { if (fullSearchActive) activateFullSearch(); };
  $$('[data-selection-highlight]').forEach(button => button.onclick = () => {
    const selection = activeSelection();
    const existing = state.highlights.find(mark => mark.id === state.selectedMarkID);
    if (existing) { existing.color = button.dataset.selectionHighlight; existing.kind = 'highlight'; existing.note = ''; pdf.setMarks(state.highlights); renderHighlights(); persistSoon(); }
    else createMark({ ...selection, color: button.dataset.selectionHighlight, kind: 'highlight' });
    hideSelectionToolbar();
  });
  $('#annotateSelection').onclick = beginAnnotation;
  $('#askSelection').onclick = askSelection;
  $('#copySelection').onclick = async () => { await api.writeClipboard(activeSelection().text); hideSelectionToolbar(); setStatus('已复制'); };
  $('#sendAnnotation').onclick = commitAnnotation;
  $('#annotationText').onkeydown = event => {
    if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); commitAnnotation(); }
  };
  document.addEventListener('pointerdown', event => {
    if (!$('#annotationEditor').classList.contains('hidden') && !$('#annotationEditor').contains(event.target) && event.target !== $('#annotateSelection')) cancelAnnotation();
    const toolbar = $('#selectionToolbar');
    if (!toolbar.classList.contains('hidden') && !toolbar.contains(event.target) && !event.ctrlKey && !event.metaKey && !isSelectionNavigationTarget(event.target)) hideSelectionToolbar();
  });
  $$('[data-quick-question]').forEach(button => button.onclick = () => addQuickQuestion(button.dataset.quickQuestion));
  $('#sendQuestion').onclick = sendQuestion;
  $('#cancelAnswer').onclick = cancelAnswer;
  $('#questionInput').onkeydown = event => {
    if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) { event.preventDefault(); sendQuestion(); }
  };
  document.addEventListener('keydown', event => {
    if (event.key === 'Enter' && document.activeElement !== $('#questionInput') && state.selectedText && !state.currentRequest) sendQuestion();
  });
  document.addEventListener('click', event => {
    const link = event.target.closest?.('.chat-bubble a[href^="http"]');
    if (link) { event.preventDefault(); api.openExternal(link.href); }
  });
  $('#speechButton').onclick = toggleSpeech;
  $('#showFullQuestion').onclick = openFullQuestionEditor;
  $('#useFullQuestion').onclick = () => { $('#questionInput').value = $('#fullQuestionInput').value; closeDialog('questionEditorDialog'); $('#questionInput').focus(); };
  $('#sendFullQuestion').onclick = () => { $('#questionInput').value = $('#fullQuestionInput').value; closeDialog('questionEditorDialog'); sendQuestion(); };
  $('#selectAllChats').onchange = event => $$('#chatMessages input[type=checkbox]').forEach(input => input.checked = event.target.checked);
  $('#deleteChats').onclick = deleteSelectedChats;
  $('#addChatsToNotes').onclick = addSelectedChatsToNotes;
  $('#showUsage').onclick = showUsage;
  $('#openSettings').onclick = () => { switchSettingsTab('api'); openDialog('settingsDialog'); };
  $$('[data-settings-tab]').forEach(button => button.onclick = () => switchSettingsTab(button.dataset.settingsTab));
  $$('[data-connection-mode]').forEach(button => button.onclick = () => setConnectionMode(button.dataset.connectionMode));
  $('#parseConnection').onclick = () => parseConnectionJSON(false);
  $('#connectionJSON').oninput = () => parseConnectionJSON(true);
  $('#validateAPI').onclick = validateAPI;
  $('#chooseVault').onclick = chooseVault;
  $('#notesChooseVault').onclick = async () => { await chooseVault(); renderNotesSummary(); };
  $('#notesCreateNotebook').onclick = async () => { await createNotebook(); renderNotesSummary(); };
  $('#notesAddOutline').onclick = async () => { await addOutlineToNotebook(); renderNotesSummary(); };
  $('#notesOpenNotebook').onclick = openNotebook;
  $('#notesOpenSettings').onclick = () => { closeDialog('notesDialog'); switchSettingsTab('obsidian'); openDialog('settingsDialog'); };
  $('#notesSelectPendingMarks').onclick = selectPendingMarks;
  $('#notesAddMarks').onclick = async () => { await addSelectedMarksToNotes(); renderNotesSummary(); };
  $('#notesSelectPendingChats').onclick = selectPendingChats;
  $('#notesDeleteChats').onclick = () => { deleteSelectedChats(); renderNotesSummary(); };
  $('#notesAddChats').onclick = async () => { await addSelectedChatsToNotes(); renderNotesSummary(); };
  $('#modelSelector').onchange = () => { settings.model = $('#modelSelector').value; saveSettingsFromUI(); };
  $('#depthSelector').onchange = () => { settings.depth = $('#depthSelector').value; saveSettingsFromUI(); };
  $$('[data-close-dialog]').forEach(button => button.onclick = () => closeDialog(button.dataset.closeDialog));
  $('#bookshelfDialog').addEventListener('cancel', event => { event.preventDefault(); closeDialog('bookshelfDialog'); });
  $('#summaryDialog').addEventListener('cancel', event => { event.preventDefault(); closeDialog('summaryDialog'); });
  $('#notesDialog').addEventListener('cancel', event => { event.preventDefault(); closeDialog('notesDialog'); });
  $('#settingsDialog').addEventListener('cancel', event => { event.preventDefault(); closeDialog('settingsDialog'); });
  $('#questionEditorDialog').addEventListener('cancel', event => { event.preventDefault(); closeDialog('questionEditorDialog'); });
  document.body.addEventListener('dragover', event => event.preventDefault());
  document.body.addEventListener('drop', async event => {
    event.preventDefault();
    const file = event.dataTransfer.files?.[0];
    const path = file?.path;
    if (path?.toLowerCase().endsWith('.pdf')) await openOrNew(path);
  });
}

function applyEdition() {
  $('#apiCompatibility').innerHTML = `支持 OpenAI、Anthropic Claude API、Google Gemini、DeepSeek、OpenRouter、AIHubMix，以及实现 OpenAI Chat Completions/Models 接口的独立中转站。<br>输入 Key 与 Base URL 后应用会读取该站可用模型；不保证兼容仅提供网页调用、私有签名协议、强制 IP 白名单或只实现非标准接口的平台。`;
}

async function openOrNew(path) {
  if (!state.sourcePath) return openDocument(path);
  await api.openProject(path, state.sourcePath);
}

async function openDocument(sourcePath) {
  try {
    setStatus('正在打开 PDF…');
    state.sourcePath = sourcePath;
    state.nativeOutline = [];
    state.nativeOutlineChecked = false;
    state.manualTOCPageIndices = [];
    setOutlineToolsVisible(false);
    state.thumbnailGeneration += 1;
    $('#thumbnailList').replaceChildren();
    state.title = sourcePath.split(/[\\/]/).pop().replace(/\.pdf$/i, '');
    const [saved, stat, bytes] = await Promise.all([api.loadProject(sourcePath), api.fileStat(sourcePath), api.readPDF(sourcePath)]);
    Object.assign(state, cleanSavedState(saved));
    state.sourcePath = sourcePath;
    state.title ||= sourcePath.split(/[\\/]/).pop().replace(/\.pdf$/i, '');
    state.fingerprint = `${stat.size}|${Math.round(stat.modifiedAt)}`;
    $('#emptyState').classList.add('hidden');
    $('#viewerContainer').classList.remove('hidden');
    const loaded = await pdf.load(bytes);
    state.nativeOutline = loaded.outline || [];
    state.nativeOutlineChecked = true;
    $('#pageCount').textContent = loaded.pageCount;
    if (!state.outline.length && state.nativeOutline.length) state.outline = state.nativeOutline;
    pdf.goToPage(state.lastPageIndex || 0);
    pdf.setMarks(state.highlights);
    renderAll();
    const derived = await api.loadDerived(sourcePath);
    const valid = derived?.version === 10 && derived.fingerprint === state.fingerprint;
    if (valid) {
      state.pages = derived.pages || [];
      pdf.setOCRPages(state.pages);
      state.chunks = derived.chunks || makeChunks(state.pages, state.outline);
      setIndexStatus('全文索引已就绪 · 缓存');
    } else {
      state.pages = await pdf.extractPages();
      state.chunks = makeChunks(state.pages, state.outline);
      await saveDerived();
      setIndexStatus('全文索引已就绪');
    }
    if (!state.outline.length && state.nativeOutline.length) state.outline = state.nativeOutline;
    updateOutlineStatus();
    renderAll();
    await persist();
  } catch (error) { showError(error); }
}

function cleanSavedState(saved) {
  if (!saved) return {
    outline: [], bookmarks: [], highlights: [], apiChats: [], summaries: {}, answerCache: {}, exportedMarkIDs: [], exportedChatIDs: [], lastPageIndex: 0, notePath: null
  };
  return {
    ...saved,
    apiChats: saved.apiChats || saved.chats || [],
    highlights: saved.highlights || [], bookmarks: saved.bookmarks || [], outline: saved.outline || [], summaries: saved.summaries || {}, answerCache: saved.answerCache || {}, exportedMarkIDs: saved.exportedMarkIDs || [], exportedChatIDs: saved.exportedChatIDs || []
  };
}

async function persist() {
  if (!state.sourcePath) return;
  const snapshot = {
    documentTitle: state.title, lastPageIndex: state.lastPageIndex, bookmarks: state.bookmarks, highlights: state.highlights,
    apiChats: state.apiChats, outline: state.outline, summaries: state.summaries,
    answerCache: state.answerCache, exportedMarkIDs: state.exportedMarkIDs, exportedChatIDs: state.exportedChatIDs, notePath: state.notePath
  };
  await api.saveProject(state.sourcePath, snapshot);
}

let persistTimer;
function persistSoon() { clearTimeout(persistTimer); persistTimer = setTimeout(() => persist().catch(console.error), 350); }

async function saveDerived() {
  if (!state.sourcePath) return;
  await api.saveDerived(state.sourcePath, { version: 10, fingerprint: state.fingerprint, pages: state.pages, chunks: state.chunks, markdown: renderDocumentMarkdown(state.title, state.pages, state.outline) });
}

function renderAll() {
  renderOutline(); renderBookmarks(); renderHighlights(); renderChats(); updateBookmarkButton(); updateOutlineStatus();
}

let thumbnailObserver;
function renderThumbnails() {
  const root = $('#thumbnailList');
  if (!pdf.pdfDocument || root.childElementCount === pdf.pageCount) return;
  const generation = ++state.thumbnailGeneration;
  thumbnailObserver?.disconnect();
  root.replaceChildren();
  thumbnailObserver = new IntersectionObserver(entries => {
    for (const entry of entries) {
      if (!entry.isIntersecting || generation !== state.thumbnailGeneration) continue;
      const button = entry.target;
      thumbnailObserver.unobserve(button);
      pdf.renderThumbnail(Number(button.dataset.pageIndex), button.querySelector('canvas'), 92)
        .catch(error => console.warn('thumbnail failed', error));
    }
  }, { root, rootMargin: '180px 0px' });
  for (let pageIndex = 0; pageIndex < pdf.pageCount; pageIndex += 1) {
    const button = document.createElement('button');
    button.className = 'thumbnail-row';
    button.dataset.pageIndex = pageIndex;
    button.innerHTML = `<span class="thumbnail-paper"><canvas></canvas></span><span>第 ${pageIndex + 1} 页</span>`;
    button.onclick = () => pdf.goToPage(pageIndex);
    root.append(button);
    thumbnailObserver.observe(button);
  }
  updateCurrentThumbnail();
}

function updateCurrentThumbnail() {
  $$('.thumbnail-row').forEach(button => button.classList.toggle('current', Number(button.dataset.pageIndex) === pdf.currentPage));
}

async function recognizeOutline() {
  if (!state.pages.length) return showError('请等待全文索引完成。');
  $('#recognizeOutline').disabled = true;
  $('#outlineStatus').textContent = '正在识别…';
  try {
    const embedded = await pdf.readEmbeddedOutline();
    if (embedded.length) {
      state.nativeOutline = embedded;
      state.nativeOutlineChecked = true;
      state.outline = embedded;
      $('#outlineStatus').textContent = `PDF 目录 · ${embedded.length} 条`;
    } else {
      const scanLimit = Math.min(state.pages.length, Math.max(36, Math.ceil(state.pages.length * .25)));
      let working = state.pages.slice(0, scanLimit);
      let indices = detectTOCPages(working);
      if (!indices.length) {
        const refreshed = [];
        for (let index = 0; index < Math.min(scanLimit, 80); index += 1) {
          $('#outlineStatus').textContent = `定位目录 ${index + 1}/${Math.min(scanLimit, 80)}`;
          refreshed.push(await pdf.forceOCRPage(index, true));
          if (index >= 5) {
            const found = detectTOCPages(refreshed);
            if (found.length && index > found.at(-1) + 2) break;
          }
        }
        const map = new Map(working.map(page => [page.pageIndex, page]));
        refreshed.forEach(page => map.set(page.pageIndex, page));
        working = [...map.values()].sort((a, b) => a.pageIndex - b.pageIndex);
        indices = detectTOCPages(working);
      }
      if (!indices.length) throw new Error('未定位到可信目录页，请使用“手动添加”。');
      const tocText = buildTOCText(working, indices);
      const entries = parseAutomaticTOC(tocText);
      if (!entries.length) throw new Error('目录页已找到，但没有解析出有效条目。');
      state.outline = resolveTOCPages(inferHierarchy(entries), indices, state.pages).map(entry => ({ ...entry, id: crypto.randomUUID(), source: 'automatic' }));
      $('#outlineStatus').textContent = `${state.outline.length} 条`;
    }
    state.summaries = {};
    state.chunks = makeChunks(state.pages, state.outline);
    await saveDerived(); await persist(); renderOutline(); updateOutlineStatus();
    setStatus('目录识别完成');
  } catch (error) { showError(error); $('#outlineStatus').textContent = '识别失败'; }
  finally { $('#recognizeOutline').disabled = false; }
}

function setOutlineToolsVisible(visible) {
  $('#outlineTools')?.classList.toggle('hidden', !visible);
  $('#toggleOutlineTools')?.setAttribute('aria-expanded', String(visible));
  const chevron = $('.outline-tools-chevron');
  if (chevron) chevron.textContent = visible ? '▾' : '▸';
}

function updateOutlineStatus() {
  const restore = $('#restoreEmbeddedOutline');
  if (restore) {
    restore.disabled = !state.nativeOutline.length;
    restore.title = state.nativeOutline.length ? `恢复 PDF 自带的 ${state.nativeOutline.length} 条目录` : 'PDF 无自带目录';
  }
  if (!state.nativeOutlineChecked) {
    $('#outlineStatus').textContent = state.sourcePath ? '正在识别 PDF 自带目录…' : '等待文档';
    return;
  }
  if (!state.nativeOutline.length) {
    $('#outlineStatus').textContent = state.outline.length ? `PDF 无自带目录 · 当前 ${state.outline.length} 条` : 'PDF 无自带目录';
    return;
  }
  const usingNative = state.outline.length === state.nativeOutline.length
    && state.outline.every((entry, index) => entry.title === state.nativeOutline[index]?.title && entry.pageIndex === state.nativeOutline[index]?.pageIndex);
  $('#outlineStatus').textContent = usingNative ? `PDF 自带目录 · ${state.nativeOutline.length} 条` : `已识别 PDF 自带目录 · 当前 ${state.outline.length} 条`;
}

async function restoreEmbeddedOutline() {
  if (!state.nativeOutline.length) {
    updateOutlineStatus();
    setStatus('PDF 无自带目录');
    return;
  }
  state.outline = state.nativeOutline.map(entry => ({ ...entry }));
  state.summaries = {};
  state.chunks = makeChunks(state.pages, state.outline);
  await saveDerived();
  await persist();
  renderOutline();
  updateOutlineStatus();
  setStatus('已恢复 PDF 自带目录');
}

function renderOutline() {
  const root = $('#outlineList'); root.replaceChildren();
  if (!state.outline.length) {
    root.innerHTML = `<p class="empty-list">${state.nativeOutlineChecked && !state.nativeOutline.length ? 'PDF 无自带目录' : '尚无目录'}</p>`;
    return;
  }
  state.outline.forEach(entry => {
    const wrapper = document.createElement('div');
    const row = document.createElement('div'); row.className = `outline-row${outlineSummariesVisible ? ' summaries-visible' : ''}`; row.style.paddingLeft = `${8 + entry.level * 17}px`;
    const toggle = document.createElement('button'); toggle.className = 'summary-toggle';
    if (outlineSummariesVisible) {
      toggle.textContent = expandedSummaryIDs.has(entry.id) ? '▾' : '▸';
      toggle.title = expandedSummaryIDs.has(entry.id) ? '收起概要' : '展开概要';
    } else toggle.classList.add('hidden');
    const title = document.createElement('button'); title.className = 'outline-title'; title.textContent = entry.title; title.onclick = () => pdf.goToPage(entry.pageIndex);
    const page = document.createElement('span'); page.className = 'outline-page'; page.textContent = `P${entry.pageIndex + 1}`;
    row.append(toggle, title, page); wrapper.append(row);
    const summaryNode = document.createElement('div'); summaryNode.className = 'outline-summary hidden';
    if (loadingSummaryIDs.has(entry.id)) summaryNode.innerHTML = '<span class="summary-loading">正在梳理论证…</span>';
    else if (state.summaries[entry.id]) summaryNode.innerHTML = renderMarkdown(state.summaries[entry.id]);
    else summaryNode.textContent = '需要连接 AI 才能生成概要';
    if (outlineSummariesVisible && expandedSummaryIDs.has(entry.id)) summaryNode.classList.remove('hidden');
    wrapper.append(summaryNode);
    toggle.onclick = async () => {
      if (expandedSummaryIDs.has(entry.id)) {
        expandedSummaryIDs.delete(entry.id);
        renderOutline();
        return;
      }
      expandedSummaryIDs.add(entry.id);
      if (!state.summaries[entry.id]) loadingSummaryIDs.add(entry.id);
      renderOutline();
      if (!state.summaries[entry.id]) {
        try { await generateSummary(entry); }
        catch (error) { showError(error); }
        finally { loadingSummaryIDs.delete(entry.id); renderOutline(); }
      }
    };
    root.append(wrapper);
  });
}

async function generateSummary(entry) {
  if (!settings.apiKey || !settings.model) return showError('请先连接 API 并选择模型。');
  const index = state.outline.findIndex(item => item.id === entry.id);
  const next = state.outline.slice(index + 1).find(item => item.level <= entry.level);
  const chunks = state.chunks.filter(chunk => chunk.pageIndex >= entry.pageIndex && (!next || chunk.pageIndex < next.pageIndex));
  const context = promptContext(prepareForPrompt(chunks, 6500));
  setStatus('正在生成章节概要…');
  const response = await api.requestAI({ id: crypto.randomUUID(), apiKey: settings.apiKey, baseURL: settings.baseURL || '', model: settings.model, system: '你是章节概要编辑。只根据给定原文输出分层项目符号。必须覆盖：本章提出的问题、核心结论、论证步骤、关键概念及其关系。不要写“章际关系”，除非原文明确讨论。重点词用 **粗体**，承重判断可用 <u>下划线</u>。篇幅紧凑，所有项目必须完整收束。', messages: [{ role: 'user', content: `${entry.title}\n\n${context}` }], maxTokens: 1200, reasoningEffort: 'low' });
  state.summaries[entry.id] = response.text;
  await persist(); setStatus('概要已生成');
}

function openManualOutlinePanel() {
  $('.workspace').classList.remove('assistant-hidden');
  $('#apiAssistant').classList.remove('active');
  $('#manualOutlinePanel').classList.add('active');
  $('#assistantPanelTitle').textContent = '手动添加目录';
  $('#apiSelectors').classList.add('hidden');
  $('#openSettings').classList.add('hidden');
  $('#pasteManualOutline').classList.remove('hidden');
  $('#closeManualOutline').classList.remove('hidden');
  $('#manualParseStatus').textContent = '';
  state.manualTOCPageIndices = detectTOCPages(state.pages);
  state.manualPreview = state.outline.map(entry => ({ ...entry, id: entry.id || crypto.randomUUID(), selected: false }));
  if (!state.manualPreview.length) addManualEntry(false);
  renderManualPreview();
}

function closeManualOutlinePanel() {
  $('#manualOutlinePanel').classList.remove('active');
  $('#apiAssistant').classList.add('active');
  $('#assistantPanelTitle').textContent = 'AI 伴读';
  $('#apiSelectors').classList.remove('hidden');
  $('#openSettings').classList.remove('hidden');
  $('#pasteManualOutline').classList.add('hidden');
  $('#closeManualOutline').classList.add('hidden');
}

async function pasteManualOutline() {
  const text = await api.readClipboard();
  if (!String(text || '').trim()) {
    $('#manualParseStatus').textContent = '剪贴板没有文字';
    return;
  }
  $('#manualOutlineText').value = text;
  await parseManual();
}

async function parseManual() {
  const button = $('#parseManualOutline');
  button.disabled = true;
  const sourceText = $('#manualOutlineText').value;
  const linewise = parseManualTOC(sourceText);
  const parsed = linewise.length ? linewise : inferHierarchy(parseAutomaticTOC(sourceText));
  if (!parsed.length) {
    $('#manualParseStatus').textContent = '未识别到有效条目；请确保每行都有标题和页码';
    button.disabled = false;
    return;
  }
  try {
    const directoryPages = await prepareManualCalibration(parsed);
    state.manualTOCPageIndices = directoryPages;
    state.manualPreview = calibrateManualTOC(parsed, state.pages, directoryPages)
      .map(entry => ({ ...entry, id: crypto.randomUUID(), source: 'manual', selected: false }));
    const directoryStatus = directoryPages.length
      ? `已锁定 PDF 目录页 ${physicalPageDescription(directoryPages)}`
      : '未检测到印刷目录页，已使用正文标题锚点';
    $('#manualParseStatus').textContent = `已识别 ${state.manualPreview.length} 条 · ${directoryStatus} · PDF 跳转页已校准`;
    renderManualPreview();
  } finally {
    button.disabled = false;
  }
}

async function prepareManualCalibration(entries) {
  if (!state.pages.length || !pdf.pdfDocument) return [];
  let directoryPages = detectTOCPages(state.pages);
  if (!directoryPages.length) {
    const scanCount = Math.min(state.pages.length, Math.max(12, Math.min(60, Math.max(Math.ceil(state.pages.length / 5), 1))));
    for (let pageIndex = 0; pageIndex < scanCount; pageIndex += 1) {
      $('#manualParseStatus').textContent = `正在定位印刷目录页 ${pageIndex + 1}/${scanCount}`;
      mergeRefreshedPages([await pdf.forceOCRPage(pageIndex, true)]);
      if (pageIndex >= 5) {
        const found = detectTOCPages(state.pages.slice(0, scanCount));
        if (found.length && pageIndex > found.at(-1) + 2) { directoryPages = found; break; }
      }
    }
    if (!directoryPages.length) directoryPages = detectTOCPages(state.pages.slice(0, scanCount));
  }
  if (directoryPages.length) {
    const refreshedDirectory = [];
    for (let position = 0; position < directoryPages.length; position += 1) {
      $('#manualParseStatus').textContent = `正在重读目录页 ${position + 1}/${directoryPages.length}`;
      refreshedDirectory.push(await pdf.forceOCRPage(directoryPages[position], true));
    }
    mergeRefreshedPages(refreshedDirectory);
    const redetected = detectTOCPages(state.pages);
    if (redetected.length) directoryPages = redetected;
  }
  const calibrationPages = manualCalibrationPageIndices(entries, directoryPages, state.pages);
  const refreshedCalibration = [];
  for (let position = 0; position < calibrationPages.length; position += 1) {
    $('#manualParseStatus').textContent = `正在校准正文标题 ${position + 1}/${calibrationPages.length}`;
    refreshedCalibration.push(await pdf.forceOCRPage(calibrationPages[position], true));
  }
  mergeRefreshedPages(refreshedCalibration);
  pdf.setOCRPages(state.pages);
  state.chunks = makeChunks(state.pages, state.outline);
  await saveDerived();
  return directoryPages;
}

function mergeRefreshedPages(refreshed = []) {
  if (!refreshed.length) return;
  const byPage = new Map(state.pages.map(page => [page.pageIndex, page]));
  refreshed.forEach(page => {
    const previous = byPage.get(page.pageIndex) || {};
    byPage.set(page.pageIndex, { ...previous, ...page, pageLabel: page.pageLabel ?? previous.pageLabel ?? null });
  });
  state.pages = [...byPage.values()].sort((left, right) => left.pageIndex - right.pageIndex);
}

function physicalPageDescription(indices = []) {
  const pages = indices.map(index => index + 1);
  if (!pages.length) return '无';
  if (pages.length === 1) return String(pages[0]);
  const continuous = pages.every((page, index) => index === 0 || page === pages[index - 1] + 1);
  return continuous ? `${pages[0]}–${pages.at(-1)}` : pages.join('、');
}

function renderManualPreview() {
  const root = $('#manualOutlinePreview'); root.replaceChildren();
  state.manualPreview.forEach((entry, index) => {
    const row = document.createElement('div'); row.className = 'manual-preview-row';
    const selected = document.createElement('input');
    selected.type = 'checkbox'; selected.checked = !!entry.selected; selected.setAttribute('aria-label', `选择 ${entry.title || `第 ${index + 1} 条`}`);
    selected.onchange = () => { entry.selected = selected.checked; updateManualSelectionState(); };
    const title = document.createElement('input');
    title.className = 'title'; title.value = entry.title; title.placeholder = '标题';
    title.oninput = () => { entry.title = title.value; $('#applyManualOutline').disabled = state.manualPreview.every(item => !String(item.title || '').trim()); };
    title.onchange = () => { recalibrateManualPreview(); renderManualPreview(); };
    const page = document.createElement('input');
    page.className = 'page'; page.type = 'number'; page.min = 1; page.value = entry.printedPage || entry.pageIndex + 1; page.setAttribute('aria-label', '目录印刷页码'); page.title = '目录中原有的印刷页码；修改后会重新校准实际 PDF 跳转页';
    page.onchange = () => { entry.printedPage = Math.max(1, Number(page.value || 1)); recalibrateManualPreview(); renderManualPreview(); };
    const physical = document.createElement('label'); physical.className = 'manual-physical-page'; physical.textContent = 'PDF';
    const physicalInput = document.createElement('input');
    physicalInput.type = 'number'; physicalInput.min = 1; physicalInput.max = Math.max(pdf.pageCount, 1); physicalInput.value = entry.pageIndex + 1;
    physicalInput.setAttribute('aria-label', '实际 PDF 页'); physicalInput.title = '自动校准后的实际跳转页；可直接修改以覆盖自动结果';
    physicalInput.onchange = () => {
      entry.pageIndex = Math.min(Math.max(Number(physicalInput.value || 1) - 1, 0), Math.max(pdf.pageCount - 1, 0));
      physicalInput.value = entry.pageIndex + 1;
    };
    physical.append(physicalInput);
    const controls = document.createElement('span'); controls.className = 'manual-row-controls';
    const level = document.createElement('span'); level.className = 'manual-level-label'; level.textContent = `第 ${entry.level + 1} 级`;
    const spacer = document.createElement('span'); spacer.className = 'manual-row-spacer';
    controls.append(level);
    const actions = [
      ['←', '提升一级', () => entry.level = Math.max(0, entry.level - 1)],
      ['→', '下沉一级', () => entry.level = Math.min(5, entry.level + 1)],
      ['↑', '上移', () => moveManual(index, -1)],
      ['↓', '下移', () => moveManual(index, 1)],
      ['＋', '在下方插入', () => insertManualEntry(index)],
      ['×', '删除', () => state.manualPreview.splice(index, 1)]
    ];
    actions.forEach(([label, titleText, action], actionIndex) => {
      if (actionIndex === 2) controls.append(spacer);
      const button = document.createElement('button'); button.textContent = label; button.title = titleText;
      button.onclick = () => { action(); renderManualPreview(); };
      controls.append(button);
    });
    row.append(selected, title, page, physical, controls); root.append(row);
  });
  if (!state.manualPreview.length) {
    const empty = document.createElement('div'); empty.className = 'record-empty'; empty.textContent = '尚无目录条目'; root.append(empty);
  }
  updateManualSelectionState();
  $('#applyManualOutline').disabled = state.manualPreview.every(entry => !String(entry.title || '').trim());
}

function updateManualSelectionState() {
  const selectedCount = state.manualPreview.filter(entry => entry.selected).length;
  $('#manualSelectedCount').textContent = `已选 ${selectedCount} 项`;
  $('#selectAllManual').checked = !!state.manualPreview.length && selectedCount === state.manualPreview.length;
  $('#applyManualBatchLevel').disabled = selectedCount === 0;
  $('#shiftManualPages').disabled = selectedCount === 0 || Number($('#manualPageShift').value || 0) === 0;
  $('#deleteManualEntries').disabled = selectedCount === 0;
}

function addManualEntry(render = true) {
  state.manualPreview.push({ id: crypto.randomUUID(), title: '', printedPage: Math.max(pdf.currentPage + 1, 1), pageIndex: Math.max(pdf.currentPage, 0), level: 0, source: 'manual', selected: false });
  if (render) renderManualPreview();
}

function insertManualEntry(index) {
  const previous = state.manualPreview[index];
  state.manualPreview.splice(index + 1, 0, { id: crypto.randomUUID(), title: '', printedPage: previous.printedPage || previous.pageIndex + 1, pageIndex: previous.pageIndex, level: previous.level, source: 'manual', selected: false });
}

function recalibrateManualPreview() {
  const previous = state.manualPreview;
  const calibrated = calibrateManualTOC(previous, state.pages, state.manualTOCPageIndices);
  state.manualPreview = calibrated.map((entry, index) => ({ ...previous[index], ...entry }));
}

function applyManualBatchLevel() {
  const level = Math.min(Math.max(Number($('#manualBatchLevel').value || 0), 0), 5);
  const selected = state.manualPreview.filter(entry => entry.selected);
  selected.forEach(entry => { entry.level = level; });
  $('#manualParseStatus').textContent = `已修改 ${selected.length} 项层级`;
  renderManualPreview();
}

function shiftManualPages() {
  const shift = Number($('#manualPageShift').value || 0);
  const selected = state.manualPreview.filter(entry => entry.selected);
  selected.forEach(entry => { entry.printedPage = Math.max(Number(entry.printedPage || entry.pageIndex + 1) + shift, 1); });
  recalibrateManualPreview();
  $('#manualParseStatus').textContent = `已迁移 ${selected.length} 项页码 ${shift >= 0 ? '+' : ''}${shift}`;
  $('#manualPageShift').value = 0;
  renderManualPreview();
}

function deleteSelectedManualEntries() {
  const count = state.manualPreview.filter(entry => entry.selected).length;
  state.manualPreview = state.manualPreview.filter(entry => !entry.selected);
  $('#manualParseStatus').textContent = `已删除 ${count} 条目录`;
  renderManualPreview();
}

function moveManual(index, delta) {
  const target = index + delta; if (target < 0 || target >= state.manualPreview.length) return;
  [state.manualPreview[index], state.manualPreview[target]] = [state.manualPreview[target], state.manualPreview[index]];
}

async function applyManual() {
  state.outline = state.manualPreview.filter(entry => String(entry.title || '').trim()).map(entry => ({ ...entry, selected: undefined, title: normalizeText(entry.title), pageIndex: Math.max(entry.pageIndex, 0), source: 'manual' }));
  state.summaries = {}; state.chunks = makeChunks(state.pages, state.outline);
  await saveDerived(); await persist(); renderOutline(); updateOutlineStatus(); closeManualOutlinePanel(); setStatus(`手动目录已保存 · ${state.outline.length} 项`);
}

function toggleBookmark() {
  const index = state.bookmarks.findIndex(item => item.pageIndex === pdf.currentPage);
  if (index >= 0) state.bookmarks.splice(index, 1);
  else { state.bookmarks.push({ id: crypto.randomUUID(), pageIndex: pdf.currentPage, name: `P${pdf.currentPage + 1}` }); switchSidebar('bookmarks'); }
  renderBookmarks(); updateBookmarkButton(); persistSoon();
}

function updateBookmarkButton() {
  const active = state.bookmarks.some(item => item.pageIndex === pdf.currentPage);
  $('#toggleBookmark').classList.toggle('active', active);
  $('#toggleBookmark').title = active ? '取消当前页书签' : '添加当前页书签';
}

function renderBookmarks() {
  const root = $('#bookmarkList'); root.replaceChildren();
  state.bookmarks.sort((a, b) => a.pageIndex - b.pageIndex).forEach(bookmark => {
    const row = document.createElement('div'); row.className = 'record-row bookmark-row';
    const icon = document.createElement('button'); icon.className = 'bookmark-jump'; icon.title = '跳到书签'; icon.innerHTML = '<svg class="app-icon"><use href="#icon-bookmark"></use></svg>'; icon.onclick = () => pdf.goToPage(bookmark.pageIndex);
    const input = document.createElement('input'); input.value = bookmark.name; input.onchange = () => { bookmark.name = input.value; persistSoon(); };
    const page = document.createElement('button'); page.textContent = `P${bookmark.pageIndex + 1}`; page.onclick = () => pdf.goToPage(bookmark.pageIndex);
    row.append(icon, input, page); root.append(row);
  });
}

function showSelectionToolbar(event, selection) {
  state.selectedText = selection.text; state.selectedFragments = selection.fragments;
  if (!state.highlights.some(mark => mark.id === state.selectedMarkID)) state.selectedMarkID = null;
  const toolbar = $('#selectionToolbar'); toolbar.classList.remove('hidden');
  const width = toolbar.offsetWidth || 300;
  toolbar.style.left = `${Math.max(8, Math.min(window.innerWidth - width - 8, event.clientX - width / 2))}px`;
  toolbar.style.top = `${Math.max(52, Math.min(window.innerHeight - 55, event.clientY + 12))}px`;
}

function hideSelectionToolbar() {
  $('#selectionToolbar').classList.add('hidden');
  state.selectedText = '';
  state.selectedFragments = [];
  state.selectedMarkID = null;
  pdf.clearSelection();
}

function activeSelection() {
  if (state.selectedText && state.selectedFragments.length) return { text: state.selectedText, fragments: state.selectedFragments };
  return pdf.captureSelection(true);
}

function createMark(record) {
  if (!record.text || !record.fragments?.length) return;
  const created = { id: crypto.randomUUID(), text: normalizeGroupedSelectionText(record.text), fragments: record.fragments, pageIndex: Math.min(...record.fragments.map(item => item.pageIndex)), color: record.color || 'yellow', kind: record.kind || 'highlight', note: record.note || '', createdAt: new Date().toISOString() };
  state.highlights.push(created);
  pdf.setMarks(state.highlights); renderHighlights(); persistSoon(); setStatus(record.kind === 'annotation' ? '批注已添加' : '划线已添加');
  pdf.correctSelectionText(created.fragments, created.text).then(corrected => {
    if (corrected && corrected !== created.text && state.highlights.some(mark => mark.id === created.id)) {
      created.text = corrected; renderHighlights(); persistSoon();
    }
  }).catch(error => console.warn('selection OCR correction failed', error));
}

function beginAnnotation() {
  pendingAnnotation = activeSelection();
  const editor = $('#annotationEditor'); const toolbar = $('#selectionToolbar');
  editor.style.left = toolbar.style.left; editor.style.top = `${parseFloat(toolbar.style.top || 100) + 44}px`; editor.classList.remove('hidden');
  $('#annotationText').value = ''; $('#annotationText').focus(); toolbar.classList.add('hidden');
}

function commitAnnotation() {
  const note = $('#annotationText').value.trim(); if (!pendingAnnotation || !note) return cancelAnnotation();
  const overlapping = state.highlights.filter(mark => mark.kind === 'highlight' && mark.fragments.some(left => pendingAnnotation.fragments.some(right => left.pageIndex === right.pageIndex && rectanglesOverlap(left.rect, right.rect))));
  state.highlights = state.highlights.filter(mark => !overlapping.includes(mark));
  createMark({ ...pendingAnnotation, kind: 'annotation', color: 'green', note }); cancelAnnotation();
}

function cancelAnnotation() { $('#annotationEditor').classList.add('hidden'); pendingAnnotation = null; hideSelectionToolbar(); }
function rectanglesOverlap(a, b) { return a[0] < b[2] && a[2] > b[0] && a[1] < b[3] && a[3] > b[1]; }

function askSelection() {
  const selection = activeSelection(); state.selectedText = selection.text; state.selectedFragments = selection.fragments;
  $('#questionInput').value = selection.text; hideSelectionToolbar(); $('#questionInput').focus();
}

function activateHighlightSearch() {
  if (!normalizeText($('#highlightSearchInput').value)) return;
  highlightSearchActive = true;
  renderHighlights();
  syncPageSearchHighlight();
}

function cancelHighlightSearch() {
  highlightSearchActive = false;
  $('#highlightSearchInput').value = '';
  renderHighlights();
  syncPageSearchHighlight();
}

function toggleHighlightSearch() {
  if (highlightSearchActive) cancelHighlightSearch();
  else activateHighlightSearch();
}

function renderHighlights() {
  const root = $('#highlightList'); root.replaceChildren();
  const query = highlightSearchActive ? normalizeText($('#highlightSearchInput').value) : '';
  const visible = state.highlights
    .filter(mark => highlightFilter === 'all' || mark.color === highlightFilter || (highlightFilter === 'annotation' && mark.kind === 'annotation'))
    .filter(mark => markMatchesQuery(mark, query))
    .sort((left, right) => left.pageIndex - right.pageIndex || String(left.createdAt).localeCompare(String(right.createdAt)));
  $$('[data-filter]').forEach(button => button.classList.toggle('active', button.dataset.filter === highlightFilter));
  const searchButton = $('#runHighlightSearch');
  searchButton.classList.toggle('cancel-search', highlightSearchActive);
  searchButton.title = highlightSearchActive ? '清除划线与批注搜索' : '搜索划线或批注';
  searchButton.setAttribute('aria-label', searchButton.title);
  searchButton.innerHTML = highlightSearchActive ? '<span>取消</span>' : '<svg class="app-icon"><use href="#icon-arrow-circle"></use></svg>';
  $('#highlightSearchCount').textContent = query || highlightFilter !== 'all' ? `${visible.length}/${state.highlights.length}` : `${state.highlights.length} 条`;
  visible.forEach(mark => {
    const row = document.createElement('div'); row.className = 'record-card';
    const checkbox = document.createElement('input'); checkbox.type = 'checkbox'; checkbox.dataset.id = mark.id;
    const content = document.createElement('button'); content.className = 'record-content'; content.onclick = () => pdf.goToPage(mark.pageIndex);
    const meta = document.createElement('span'); meta.className = 'record-meta';
    const dot = document.createElement('span'); dot.className = `mark-color-dot ${mark.kind === 'annotation' ? 'green' : mark.color}`;
    const kind = document.createElement('span'); kind.textContent = mark.kind === 'annotation' ? '批注' : '划线';
    const page = document.createElement('span'); page.textContent = `P${mark.pageIndex + 1}`;
    meta.append(dot, kind, page);
    const text = document.createElement('span'); text.className = 'record-text'; text.innerHTML = query ? highlightHTML(mark.text, query) : escapeHTML(mark.text);
    content.append(meta, text);
    row.append(checkbox, content);
    if (mark.note) { const note = document.createElement('p'); note.className = 'record-note'; note.innerHTML = query ? highlightHTML(mark.note, query) : escapeHTML(mark.note); row.append(note); }
    root.append(row);
  });
  if (!visible.length) {
    const empty = document.createElement('p'); empty.className = 'record-empty';
    empty.textContent = state.highlights.length ? '没有匹配的划线或批注' : '还没有划线或批注';
    root.append(empty);
  }
  return visible;
}

function selectedMarkIDs() { return new Set($$('#highlightList input:checked').map(input => input.dataset.id)); }
function deleteSelectedMarks() { const ids = selectedMarkIDs(); state.highlights = state.highlights.filter(mark => !ids.has(mark.id)); pdf.setMarks(state.highlights); renderHighlights(); persistSoon(); setStatus(`已删除 ${ids.size} 条`); }
function mergeSelectedMarks() {
  const ids = selectedMarkIDs(); const selected = state.highlights.filter(mark => ids.has(mark.id)).sort((a, b) => a.pageIndex - b.pageIndex || a.createdAt.localeCompare(b.createdAt));
  if (selected.length < 2) return showError('请至少选择两条划线或批注。');
  const first = selected[0]; const allAnnotations = selected.every(mark => mark.kind === 'annotation');
  const merged = { ...first, id: crypto.randomUUID(), text: selected.map(mark => `• ${mark.text}`).join('\n'), fragments: selected.flatMap(mark => mark.fragments), kind: allAnnotations ? 'annotation' : 'highlight', color: allAnnotations ? 'green' : first.color, note: selected.map(mark => mark.note).filter(Boolean).join('\n'), pageIndex: Math.min(...selected.map(mark => mark.pageIndex)) };
  state.highlights = state.highlights.filter(mark => !ids.has(mark.id)); state.highlights.push(merged); pdf.setMarks(state.highlights); renderHighlights(); persistSoon(); setStatus('已合并为一条');
}

async function addSelectedMarksToNotes() {
  const ids = selectedMarkIDs(); const pending = state.highlights.filter(mark => ids.has(mark.id) && !state.exportedMarkIDs.includes(mark.id));
  if (!pending.length) return showError('没有尚未加入笔记的选中内容。');
  let markdown = await ensureNotebook();
  for (const mark of pending) markdown = insertUnderChapter(markdown, highlightBlock(mark), chapterForPage(mark.pageIndex, state.outline, mark.text));
  await api.writeTextFile(state.notePath, markdown); state.exportedMarkIDs.push(...pending.map(mark => mark.id)); await persist(); setStatus(`已加入 ${pending.length} 条笔记`);
}

function activateFullSearch() {
  const query = normalizeText($('#searchInput').value); const root = $('#searchResults'); root.replaceChildren();
  if (!query) return cancelFullSearch();
  fullSearchActive = true;
  const results = [];
  for (const page of state.pages) {
    for (const sentence of normalizeText(page.text).split(/(?<=[。！？.!?])\s*/)) if (searchMatchRanges(query, sentence).length) results.push({ pageIndex: page.pageIndex, sentence });
  }
  $('#searchCount').textContent = `${results.length} 条结果`;
  results.slice(0, 500).forEach(result => {
    const button = document.createElement('button'); button.className = 'search-result'; button.innerHTML = highlightHTML(result.sentence, query); button.onclick = () => pdf.goToPage(result.pageIndex); root.append(button);
  });
  renderFullSearchButton();
  syncPageSearchHighlight();
}

function cancelFullSearch() {
  fullSearchActive = false;
  $('#searchInput').value = '';
  $('#searchResults').replaceChildren();
  $('#searchCount').textContent = '';
  renderFullSearchButton();
  syncPageSearchHighlight();
}

function toggleFullSearch() {
  if (fullSearchActive) cancelFullSearch();
  else activateFullSearch();
}

function renderFullSearchButton() {
  const button = $('#runSearch');
  button.classList.toggle('cancel-search', fullSearchActive);
  button.title = fullSearchActive ? '取消全文搜索' : '搜索';
  button.setAttribute('aria-label', button.title);
  button.innerHTML = fullSearchActive ? '<span>取消</span>' : '<svg class="app-icon"><use href="#icon-arrow-circle"></use></svg>';
}

function syncPageSearchHighlight() {
  if ($('#highlightsPanel').classList.contains('active') && highlightSearchActive) {
    const query = normalizeText($('#highlightSearchInput').value);
    const matching = state.highlights.filter(mark => (highlightFilter === 'all' || mark.color === highlightFilter || (highlightFilter === 'annotation' && mark.kind === 'annotation')) && markMatchesQuery(mark, query));
    pdf.find(query, matching.flatMap(mark => mark.fragments || []));
    return;
  }
  if ($('#searchPanel').classList.contains('active') && fullSearchActive) {
    pdf.find(normalizeText($('#searchInput').value));
    return;
  }
  pdf.clearFind();
}

function highlightHTML(text, query) {
  const ranges = searchMatchRanges(query, text);
  if (!ranges.length) return escapeHTML(text);
  let cursor = 0;
  const pieces = [];
  for (const range of ranges) {
    pieces.push(escapeHTML(text.slice(cursor, range.start)));
    pieces.push(`<mark class="search-hit">${escapeHTML(text.slice(range.start, range.end))}</mark>`);
    cursor = range.end;
  }
  pieces.push(escapeHTML(text.slice(cursor)));
  return pieces.join('');
}

function addQuickQuestion(value) {
  const input = $('#questionInput'); const current = input.value.trim(); input.value = current ? `${current}\n\n${value}` : value; state.selectedQuick = value;
}

function contextScope(question) { return /联系上下文/.test(question) ? 'context' : /解释一下/.test(question) ? 'explanation' : 'standard'; }

async function sendQuestion() {
  if (state.currentRequest) return;
  const visibleQuestion = $('#questionInput').value.trim(); if (!visibleQuestion) return;
  if (!settings.apiKey || !settings.model) { openDialog('settingsDialog'); return showError('请先连接 API 并选择模型。'); }
  if (!state.chunks.length) return showError('请等待全文索引完成。');
  const focusPage = state.selectedFragments.length ? Math.min(...state.selectedFragments.map(item => item.pageIndex)) : pdf.currentPage;
  const scope = contextScope(visibleQuestion); const wholeBook = $('#wholeBook').checked; const depth = DEPTHS[$('#depthSelector').value] || DEPTHS.balanced;
  const retrievalQuery = `${state.selectedText}\n${visibleQuestion}`.trim();
  const contextChunks = prepareForPrompt(retrieveForReading(retrievalQuery, focusPage, state.chunks, { limit: depth.contextLimit, wholeBook, scope }), Math.round(depth.budgets[scope] * (wholeBook ? 1.12 : 1)));
  const quoteIsInQuestion = state.selectedText && normalizeText(visibleQuestion).includes(normalizeText(state.selectedText));
  const promptChunks = quoteIsInQuestion
    ? contextChunks.map(chunk => ({ ...chunk, text: chunk.text.replace(normalizeText(state.selectedText), '〔当前划选位置〕') }))
    : contextChunks;
  const context = promptContext(promptChunks);
  const sourceIdentity = state.selectedText ? await api.sha256(`${focusPage}|${state.selectedText}`) : null;
  const history = contextualHistory(sourceIdentity, focusPage, depth.historyLimit);
  const cacheKey = await api.sha256(JSON.stringify({ visibleQuestion, context, model: settings.model, depth: $('#depthSelector').value, history: history.map(turn => turn.content) }));
  const userTurn = { id: crypto.randomUUID(), role: 'user', content: visibleQuestion, pageReferences: [focusPage], noteAnchorPageIndex: focusPage, sourceText: state.selectedText, sourceIdentity, createdAt: new Date().toISOString(), selected: false };
  state.apiChats.push(userTurn); $('#questionInput').value = ''; renderChats();
  if (!wholeBook && state.answerCache[cacheKey]) {
    state.apiChats.push({ ...structuredClone(state.answerCache[cacheKey]), id: crypto.randomUUID(), servedFromLocalCache: true }); renderChats(); persistSoon(); setStatus('已使用本地回答缓存（未调用 API）'); return;
  }
  const requestId = crypto.randomUUID();
  state.currentRequest = { id: requestId, userTurnId: userTurn.id, originalQuestion: visibleQuestion, partial: '', sourceIdentity, focusPage };
  $('#cancelAnswer').classList.remove('hidden'); $('#sendQuestion').disabled = true; setStatus(/链接资源/.test(visibleQuestion) ? 'AI 正在查找资源…' : wholeBook ? 'AI 正在联系全书…' : 'AI 正在阅读相关原文…');
  const placeholder = { id: crypto.randomUUID(), role: 'assistant', content: '', pageReferences: [focusPage], noteAnchorPageIndex: focusPage, sourceIdentity, createdAt: new Date().toISOString(), loading: true };
  state.apiChats.push(placeholder); renderChats();
  try {
    const response = await api.requestAI({ id: requestId, apiKey: settings.apiKey, baseURL: settings.baseURL || '', model: settings.model, system: systemPrompt(depth, wholeBook, /链接资源/.test(visibleQuestion)), messages: [...history.map(turn => ({ role: turn.role, content: turn.content })), { role: 'user', content: `${context ? `<book_context>\n${context}\n</book_context>\n\n` : ''}${visibleQuestion}` }], maxTokens: depth.outputLimit, reasoningEffort: depth.reasoningEffort });
    placeholder.content = response.text || state.currentRequest?.partial || ''; placeholder.loading = false; placeholder.usage = response.usage;
    state.lastUsage = { ...response.usage, retrievedChunks: contextChunks.length, estimatedContextTokens: estimatedTokens(context), wholeBook, scope, model: settings.model, depth: $('#depthSelector').value, localCache: false };
    state.answerCache[cacheKey] = structuredClone(placeholder);
    if (Object.keys(state.answerCache).length > 160) delete state.answerCache[Object.keys(state.answerCache)[0]];
    setStatus(`AI 回答完成 · 输入 ${response.usage?.inputTokens || 0} / 输出 ${response.usage?.outputTokens || 0}`);
  } catch (error) {
    state.apiChats = state.apiChats.filter(turn => turn.id !== placeholder.id);
    if (String(error).includes('aborted') || String(error).includes('取消')) setStatus('已取消 AI 请求'); else showError(error);
  } finally {
    state.currentRequest = null; $('#cancelAnswer').classList.add('hidden'); $('#sendQuestion').disabled = false; state.selectedText = ''; state.selectedFragments = []; renderChats(); await persist();
  }
}

function contextualHistory(sourceIdentity, focusPage, limit) {
  const turns = state.apiChats.filter(turn => !turn.loading).slice(0, -1);
  if (sourceIdentity) {
    const relevant = turns.filter(turn => turn.sourceIdentity === sourceIdentity);
    return relevant.slice(-limit);
  }
  const lastUser = [...turns].reverse().find(turn => turn.role === 'user');
  if (!lastUser || lastUser.noteAnchorPageIndex !== focusPage) return [];
  const start = turns.findLastIndex(turn => turn.role === 'user' && turn.noteAnchorPageIndex !== focusPage);
  return turns.slice(start + 1).slice(-limit);
}

function systemPrompt(depth, wholeBook, resources) {
  const visible = depth === DEPTHS.economical ? '约 448–640 个汉字，最多 3 个短节' : depth === DEPTHS.deep ? '约 1,280–1,920 个汉字，最多 6 个短节' : '约 768–1,152 个汉字，最多 4 个短节';
  return `你是 Reading Companion 的 ljg-read 伴读者。只依据给定原文回答；原文没有支持的推断必须明确标注。先在内部修复会影响理解的 OCR 错字，不要向用户解释修复过程。\n\n先用 1–2 句直接回答，再重建“问题 → 区分 → 论证 → 结论”。区分理论来源、判断对象、分析层级、方法、证据与结论，禁止把亲缘关系误写成上下位关系。联系上下文时说明前文如何引出、本段论证目标、当前动作及如何引向下文。\n\n使用清晰 Markdown：2–4 个自然小标题，并列关系逐点换行；每段不超过 2 句；只加粗真正承重的概念，可用下划线突出关键边界。不要堆成长段。回答后用“### 碰撞”只提出一个能迫使读者选择判断标准的问题；若本轮是资源链接，则只给约 5 个高质量可点击链接卡片，每项一句介绍，不提碰撞问题。\n\n本轮目标篇幅：${visible}。这是生成前规划，不得在生成后裁剪；必须完整收束，不留半句、悬空标题或未完成列表。${wholeBook ? '\n已开启联系全书：可跨章节比较，但仍只引用最相关证据。' : ''}${resources ? '\n资源模式：优先官方页面、馆藏、作者/机构页面和高质量资料，链接必须真实可访问。' : ''}`;
}

function handleAIProgress(payload) {
  if (!state.currentRequest || payload.id !== state.currentRequest.id) return;
  state.currentRequest.partial += payload.delta || '';
  const placeholder = state.apiChats.find(turn => turn.loading);
  if (placeholder) { placeholder.content = state.currentRequest.partial; renderChats(); }
}

async function cancelAnswer() {
  if (!state.currentRequest) return;
  await api.cancelAI(state.currentRequest.id);
  if (!state.currentRequest.partial) {
    state.apiChats = state.apiChats.filter(turn => turn.id !== state.currentRequest.userTurnId && !turn.loading);
    $('#questionInput').value = state.currentRequest.originalQuestion;
    setStatus('已取消发送，问题已恢复');
  }
}

function renderChats() {
  const root = $('#chatMessages'); root.replaceChildren();
  $('#chatEmptyState').classList.toggle('hidden', state.apiChats.length > 0);
  root.classList.toggle('hidden', state.apiChats.length === 0);
  state.apiChats.forEach(turn => {
    const row = document.createElement('div'); row.className = `chat-turn ${turn.role}`; row.id = `chat-${turn.id}`;
    const label = document.createElement('label'); const select = document.createElement('input'); select.type = 'checkbox'; select.dataset.id = turn.id; select.checked = !!turn.selected;
    const bubble = document.createElement('div'); bubble.className = 'chat-bubble'; bubble.innerHTML = turn.role === 'assistant' ? renderMarkdown(turn.content || (turn.loading ? '正在思考…' : '')) : escapeHTML(turn.content).replace(/\n/g, '<br>');
    label.append(select, bubble); row.append(label); root.append(row);
  });
  renderChatOverview(); root.scrollTop = root.scrollHeight;
}

function renderChatOverview() {
  const root = $('#chatOverview'); root.replaceChildren();
  state.apiChats.filter(turn => turn.role === 'user').forEach(turn => {
    const button = document.createElement('button'); button.className = 'overview-dot'; button.dataset.summary = compactQuestion(turn.content); button.onclick = () => document.getElementById(`chat-${turn.id}`)?.scrollIntoView({ behavior: 'smooth', block: 'center' }); root.append(button);
  });
}
function compactQuestion(value) { return normalizeText(value).replace(/[，。！？；：,.!?;:]/g, ' ').split(/\s+/).filter(Boolean).slice(0, 8).join(' · ').slice(0, 48); }
function selectedChatIDs() { return new Set($$('#chatMessages input:checked').map(input => input.dataset.id)); }
function deleteSelectedChats() { const ids = selectedChatIDs(); state.apiChats = state.apiChats.filter(turn => !ids.has(turn.id)); renderChats(); persistSoon(); setStatus(`已删除 ${ids.size} 条对话`); }

async function addSelectedChatsToNotes() {
  const ids = selectedChatIDs(); const selected = state.apiChats.filter(turn => ids.has(turn.id) && !state.exportedChatIDs.includes(turn.id));
  if (!selected.length) return showError('没有尚未加入笔记的选中对话。');
  const mode = document.querySelector('input[name=chatExport]:checked')?.value || 'original'; const collapsed = $('#collapseConversation').checked;
  let block; if (mode === 'condensed') block = aiBlock(selected, { collapsed, condensed: await condenseConversation(selected) }); else block = aiBlock(selected, { collapsed });
  const anchor = selected.find(turn => Number.isInteger(turn.noteAnchorPageIndex))?.noteAnchorPageIndex;
  const source = selected.find(turn => turn.sourceText)?.sourceText || '';
  let markdown = await ensureNotebook(); markdown = insertUnderChapter(markdown, block, chapterForPage(anchor ?? pdf.currentPage, state.outline, source));
  await api.writeTextFile(state.notePath, markdown); state.exportedChatIDs.push(...selected.map(turn => turn.id)); await persist(); setStatus('AI 对话已加入笔记');
}

async function condenseConversation(turns) {
  const transcript = turns.map(turn => `${turn.role === 'user' ? '读者' : '伴读'}：${turn.content}`).join('\n\n');
  const maxTokens = Math.min(12000, Math.max(1200, Math.ceil(estimatedTokens(transcript) * .45)));
  const response = await api.requestAI({ id: crypto.randomUUID(), apiKey: settings.apiKey, baseURL: settings.baseURL || '', model: settings.model, system: '把阅读对话整理为约原文 30% 的完整中文笔记。逐组保留核心问题、直接答案、关键区分、主要证据和结论；删除寒暄、重复与铺垫。使用短标题和项目符号，每条只承担一个逻辑动作。不得补写事实，不得截断句子、列表或 Markdown。', messages: [{ role: 'user', content: transcript }], maxTokens, reasoningEffort: 'low' });
  return response.text;
}

async function toggleSpeech() {
  if (speechActive) {
    await api.stopSpeech();
    speechActive = false;
    $('#speechButton').classList.remove('active');
    $('#speechButton span').textContent = '语音';
    setStatus('语音输入已结束，识别内容已保留');
    $('#questionInput').focus();
    return;
  }
  speechTranscript = $('#questionInput').value;
  const result = await api.startSpeech('zh-CN'); if (!result.started) return showError(result.reason);
  speechActive = true;
  $('#speechButton').classList.add('active');
  $('#speechButton span').textContent = '停止';
  setStatus('正在听写，再次点击结束并保留文字');
}

function handleSpeechResult(result) {
  if (result.error) {
    speechActive = false;
    $('#speechButton').classList.remove('active');
    $('#speechButton span').textContent = '语音';
    return showError(result.error);
  }
  if (!result.text) return;
  speechTranscript = `${speechTranscript}${speechTranscript && !/\s$/.test(speechTranscript) ? ' ' : ''}${result.text}`;
  $('#questionInput').value = speechTranscript;
}

async function showUsage() {
  const usage = state.lastUsage;
  $('#usageContent').innerHTML = usage ? `<div class="usage-grid"><span>模型</span><b>${escapeHTML(usage.model)}</b><span>阅读模式</span><b>${escapeHTML(usage.depth)}</b><span>输入 Token</span><b>${usage.inputTokens || 0}</b><span>输出 Token</span><b>${usage.outputTokens || 0}</b><span>缓存命中</span><b>${usage.cachedTokens || 0}</b><span>推理 Token</span><b>${usage.reasoningTokens || 0}</b><span>检索片段</span><b>${usage.retrievedChunks}</b><span>估算原文 Token</span><b>${usage.estimatedContextTokens}</b><span>范围</span><b>${usage.wholeBook ? '全书' : usage.scope}</b></div>` : '<p>还没有可显示的用量。</p>';
  openDialog('usageDialog');
}

async function createNotebook() { await ensureNotebook(true); setStatus('笔记本已创建'); }
async function addOutlineToNotebook() { const markdown = ensureOutline(await ensureNotebook(), state.outline); await api.writeTextFile(state.notePath, markdown); setStatus('目录已加入笔记'); }
async function ensureNotebook(forceSkeleton = false) {
  if (!state.sourcePath) throw new Error('请先打开 PDF。');
  await saveSettingsFromUI();
  const registeredVault = await api.resolveObsidianVault(settings.vaultPath);
  if (!registeredVault) {
    const registered = await api.listObsidianVaults();
    throw new Error(`当前设置的文件夹不是 Obsidian 已注册的 Vault。请先在 Obsidian 中使用“打开文件夹作为仓库”，再在“设置 > Obsidian”选择它。\n\n已注册 Vault：\n${registered.length ? registered.join('\n') : '没有检测到已注册 Vault'}`);
  }
  settings.vaultPath = registeredVault;
  state.notePath = await api.joinPath(settings.vaultPath, settings.vaultFolder, `${safeFileName(state.title)}.md`);
  const exists = await api.pathExists(state.notePath);
  if (!exists || forceSkeleton) await api.writeTextFile(state.notePath, skeleton(state.title, state.outline));
  else await api.writeTextFile(state.notePath, ensureOutline(await api.readTextFile(state.notePath), state.outline));
  await persist(); return api.readTextFile(state.notePath);
}
async function openNotebook() {
  await ensureNotebook();
  const result = await api.openObsidianNote(settings.vaultPath, state.notePath);
  if (result?.vaultPath && result.vaultPath !== settings.vaultPath) {
    settings.vaultPath = result.vaultPath;
    await api.saveSettings(settings);
  }
  setStatus('已在 Obsidian 打开笔记');
}

function renderNotesSummary() {
  const pendingMarks = state.highlights.filter(mark => !state.exportedMarkIDs.includes(mark.id)).length;
  const pendingChats = state.apiChats.filter(turn => !state.exportedChatIDs.includes(turn.id)).length;
  $('#notesVaultStatus').textContent = settings.vaultPath ? `Vault · ${settings.vaultPath.split(/[\\/]/).filter(Boolean).at(-1)}` : '尚未连接 Vault';
  $('#pendingMarksCount').textContent = `尚未加入 ${pendingMarks} 条`;
  $('#pendingChatsCount').textContent = `尚未加入 ${pendingChats} 条`;
  $('#notesSummary').innerHTML = state.notePath ? `<p class="subtle">当前笔记：${escapeHTML(state.notePath)}</p>` : '';
}

function selectPendingMarks() {
  const pending = new Set(state.highlights.filter(mark => !state.exportedMarkIDs.includes(mark.id)).map(mark => mark.id));
  $$('#highlightList input[type=checkbox]').forEach(input => { input.checked = pending.has(input.dataset.id); });
  switchSidebar('highlights');
  renderNotesSummary();
}

function selectPendingChats() {
  const pending = new Set(state.apiChats.filter(turn => !state.exportedChatIDs.includes(turn.id)).map(turn => turn.id));
  $$('#chatMessages input[type=checkbox]').forEach(input => { input.checked = pending.has(input.dataset.id); });
  renderNotesSummary();
}

async function showBookshelf() {
  const projects = await api.listProjects(); const root = $('#bookshelfList'); root.replaceChildren();
  projects.forEach(project => {
    const row = document.createElement('div'); row.className = 'book-row';
    const icon = document.createElement('span'); icon.textContent = '▤';
    const info = document.createElement('div'); info.innerHTML = `<div class="book-title">${escapeHTML(project.title)}</div><div class="book-path">${escapeHTML(project.sourcePath)}</div>`;
    const open = document.createElement('button'); open.className = 'open-book'; open.textContent = '打开'; open.disabled = !project.available; open.onclick = async () => { closeDialog('bookshelfDialog'); await api.openProject(project.sourcePath, state.sourcePath); };
    const remove = document.createElement('button'); remove.className = 'danger'; remove.textContent = '删除缓存'; remove.onclick = async () => { if (confirm(`彻底重置“${project.title}”？原始 PDF 与 Obsidian 笔记不会删除。`)) { await api.deleteProject(project.sourcePath); await showBookshelf(); } };
    row.append(icon, info, open, remove); root.append(row);
  }); openDialog('bookshelfDialog');
}

function populateSettings() {
  $('#apiKey').value = settings.apiKey || ''; $('#baseURL').value = settings.baseURL || ''; $('#vaultPath').value = settings.vaultPath || ''; $('#vaultFolder').value = settings.vaultFolder || 'Reading Companion'; $('#depthSelector').value = settings.depth || 'balanced';
  setConnectionMode(settings.connectionMode || (settings.baseURL ? 'custom' : 'official'));
  setConnectionStatus(settings.apiKey && settings.model ? '连接成功' : '未连接', !!(settings.apiKey && settings.model));
  populateModels(settings.models || [], settings.model);
}
function populateModels(models, selected) { const selector = $('#modelSelector'); selector.innerHTML = '<option value="">选择模型</option>'; models.forEach(model => selector.add(new Option(model, model, false, model === selected))); }

function switchSettingsTab(name) {
  $$('[data-settings-tab]').forEach(button => button.classList.toggle('active', button.dataset.settingsTab === name));
  $$('[data-settings-panel]').forEach(panel => panel.classList.toggle('active', panel.dataset.settingsPanel === name));
}

function setConnectionMode(mode) {
  const resolved = mode === 'custom' ? 'custom' : 'official';
  settings.connectionMode = resolved;
  $$('[data-connection-mode]').forEach(button => button.classList.toggle('active', button.dataset.connectionMode === resolved));
  $('#customConnectionFields').classList.toggle('hidden', resolved !== 'custom');
  $('#connectionHelp').textContent = resolved === 'custom'
    ? '粘贴连接信息，或填写平台提供的 Base URL 与 API Key。'
    : '支持官方 API Key 及已内置的主流服务商，平台会由 Key 自动识别。';
}

function parseConnectionJSON(quiet = false) {
  const raw = $('#connectionJSON').value.trim();
  if (!raw) return false;
  try {
    const value = JSON.parse(raw);
    const key = value.key || value.apiKey || value.api_key;
    const url = value.url || value.baseURL || value.base_url;
    if (!key || !url) throw new Error('连接信息缺少 Key 或 URL。');
    $('#apiKey').value = key;
    $('#baseURL').value = url;
    setConnectionMode('custom');
    setStatus('已自动填入 API Key 和 Base URL');
    return true;
  } catch (error) {
    if (!quiet) showError(error?.message || '连接信息格式无效。');
    return false;
  }
}

async function validateAPI() {
  setConnectionStatus('正在验证…', false);
  try {
    const connectionMode = settings.connectionMode === 'custom' ? 'custom' : 'official';
    const candidate = { apiKey: $('#apiKey').value.trim(), baseURL: connectionMode === 'custom' ? $('#baseURL').value.trim() : '' };
    if (!candidate.apiKey) throw new Error('请输入 API Key。');
    if (connectionMode === 'custom' && !candidate.baseURL) throw new Error('自定义 API 需要 Base URL。');
    const detection = connectionMode === 'custom'
      ? { models: await api.listModels(candidate), baseURL: candidate.baseURL }
      : await api.detectProvider(candidate.apiKey);
    const models = detection.models || [];
    candidate.baseURL = detection.baseURL || candidate.baseURL;
    if (!models.length) throw new Error('连接成功，但没有读取到可用模型。');
    settings = { ...settings, ...candidate, connectionMode, models, model: models.includes(settings.model) ? settings.model : models[0], depth: $('#depthSelector').value, vaultPath: $('#vaultPath').value.trim(), vaultFolder: $('#vaultFolder').value.trim() || 'Reading Companion' };
    await api.saveSettings(settings); populateModels(models, settings.model); setConnectionStatus(`连接成功 · ${models.length} 个模型`, true); setStatus('API 连接成功'); setTimeout(() => closeDialog('settingsDialog'), 650);
  } catch (error) { setConnectionStatus('连接失败', false); showError(error); }
}

async function saveSettingsFromUI() {
  const connectionMode = settings.connectionMode === 'custom' ? 'custom' : 'official';
  settings = { ...settings, connectionMode, apiKey: $('#apiKey').value.trim() || settings.apiKey, baseURL: connectionMode === 'custom' ? $('#baseURL').value.trim() : (settings.baseURL || ''), model: $('#modelSelector').value || settings.model, depth: $('#depthSelector').value, vaultPath: $('#vaultPath').value.trim() || settings.vaultPath, vaultFolder: $('#vaultFolder').value.trim() || 'Reading Companion' };
  await api.saveSettings(settings);
}

async function chooseVault() {
  const selectedPath = await api.openFolderDialog();
  if (!selectedPath) return;
  const registeredVault = await api.resolveObsidianVault(selectedPath);
  if (!registeredVault) {
    const registered = await api.listObsidianVaults();
    return showError(`所选文件夹不是 Obsidian 已注册的 Vault 根目录。请先在 Obsidian 中使用“打开文件夹作为仓库”，或选择以下 Vault：\n\n${registered.length ? registered.join('\n') : '没有检测到已注册 Vault'}`);
  }
  $('#vaultPath').value = registeredVault;
  settings.vaultPath = registeredVault;
  await saveSettingsFromUI();
  setStatus('Obsidian Vault 已设置');
}

function setConnectionStatus(message, connected) {
  const status = $('#connectionStatus');
  status.classList.toggle('connected', connected);
  status.innerHTML = `<span class="status-dot"></span><span>${escapeHTML(message)}</span>`;
}

function switchSidebar(name) {
  $$('.sidebar-tabs button').forEach(button => button.classList.toggle('active', button.dataset.sidebarTab === name));
  $$('.sidebar-panel').forEach(panel => panel.classList.toggle('active', panel.id === `${name}Panel`));
  if (name !== 'outline') setOutlineToolsVisible(false);
  if (name === 'thumbnails') renderThumbnails();
  syncPageSearchHighlight();
}

function isSelectionNavigationTarget(target) {
  return Boolean(target?.closest?.('#previousPage, #nextPage, #pageField, .thumbnail-row, .outline-title, .bookmark-row button, .record-content, .search-result'));
}

function openFullQuestionEditor() {
  $('#fullQuestionInput').value = $('#questionInput').value;
  openDialog('questionEditorDialog');
  requestAnimationFrame(() => $('#fullQuestionInput').focus());
}

function applySavedLayout() {
  const workspace = $('.workspace');
  workspace.style.setProperty('--left-width', `${Math.max(280, Math.min(560, Number(settings.leftPanelWidth) || 360))}px`);
  workspace.style.setProperty('--right-width', `${Math.max(340, Math.min(680, Number(settings.rightPanelWidth) || 420))}px`);
}

function bindColumnResizers() {
  $$('[data-resizer]').forEach(resizer => {
    resizer.addEventListener('pointerdown', event => {
      event.preventDefault();
      const workspace = $('.workspace');
      const side = resizer.dataset.resizer;
      resizer.setPointerCapture(event.pointerId);
      document.body.classList.add('resizing-columns');
      const move = moveEvent => {
        const bounds = workspace.getBoundingClientRect();
        const width = side === 'left' ? moveEvent.clientX - bounds.left : bounds.right - moveEvent.clientX;
        const clamped = Math.max(side === 'left' ? 280 : 340, Math.min(side === 'left' ? 560 : 680, width));
        workspace.style.setProperty(side === 'left' ? '--left-width' : '--right-width', `${clamped}px`);
      };
      const finish = async finishEvent => {
        resizer.releasePointerCapture(finishEvent.pointerId);
        resizer.removeEventListener('pointermove', move);
        resizer.removeEventListener('pointerup', finish);
        resizer.removeEventListener('pointercancel', finish);
        document.body.classList.remove('resizing-columns');
        const style = getComputedStyle(workspace);
        settings.leftPanelWidth = parseFloat(style.getPropertyValue('--left-width'));
        settings.rightPanelWidth = parseFloat(style.getPropertyValue('--right-width'));
        await api.saveSettings(settings);
      };
      resizer.addEventListener('pointermove', move);
      resizer.addEventListener('pointerup', finish);
      resizer.addEventListener('pointercancel', finish);
    });
  });
}
function updateZoom() { $('#zoomLabel').textContent = `${Math.round(pdf.pdfViewer.currentScale * 100)}%`; $('#fitMode').value = 'custom'; }

function openDialog(id) { document.getElementById(id)?.showModal(); }
function closeDialog(id) { const dialog = document.getElementById(id); if (dialog?.open) dialog.close(); if (id === 'settingsDialog') saveSettingsFromUI().catch(console.error); }
function setStatus(message) { $('#statusMessage').textContent = message; }
function setIndexStatus(message) { $('#indexingStatus').textContent = message; }
function showError(error) { const message = error?.message || String(error); setStatus(message); console.error(error); alert(message); }
function escapeHTML(value = '') { const node = document.createElement('div'); node.textContent = value; return node.innerHTML; }
function renderMarkdown(value = '') {
  const template = document.createElement('template');
  template.innerHTML = marked.parse(value);
  template.content.querySelectorAll('script,style,iframe,object,embed').forEach(node => node.remove());
  template.content.querySelectorAll('*').forEach(node => {
    [...node.attributes].forEach(attribute => {
      if (/^on/i.test(attribute.name) || attribute.name === 'srcdoc') node.removeAttribute(attribute.name);
      if ((attribute.name === 'href' || attribute.name === 'src') && !/^(?:https?:|data:image\/)/i.test(attribute.value)) node.removeAttribute(attribute.name);
    });
  });
  return template.innerHTML;
}
