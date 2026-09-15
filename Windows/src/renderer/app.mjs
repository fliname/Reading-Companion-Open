import { marked } from './vendor/marked.esm.js';
import { PDFController } from './pdf-controller.mjs';
import { DEPTHS, makeChunks, normalizeText, prepareForPrompt, promptContext, renderMarkdown as renderDocumentMarkdown, retrieveForReading, estimatedTokens, searchMatchRanges } from '../shared/retrieval.mjs';
import { calibrateManualTOC, detectTOCPages, inferHierarchy, manualCalibrationPageIndices, parseAutomaticTOC, parseManualTOC } from '../shared/toc.mjs';
import { recognizeAutomaticOutline } from '../shared/auto-toc.mjs';
import { aiBlock, chapterForPage, ensureOutline, highlightBlock, insertUnderChapter, safeFileName, skeleton } from '../shared/notes.mjs';
import { markMatchesQuery } from '../shared/mark-search.mjs';
import { normalizeGroupedSelectionText } from '../shared/selection-group.mjs';
import { ReflowReader } from './reflow-reader.mjs';
import { LibraryView } from './library-view.mjs';
import { BookCoverRenderer } from './book-cover.mjs';
import { CharacterManager } from '../shared/characters.mjs';

const $ = selector => document.querySelector(selector);
const $$ = selector => [...document.querySelectorAll(selector)];
const api = window.readingCompanion;

const REFLOW_EXTENSIONS = /\.(epub|azw3|mobi)$/i;
function isReflowPath(sourcePath) { return REFLOW_EXTENSIONS.test(String(sourcePath || '')); }
function fileBaseName(sourcePath) { return String(sourcePath || '').split(/[\\/]/).pop().replace(/\.[^.]+$/, ''); }

const state = {
  sourcePath: null,
  documentReady: false,
  layoutLocked: false,
  reflowReadingPosition: null,
  reflowLayoutRevision: -1,
  outlineReferences: {},
  summaryDraft: null,
  title: '',
  fingerprint: '',
  bookKind: 'pdf',
  bookCategory: null,
  reflowBook: null,
  reflowReader: null,
  reflowScale: 1,
  reflowSpreadCount: 1,
  reflowPageNumber: 1,
  reflowPageCount: 0,
  reflowSelection: null,
  pageRangeSummaries: [],
  characters: new CharacterManager(),
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
  ljgReadSkillEnabled: true,
  currentRequest: null,
  lastUsage: null,
  manualPreview: [],
  manualTOCPageIndices: [],
  notePath: null,
  thumbnailGeneration: 0
};

let libraryView = null;
let pendingCategoryChoice = null;
const expandedCharacterIDs = new Set();
const characterNavigationIndices = new Map();
let characterDraft = null;

let settings = {};
let settingsSaveChain = Promise.resolve();
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
    if (!state.documentReady || state.bookKind !== 'pdf') return;
    state.lastPageIndex = pageIndex;
    $('#pageField').value = pageIndex + 1;
    updatePageControls();
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
  api.onProjectFlush?.(async () => {
    clearTimeout(persistTimer);
    try { await persist(); } catch (error) { console.error('Unable to flush reading progress', error); }
    finally { api.projectFlushed(); }
  });
  api.onOpenProjectInPlace(openDocument);
  api.onMenuOpenPDF(async () => { const path = await api.openBookDialog(); if (path) await openOrNew(path); });
  api.onAIProgress(handleAIProgress);
  api.onOCRProgress(progress => {
    if (progress.status) setIndexStatus(`OCR · ${Math.round((progress.progress || 0) * 100)}%`);
  });
  api.onBookImportProgress(progress => {
    if (progress?.message) setStatus(progress.message);
    if (Number.isFinite(progress?.progress)) setIndexStatus(`电子书 · ${Math.round(progress.progress * 100)}%`);
  });
  api.onSpeech(handleSpeechResult);
  api.onUpdateProgress(progress => setStatus(progress.message || '正在更新…'));
  const initial = await api.getInitialProject();
  if (initial) await openDocument(initial);
}

function bindUI() {
  $('#openPDF').onclick = $('#emptyOpenPDF').onclick = async () => { const path = await api.openBookDialog(); if (path) await openOrNew(path); };
  $('#openBookshelf').onclick = showBookshelf;
  $('#toggleSidebar').onclick = () => { if (!state.layoutLocked) $('.workspace').classList.toggle('sidebar-hidden'); };
  $('#toggleAssistant').onclick = () => { if (!state.layoutLocked) $('.workspace').classList.toggle('assistant-hidden'); };
  bindColumnResizers();
  $('#fitMode').onchange = event => { if (state.bookKind !== 'reflow' && event.target.value !== 'custom') pdf.setScale(event.target.value); };
  $('#zoomOut').onclick = () => { adjustZoom(-0.1); };
  $('#zoomIn').onclick = () => { adjustZoom(0.1); };
  $('#reflowSpread').onclick = () => {
    if (state.layoutLocked) return;
    if (state.bookKind === 'reflow') {
      state.reflowSpreadCount = state.reflowSpreadCount === 2 ? 1 : 2;
      state.reflowReader?.setSpreadCount(state.reflowSpreadCount);
    } else pdf.setSpreadCount(pdf.spreadCount === 2 ? 1 : 2);
    applyBookKindChrome(); updatePageControls(); persistSoon();
  };
  $('#rotatePage').onclick = () => { if (state.bookKind !== 'reflow') pdf.rotate(); };
  $('#lockScroll').onclick = () => {
    setLayoutLocked(!state.layoutLocked);
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
  $('#previousPage').onclick = () => { if (state.bookKind === 'reflow') state.reflowReader?.turn(-1); else pdf.previousPage(); };
  $('#nextPage').onclick = () => { if (state.bookKind === 'reflow') state.reflowReader?.turn(1); else pdf.nextPage(); };
  $('#pageField').onchange = event => {
    const target = Math.max(0, Number(event.target.value || 1) - 1);
    if (state.bookKind === 'reflow') state.reflowReader?.goToPage(target);
    else pdf.goToPage(target);
  };
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
  $('#cancelManualOutline').onclick = closeManualOutlinePanel;
  $('#addManualEntry').onclick = addManualEntry;
  $('#selectAllManual').onchange = event => { state.manualPreview.forEach(entry => entry.selected = event.target.checked); renderManualPreview(); };
  $('#manualBatchLevel').onchange = applyManualBatchLevel;
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
    if (existing) { existing.color = button.dataset.selectionHighlight; existing.kind = 'highlight'; existing.note = ''; syncMarksToView(); renderHighlights(); persistSoon(); }
    else if (selection) createMark({ ...selection, color: button.dataset.selectionHighlight, kind: 'highlight' });
    hideSelectionToolbar();
  });
  $('#annotateSelection').onclick = beginAnnotation;
  $('#askSelection').onclick = askSelection;
  $('#copySelection').onclick = async () => { await api.writeClipboard(activeSelection().text); hideSelectionToolbar(); setStatus('已复制'); };
  $('#sendAnnotation').onclick = commitAnnotation;
  $('#annotationText').onkeydown = event => {
    if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); commitAnnotation(); }
  };
  $('#addCharacterBatch').onclick = addCharacterBatch;
  $('#addSingleCharacter').onclick = addSingleCharacter;
  $('#manageCharacters').onclick = openCharacterManagement;
  $('#saveCharacters').onclick = closeCharacterManagement;
  $('#characterBatchInput').onkeydown = event => {
    if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) { event.preventDefault(); addCharacterBatch(); }
  };
  $('#characterHighlightsToggle').onchange = event => {
    (characterDraft || state.characters).setHighlightsEnabled(event.target.checked);
    if (!characterDraft) { syncDocumentCharacters(); persistSoon(); }
  };
  document.addEventListener('pointerdown', event => {
    if (!$('#annotationEditor').classList.contains('hidden') && !$('#annotationEditor').contains(event.target) && event.target !== $('#annotateSelection')) cancelAnnotation();
    const toolbar = $('#selectionToolbar');
    if (!toolbar.classList.contains('hidden') && !toolbar.contains(event.target) && !event.ctrlKey && !event.metaKey && !isSelectionNavigationTarget(event.target)) hideSelectionToolbar();
  });
  $$('[data-quick-question]').forEach(button => button.onclick = () => addQuickQuestion(button.dataset.quickQuestion));
  $('#ljgReadSkill').onchange = event => {
    state.ljgReadSkillEnabled = event.target.checked;
    persistSoon();
  };
  $('#sendQuestion').onclick = sendQuestion;
  $('#cancelAnswer').onclick = cancelAnswer;
  $('#questionInput').onkeydown = event => {
    if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) { event.preventDefault(); sendQuestion(); }
  };
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape') closeAISelectorMenus();
    if (event.key === 'Enter' && document.activeElement !== $('#questionInput') && state.selectedText && !state.currentRequest) sendQuestion();
    if (state.bookKind === 'reflow' && state.documentReady &&
        !event.ctrlKey && !event.metaKey && !event.altKey &&
        !event.target?.matches('textarea,input,select,[contenteditable=true]')) {
      if (event.key === 'ArrowDown' || event.key === 'ArrowRight') {
        event.preventDefault(); state.reflowReader?.turn(1);
      } else if (event.key === 'ArrowUp' || event.key === 'ArrowLeft') {
        event.preventDefault(); state.reflowReader?.turn(-1);
      }
    }
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
  $('#addChatsToNotes').onclick = openChatNoteExportDialog;
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
  $('#notesAddChats').onclick = async () => {
    try {
      if (await addSelectedChatsToNotes()) renderNotesSummary();
    } catch (error) { showError(error); }
  };
  $('#confirmChatNoteExport').onclick = confirmChatNoteExport;
  $('#modelMenuButton').onclick = () => toggleAISelectorMenu('model');
  $('#depthMenuButton').onclick = () => toggleAISelectorMenu('depth');
  $('#modelSelector').onchange = () => selectAIModel($('#modelSelector').value);
  $('#depthSelector').onchange = () => selectReadingDepth($('#depthSelector').value);
  document.addEventListener('pointerdown', event => { if (!event.target.closest?.('.ai-selector-control')) closeAISelectorMenus(); });
  $$('[data-close-dialog]').forEach(button => button.onclick = () => closeDialog(button.dataset.closeDialog));
  $('#bookshelfDialog').addEventListener('cancel', event => { event.preventDefault(); closeDialog('bookshelfDialog'); });
  $('#summaryDialog').addEventListener('cancel', event => { event.preventDefault(); closeDialog('summaryDialog'); });
  $('#notesDialog').addEventListener('cancel', event => { event.preventDefault(); closeDialog('notesDialog'); });
  $('#chatNoteExportDialog').addEventListener('cancel', event => { event.preventDefault(); closeDialog('chatNoteExportDialog'); });
  $('#settingsDialog').addEventListener('cancel', event => { event.preventDefault(); closeDialog('settingsDialog'); });
  $('#questionEditorDialog').addEventListener('cancel', event => { event.preventDefault(); closeDialog('questionEditorDialog'); });
  $$('[data-book-category]').forEach(button => button.onclick = () => finishCategoryChoice(button.dataset.bookCategory));
  $('#cancelImportCategory').onclick = () => finishCategoryChoice(null);
  $('#importCategoryDialog').addEventListener('cancel', event => { event.preventDefault(); finishCategoryChoice(null); });
  let dragDepth = 0;
  document.body.addEventListener('dragenter', event => {
    if (![...event.dataTransfer.types].includes('Files')) return;
    event.preventDefault();
    dragDepth += 1;
    document.body.classList.add('pdf-drop-target');
  });
  document.body.addEventListener('dragover', event => {
    if (![...event.dataTransfer.types].includes('Files')) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = 'copy';
  });
  document.body.addEventListener('dragleave', event => {
    if (![...event.dataTransfer.types].includes('Files')) return;
    dragDepth = Math.max(0, dragDepth - 1);
    if (!dragDepth) document.body.classList.remove('pdf-drop-target');
  });
  document.body.addEventListener('drop', async event => {
    event.preventDefault();
    dragDepth = 0;
    document.body.classList.remove('pdf-drop-target');
    const file = [...(event.dataTransfer.files || [])].find(candidate => /\.(pdf|epub|azw3|mobi)$/i.test(candidate.name));
    if (!file) return showError('请拖入 PDF、EPUB、AZW3 或 MOBI 文件。');
    const path = api.droppedFilePath(file);
    if (!path) return showError('无法读取拖入文件的路径，请使用“打开”按钮选择图书。');
    await openOrNew(path);
  });
}

function applyEdition() {
  $('#apiCompatibility').innerHTML = `支持 OpenAI、Anthropic Claude API、Google Gemini、DeepSeek、OpenRouter、AIHubMix，以及实现 OpenAI Chat Completions/Models 接口的独立中转站。<br>输入 Key 与 Base URL 后应用会读取该站可用模型；不保证兼容仅提供网页调用、私有签名协议、强制 IP 白名单或只实现非标准接口的平台。`;
}

async function openOrNew(path) {
  if (!state.sourcePath) return openDocument(path);
  await api.openProject(path, state.sourcePath);
}

function validBookCategory(value) {
  return value === 'fiction' || value === 'nonfiction';
}

function finishCategoryChoice(category) {
  const resolve = pendingCategoryChoice;
  pendingCategoryChoice = null;
  closeDialog('importCategoryDialog');
  resolve?.(validBookCategory(category) ? category : null);
}

function chooseBookCategory(sourcePath, savedCategory) {
  if (validBookCategory(savedCategory)) return Promise.resolve(savedCategory);
  $('#importCategoryBookTitle').textContent = fileBaseName(sourcePath);
  openDialog('importCategoryDialog');
  return new Promise(resolve => { pendingCategoryChoice = resolve; });
}

async function openDocument(sourcePath) {
  try {
    await persist();
    clearTimeout(persistTimer);
    if (isReflowPath(sourcePath)) return await openReflowDocument(sourcePath);
    const saved = await api.loadProject(sourcePath);
    const category = await chooseBookCategory(sourcePath, saved?.bookCategory);
    if (!category) return setStatus('已取消导入');
    state.documentReady = false; state.summaryDraft = null; state.outlineReferences = {};
    setLayoutLocked(false);
    setStatus('正在打开 PDF…');
    state.bookKind = 'pdf';
    state.sourcePath = sourcePath;
    state.nativeOutline = [];
    state.nativeOutlineChecked = false;
    state.manualTOCPageIndices = [];
    outlineSummariesVisible = false;
    expandedSummaryIDs.clear();
    expandedCharacterIDs.clear();
    characterNavigationIndices.clear();
    setOutlineToolsVisible(false);
    state.thumbnailGeneration += 1;
    $('#thumbnailList').replaceChildren();
    state.title = fileBaseName(sourcePath);
    const [stat, bytes] = await Promise.all([api.fileStat(sourcePath), api.readPDF(sourcePath)]);
    Object.assign(state, cleanSavedState(saved));
    state.sourcePath = sourcePath;
    state.title ||= fileBaseName(sourcePath);
    state.bookCategory = category;
    state.characters = new CharacterManager().fromJSON(saved?.characters);
    state.pageRangeSummaries = Array.isArray(saved?.pageRangeSummaries) ? saved.pageRangeSummaries : [];
    state.fingerprint = `${stat.size}|${Math.round(stat.modifiedAt)}`;
    $('#emptyState').classList.add('hidden');
    $('#viewerContainer').classList.remove('hidden');
    $('#reflowContainer').classList.add('hidden');
    const restoredPage = Math.max(0, Number(saved?.lastPageIndex) || 0);
    const loaded = await pdf.load(bytes, { initialPageIndex: restoredPage, spreadCount: saved?.pdfSpreadCount || 1 });
    state.lastPageIndex = pdf.currentPage;
    state.documentReady = true;
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

function sectionText(html) {
  const template = document.createElement('template');
  template.innerHTML = String(html || '');
  template.content.querySelectorAll('script,style').forEach(node => node.remove());
  return template.content.textContent.replace(/[ \t\f\v]+/g, ' ').replace(/ *\n */g, '\n').trim();
}

async function openReflowDocument(sourcePath) {
  const saved = await api.loadProject(sourcePath);
  const category = await chooseBookCategory(sourcePath, saved?.bookCategory);
  if (!category) return setStatus('已取消导入');
  state.documentReady = false; state.summaryDraft = null; state.outlineReferences = {}; state.reflowLayoutRevision = -1;
  setLayoutLocked(false);
  setStatus('正在导入图书…');
  state.bookKind = 'reflow';
  state.sourcePath = sourcePath;
  state.nativeOutline = [];
  state.nativeOutlineChecked = true;
  state.manualTOCPageIndices = [];
  outlineSummariesVisible = false;
  expandedSummaryIDs.clear();
  expandedCharacterIDs.clear();
  characterNavigationIndices.clear();
  setOutlineToolsVisible(false);
  state.thumbnailGeneration += 1;
  $('#thumbnailList').replaceChildren();
  const book = await api.importBook(sourcePath);
  state.reflowBook = book;
  state.reflowReadingPosition = saved?.reflowReadingPosition || null;
  state.reflowScale = state.reflowReadingPosition?.scale || saved?.reflowScale || 1;
  state.reflowSpreadCount = state.reflowReadingPosition?.spread || saved?.reflowSpreadCount || 1;
  state.title = book.title || fileBaseName(sourcePath);
  Object.assign(state, cleanSavedState(saved));
  state.sourcePath = sourcePath;
  state.title = book.title || state.title || fileBaseName(sourcePath);
  state.bookCategory = category;
  state.characters = new CharacterManager().fromJSON(saved?.characters);
  state.pageRangeSummaries = Array.isArray(saved?.pageRangeSummaries) ? saved.pageRangeSummaries : [];
  state.documentReady = false;
  state.fingerprint = book.sourceFingerprint || '';
  state.pages = (book.sections || []).map(section => ({
    pageIndex: section.startPageIndex || 0,
    text: sectionText(section.html),
    pageLabel: section.title || null,
    sectionID: section.id
  })).filter(page => page.text);
  state.nativeOutline = (book.navigation || []).map(entry => ({
    id: crypto.randomUUID(),
    title: entry.title,
    pageIndex: entry.location || 0,
    level: entry.level || 0
  }));
  state.outline = state.outline.length ? state.outline : state.nativeOutline.map(entry => ({ ...entry }));
  state.chunks = makeChunks(state.pages, state.outline);

  $('#emptyState').classList.add('hidden');
  $('#viewerContainer').classList.add('hidden');
  $('#reflowContainer').classList.remove('hidden');
  if (!state.reflowReader) {
    state.reflowReader = new ReflowReader($('#reflowViewport'));
    state.reflowReader.onNavigation(payload => {
      if (state.bookKind !== 'reflow') return;
      state.documentReady = true;
      state.reflowReadingPosition = payload.position;
      state.reflowLayoutRevision = payload.layoutRevision;
      state.reflowPageNumber = payload.pageNumber;
      state.reflowPageCount = payload.pageCount;
      state.reflowSpreadCount = payload.spreadCount || 1;
      state.lastPageIndex = Math.max(0, payload.location || 0);
      $('#pageField').value = payload.pageNumber;
      $('#pageCount').textContent = payload.pageCount;
      updatePageControls();
      syncReflowReferences().catch(showError);
      updateBookmarkButton();
      persistSoon();
    });
    state.reflowReader.onSelection(payload => handleReflowSelection(payload));
    state.reflowReader.onMark(payload => handleReflowMark(payload));
  }
  state.reflowReader.loadBook(book);
  state.reflowReader.configure({ scale: state.reflowScale, count: state.reflowSpreadCount,
    position: state.reflowReadingPosition, location: 0,
    legacyPage: state.reflowReadingPosition ? null : Math.max(0, Number(saved?.lastPageIndex) || 0) });
  syncReflowMarks();
  syncReflowCharacters();

  setIndexStatus('全文索引已就绪');
  updateOutlineStatus();
  renderAll();
  renderCharacters();
  await persist();
  saveReflowCover(book).catch(error => console.warn('cover render failed', error));
  setStatus('图书已就绪');
}

async function saveReflowCover(book) {
  if (!book?.coverImageData || !state.sourcePath) return;
  const dataURL = await BookCoverRenderer.toDataURL({ imageData: book.coverImageData, title: book.title });
  await api.saveCover(state.sourcePath, dataURL);
}

function handleReflowSelection(payload) {
  if (!payload) { if (!$('#selectionToolbar').classList.contains('hidden')) hideSelectionToolbar(); return; }
  state.selectedText = payload.text;
  state.selectedFragments = [];
  state.reflowSelection = {
    text: payload.text,
    sectionID: payload.sectionID,
    start: payload.start,
    end: payload.end,
    anchors: payload.anchors,
    location: payload.location
  };
  const bounds = $('#reflowContainer').getBoundingClientRect();
  showSelectionToolbar({
    clientX: bounds.left + payload.x + payload.width / 2,
    clientY: bounds.top + payload.y + payload.height
  }, { text: payload.text, fragments: [] });
}

function handleReflowMark(payload) {
  const mark = state.highlights.find(item => item.id === payload?.id);
  const anchors = mark?.reflowAnchors || (mark?.reflowAnchor ? [mark.reflowAnchor] : []);
  const anchor = anchors[0];
  if (!mark || !anchor) return;
  state.selectedMarkID = mark.id;
  state.selectedText = mark.text;
  state.selectedFragments = [];
  state.reflowSelection = {
    text: mark.text,
    sectionID: anchor.sectionID,
    start: anchor.start ?? anchor.startOffset,
    end: anchor.end ?? anchor.endOffset,
    anchors,
    location: mark.pageIndex
  };
  const bounds = $('#reflowContainer').getBoundingClientRect();
  showSelectionToolbar({
    clientX: bounds.left + payload.x + payload.width / 2,
    clientY: bounds.top + payload.y + payload.height
  }, { text: mark.text, fragments: [] });
}

function cleanSavedState(saved) {
  if (!saved) return {
    outline: [], bookmarks: [], highlights: [], apiChats: [], summaries: {}, answerCache: {}, exportedMarkIDs: [], exportedChatIDs: [], lastPageIndex: 0, notePath: null, ljgReadSkillEnabled: true
  };
  return {
    ...saved,
    ljgReadSkillEnabled: saved.ljgReadSkillEnabled !== false,
    apiChats: saved.apiChats || saved.chats || [],
    highlights: saved.highlights || [], bookmarks: saved.bookmarks || [], outline: saved.outline || [], summaries: saved.summaries || {}, answerCache: saved.answerCache || {}, exportedMarkIDs: saved.exportedMarkIDs || [], exportedChatIDs: saved.exportedChatIDs || []
  };
}

function reflowSectionIndex(sectionID) {
  return (state.reflowBook?.sections || []).findIndex(section => section.id === sectionID);
}

function reflowMarks() {
  return state.highlights
    .flatMap(mark => (mark.reflowAnchors || (mark.reflowAnchor ? [mark.reflowAnchor] : [])).map(anchor => ({
      id: mark.id,
      sectionID: anchor.sectionID,
      start: anchor.start ?? anchor.startOffset,
      end: anchor.end ?? anchor.endOffset,
      kind: mark.kind === 'annotation' ? 'annotation' : 'highlight',
      tint: mark.color === 'red' ? '红色' : mark.color === 'blue' ? '蓝色' : '黄色'
    })));
}

function syncReflowMarks() {
  state.reflowReader?.applyMarks(reflowMarks());
}

function syncReflowCharacters() {
  if (!state.reflowReader) return;
  const enabled = state.characters.highlightsEnabled !== false && state.bookCategory === 'fiction';
  state.reflowReader.applyCharacters(enabled ? state.characters.characters.map(character => ({
    id: character.id,
    names: character.allNames,
    color: character.cssColorFor(false)
  })) : []);
}

function syncDocumentCharacters() {
  syncReflowCharacters();
  const enabled = state.characters.highlightsEnabled !== false && state.bookCategory === 'fiction';
  pdf.setCharacters?.(enabled ? state.characters.characters.map(character => ({
    id: character.id,
    names: character.allNames,
    color: character.cssColorFor(false)
  })) : []);
}

function syncMarksToView() {
  if (state.bookKind === 'reflow') syncReflowMarks();
  else pdf.setMarks(state.highlights);
}

function goToReadingPage(pageIndex) {
  if (state.bookKind === 'reflow') state.reflowReader?.goToLocation(pageIndex);
  else pdf.goToPage(pageIndex);
}

function currentReadingPage() {
  if (state.bookKind === 'reflow') return Math.max(0, state.reflowPageNumber - 1);
  return pdf.currentPage;
}

function applyBookKindChrome() {
  const reflow = state.bookKind === 'reflow';
  const fiction = state.bookCategory === 'fiction';
  $('#fitMode').classList.toggle('hidden', reflow);
  $('#rotatePage').classList.toggle('hidden', reflow);
  $('#lockScroll').classList.remove('hidden');
  $('#highlightMode').classList.toggle('hidden', reflow);
  $$('.highlight-tool .color-dot[data-highlight-color]').forEach(dot => dot.classList.toggle('hidden', reflow));
  $('#reflowSpread').classList.remove('hidden');
  $('#reflowSpread').classList.toggle('active', (reflow ? state.reflowSpreadCount : pdf.spreadCount) === 2);
  $('[data-sidebar-tab="thumbnails"]')?.classList.toggle('hidden', reflow);
  $('#charactersTabButton')?.classList.toggle('hidden', !fiction);
  $('.depth-selector-control')?.classList.toggle('hidden', fiction);
  $$('.quick-row > button').forEach(button => button.classList.toggle('hidden', fiction));
  $('.skill-switch')?.classList.toggle('hidden', fiction);
  $('#ljgReadSkill').checked = state.ljgReadSkillEnabled !== false;
  if ($('#apiAssistant').classList.contains('active')) {
    const categoryLabel = fiction ? '虚构类' : state.bookCategory === 'nonfiction' ? '非虚构类' : '';
    $('#assistantPanelTitle').textContent = categoryLabel ? `AI 伴读 · ${categoryLabel}` : 'AI 伴读';
  }
  if (fiction) closeAISelectorMenus();
  if (reflow && $('.workspace .sidebar-tabs button.active')?.dataset.sidebarTab === 'thumbnails') switchSidebar('outline');
  if (!fiction && $('.workspace .sidebar-tabs button.active')?.dataset.sidebarTab === 'characters') switchSidebar('outline');
  updateZoom();
}

let projectSaveChain = Promise.resolve();
async function persist() {
  if (!state.sourcePath || !state.documentReady) return;
  const sourcePath = state.sourcePath;
  const snapshot = {
    documentTitle: state.title, lastPageIndex: state.lastPageIndex, bookmarks: state.bookmarks, highlights: state.highlights,
    apiChats: state.apiChats, outline: state.outline, summaries: state.summaries,
    answerCache: state.answerCache, exportedMarkIDs: state.exportedMarkIDs, exportedChatIDs: state.exportedChatIDs, notePath: state.notePath,
    bookCategory: state.bookCategory, characters: state.characters.toJSON(), pageRangeSummaries: state.pageRangeSummaries,
    ljgReadSkillEnabled: state.ljgReadSkillEnabled !== false,
    reflowReadingPosition: state.reflowReadingPosition, reflowScale: state.reflowScale,
    reflowSpreadCount: state.reflowSpreadCount, pdfSpreadCount: pdf.spreadCount
  };
  const value = structuredClone(snapshot);
  projectSaveChain = projectSaveChain.catch(() => {}).then(() => api.saveProject(sourcePath, value));
  await projectSaveChain;
}

let persistTimer;
function persistSoon() { clearTimeout(persistTimer); persistTimer = setTimeout(() => persist().catch(console.error), 350); }

async function saveDerived() {
  if (!state.sourcePath) return;
  await api.saveDerived(state.sourcePath, { version: 10, fingerprint: state.fingerprint, pages: state.pages, chunks: state.chunks, markdown: renderDocumentMarkdown(state.title, state.pages, state.outline) });
}

function renderAll() {
  $('#bookFileTitle').textContent = fileBaseName(state.sourcePath);
  $('#bookFileTitle').title = fileBaseName(state.sourcePath);
  updatePageControls();
  renderOutline(); renderBookmarks(); renderHighlights(); renderChats(); updateBookmarkButton(); updateOutlineStatus(); renderCharacters(); applyBookKindChrome(); syncDocumentCharacters();
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
    const result = await recognizeAutomaticOutline({
      kind: state.bookKind,
      pages: state.pages,
      bookNavigation: state.reflowBook?.navigation || [],
      readNativeOutline: () => pdf.readEmbeddedOutline(),
      refreshPage: pageIndex => pdf.forceOCRPage(pageIndex, true),
      onProgress: progress => { $('#outlineStatus').textContent = progress.message; },
      makeID: () => crypto.randomUUID(),
    });
    mergeRefreshedPages(result.refreshedPages);
    if (result.refreshedPages.length) pdf.setOCRPages(state.pages);
    state.nativeOutline = result.nativeOutline;
    state.nativeOutlineChecked = true;
    state.outline = result.outline;
    $('#outlineStatus').textContent = result.label;
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
  if (state.bookKind === 'reflow') {
    if (restore) { restore.disabled = true; restore.title = '电子书无 PDF 自带目录'; }
    $('#outlineStatus').textContent = state.outline.length ? `图书目录 · ${state.outline.length} 条` : '图书无目录';
    return;
  }
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
  if (state.bookCategory === 'fiction' && outlineSummariesVisible) {
    renderFictionSummaryPanel(root);
    return;
  }
  if (!state.outline.length) {
    root.innerHTML = `<p class="empty-list">${state.bookKind === 'reflow' ? '图书无目录' : state.nativeOutlineChecked && !state.nativeOutline.length ? 'PDF 无自带目录' : '尚无目录'}</p>`;
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
    const title = document.createElement('button'); title.className = 'outline-title'; title.textContent = entry.title; title.onclick = () => {
      const anchor = state.outlineReferences[entry.id]?.anchor;
      if (state.bookKind === 'reflow' && anchor) state.reflowReader.goToAnchor(anchor);
      else goToReadingPage(entry.pageIndex);
    };
    const page = document.createElement('span'); page.className = 'outline-page'; page.textContent = `P${state.outlineReferences[entry.id]?.pageNumber || entry.pageIndex + 1}`; page.dataset.outlineId = entry.id;
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

function setLayoutLocked(value) {
  const workspace = $('.workspace');
  if (value && !state.layoutLocked) workspace.style.setProperty('--locked-columns', getComputedStyle(workspace).gridTemplateColumns);
  state.layoutLocked = Boolean(value);
  workspace.classList.toggle('layout-locked', state.layoutLocked);
  pdf.setLocked(state.layoutLocked && state.bookKind === 'pdf');
  $('#viewerContainer').classList.toggle('locked', pdf.locked);
  $('#lockScroll').classList.toggle('active', state.layoutLocked);
  $('#lockScroll').title = state.layoutLocked ? '解除页面锁定' : '锁定阅读区、左右栏宽度及 PDF 当前裁切范围';
  for (const selector of ['#fitMode', '#zoomOut', '#zoomIn', '#reflowSpread', '#rotatePage', '#toggleSidebar', '#toggleAssistant']) $(selector).disabled = state.layoutLocked;
}

function updatePageControls() {
  const reflow = state.bookKind === 'reflow';
  const current = reflow ? state.reflowPageNumber : pdf.currentPage + 1;
  const count = reflow ? state.reflowPageCount : pdf.pageCount;
  const spread = reflow ? state.reflowSpreadCount : pdf.spreadCount;
  $('#pageField').value = current || 1;
  $('#pageCount').textContent = count || 0;
  $('#spreadPageEnd').textContent = spread === 2 && current < count ? `–${Math.min(count, current + 1)}` : '';
}

let referenceSignature = '';
let referenceGeneration = 0;
async function syncReflowReferences(force = false) {
  if (state.bookKind !== 'reflow' || !state.documentReady) return;
  const sourcePath = state.sourcePath;
  const request = { outline: state.outline.map(item => ({ id: item.id, title: item.title, location: item.pageIndex })),
    summaries: state.pageRangeSummaries, draft: state.summaryDraft };
  const signature = JSON.stringify([sourcePath, state.reflowLayoutRevision, request]);
  if (!force && referenceSignature === signature) return;
  referenceSignature = signature;
  const generation = ++referenceGeneration;
  const result = await state.reflowReader.resolveReferences(request);
  if (generation !== referenceGeneration || sourcePath !== state.sourcePath || state.bookKind !== 'reflow') return;
  state.outlineReferences = Object.fromEntries(result.outline.map(item => [item.id, item]));
  for (const resolved of result.summaries) {
    const record = state.pageRangeSummaries.find(item => item.id === resolved.id);
    if (record) Object.assign(record, resolved);
  }
  if (result.draft) state.summaryDraft = result.draft;
  referenceSignature = JSON.stringify([sourcePath, state.reflowLayoutRevision, { ...request, summaries: state.pageRangeSummaries, draft: state.summaryDraft }]);
  if (!$('#outlineList').contains(document.activeElement)) renderOutline();
  else {
    for (const node of $$('[data-outline-id]')) node.textContent = `P${state.outlineReferences[node.dataset.outlineId]?.pageNumber || 1}`;
    updateSummaryRangeFields();
  }
  persistSoon();
}

function updateSummaryRangeFields() {
  const draft = state.summaryDraft;
  const maximum = state.bookKind === 'reflow' ? state.reflowPageCount : pdf.pageCount;
  for (const [id, key] of [['summaryStartPage', 'startPage'], ['summaryEndPage', 'endPage']]) {
    const node = document.getElementById(id);
    if (node) { node.max = String(maximum); if (draft && node !== document.activeElement) node.value = draft[key]; }
  }
}

function renderFictionSummaryPanel(root) {
  const maximum = state.bookKind === 'reflow' ? state.reflowPageCount : pdf.pageCount;
  const current = Math.min(Math.max(currentReadingPage() + 1, 1), Math.max(maximum, 1));
  state.summaryDraft ||= { id: 'draft', startPage: current, endPage: current, anchors: [] };
  const panel = document.createElement('div'); panel.className = 'fiction-summary-panel';
  const form = document.createElement('div'); form.className = 'fiction-summary-form';
  const start = document.createElement('input'); start.type = 'number'; start.min = '1'; start.max = String(maximum); start.id = 'summaryStartPage'; start.value = String(state.summaryDraft.startPage); start.setAttribute('aria-label', '概要起始页');
  const dash = document.createElement('span'); dash.textContent = '—';
  const end = document.createElement('input'); end.type = 'number'; end.min = '1'; end.max = String(maximum); end.id = 'summaryEndPage'; end.value = String(state.summaryDraft.endPage); end.setAttribute('aria-label', '概要结束页');
  const generate = document.createElement('button'); generate.className = 'small-primary'; generate.textContent = '生成';
  const updateDraft = () => {
    state.summaryDraft = { id: 'draft', startPage: Number(start.value), endPage: Number(end.value), anchors: [] };
    if (Number.isInteger(state.summaryDraft.startPage) && state.summaryDraft.startPage > 0 && state.summaryDraft.endPage >= state.summaryDraft.startPage) syncReflowReferences(true).catch(showError);
  };
  start.onchange = end.onchange = updateDraft;
  generate.onclick = async () => {
    const maximum = state.bookKind === 'reflow' ? state.reflowPageCount : pdf.pageCount;
    const first = Number(start.value); const last = Number(end.value);
    if (!Number.isInteger(first) || !Number.isInteger(last) || first < 1 || last < first || last > maximum) return showError(`请输入 1–${maximum} 之间的有效页码范围。`);
    generate.disabled = true; generate.textContent = '生成中…';
    try { await generatePageRangeSummary(first, last); }
    finally { generate.disabled = false; generate.textContent = '生成'; renderOutline(); }
  };
  const help = document.createElement('p'); help.className = 'fiction-summary-help'; help.textContent = `请输入阅读器页码，范围 1–${Math.max(maximum, 1)}。每次结果都会保留。`;
  form.append(start, dash, end, generate, help); panel.append(form);
  const list = document.createElement('div'); list.className = 'fiction-summary-list';
  if (!state.pageRangeSummaries.length) {
    const empty = document.createElement('p'); empty.className = 'empty-list'; empty.textContent = '还没有概要。输入页码范围后生成。'; list.append(empty);
  }
  state.pageRangeSummaries.forEach(record => {
    const card = document.createElement('article'); card.className = 'fiction-summary-card';
    const header = document.createElement('header'); const title = document.createElement('button'); title.className = 'fiction-summary-jump'; title.textContent = record.startPage === record.endPage ? `第 ${record.startPage} 页` : `第 ${record.startPage}–${record.endPage} 页`;
    const remove = document.createElement('button'); remove.className = 'danger'; remove.textContent = '删除'; remove.onclick = () => { state.pageRangeSummaries = state.pageRangeSummaries.filter(item => item.id !== record.id); persistSoon(); renderOutline(); };
    const text = document.createElement('p'); text.textContent = record.summary;
    const jump = () => {
      if (state.bookKind === 'reflow') {
        if (record.anchors?.length) state.reflowReader.goToAnchor(record.anchors[0]);
        else state.reflowReader.goToPage(record.startPage - 1);
      } else pdf.goToPage(record.startPage - 1);
    };
    title.onclick = text.onclick = jump; title.title = '跳转到概要对应原文';
    header.append(title, remove); card.append(header, text); list.append(card);
  });
  panel.append(list); root.append(panel);
  syncReflowReferences().catch(showError);
}

async function generatePageRangeSummary(startPage, endPage) {
  if (!settings.apiKey || !settings.model) return showError('请先连接 API 并选择模型。');
  const sourcePath = state.sourcePath;
  let anchors = [];
  let text = '';
  if (state.bookKind === 'reflow') {
    const range = await state.reflowReader.textForPageRange(startPage - 1, endPage - 1);
    text = (range.pages || []).join('\n').trim();
    anchors = range.anchors || [];
  } else {
    text = state.pages.filter(page => page.pageIndex >= startPage - 1 && page.pageIndex <= endPage - 1).map(page => page.text).join('\n').trim();
  }
  if (!text) return showError('所选页码范围没有可用文本。');
  setStatus('正在生成页码概要…');
  const response = await api.generateFictionSummary({
    id: crypto.randomUUID(), apiKey: settings.apiKey, baseURL: settings.baseURL || '', model: settings.model,
    messages: [{ role: 'user', content: `页码范围：${startPage === endPage ? `第 ${startPage} 页` : `第 ${startPage}–${endPage} 页`}\n\n所选页码原文：\n${text}` }]
  });
  if (state.sourcePath !== sourcePath) return;
  state.pageRangeSummaries.unshift({ id: crypto.randomUUID(), startPage, endPage, anchors, summary: response.text || '', createdAt: new Date().toISOString() });
  await syncReflowReferences(true);
  await persist(); setStatus('页码概要已生成');
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
  if (state.layoutLocked && $('.workspace').classList.contains('assistant-hidden')) return;
  $('.workspace').classList.remove('assistant-hidden');
  $('#apiAssistant').classList.remove('active');
  $('#manualOutlinePanel').classList.add('active');
  $('#assistantPanelTitle').textContent = '手动添加目录';
  $('#apiSelectors').classList.add('hidden');
  $('#openSettings').classList.add('hidden');
  $('#manualParseStatus').textContent = '';
  state.manualTOCPageIndices = detectTOCPages(state.pages);
  state.manualPreview = state.outline.map(entry => ({ ...entry, id: entry.id || crypto.randomUUID(), selected: false }));
  if (!state.manualPreview.length) addManualEntry(false);
  renderManualPreview();
}

function closeManualOutlinePanel() {
  $('#manualOutlinePanel').classList.remove('active');
  $('#apiAssistant').classList.add('active');
  $('#apiSelectors').classList.remove('hidden');
  $('#openSettings').classList.remove('hidden');
  applyBookKindChrome();
}

function openCharacterManagement() {
  if (state.layoutLocked && $('.workspace').classList.contains('assistant-hidden')) return;
  characterDraft = new CharacterManager().fromJSON(state.characters.toJSON());
  $('.workspace').classList.remove('assistant-hidden');
  $('#apiAssistant').classList.remove('active');
  $('#manualOutlinePanel').classList.remove('active');
  $('#characterManagementPanel').classList.add('active');
  $('#assistantPanelTitle').textContent = '人物管理';
  $('#apiSelectors').classList.add('hidden');
  $('#openSettings').classList.add('hidden');
  $('#characterHighlightsToggle').checked = characterDraft.highlightsEnabled !== false;
  renderCharacterEditors();
}

function closeCharacterManagement() {
  if (characterDraft) state.characters = characterDraft;
  characterDraft = null;
  $('#characterManagementPanel').classList.remove('active');
  $('#apiAssistant').classList.add('active');
  $('#apiSelectors').classList.remove('hidden');
  $('#openSettings').classList.remove('hidden');
  syncDocumentCharacters();
  renderCharacters();
  applyBookKindChrome();
  persistSoon();
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
    if (state.bookKind === 'reflow') {
      const maximum = maximumOutlineLocation();
      state.manualTOCPageIndices = [];
      state.manualPreview = parsed.map(entry => ({
        ...entry,
        id: crypto.randomUUID(),
        pageIndex: Math.min(Math.max(Number(entry.printedPage || 1) - 1, 0), maximum - 1),
        source: 'manual',
        selected: false
      }));
      $('#manualParseStatus').textContent = `已识别 ${state.manualPreview.length} 条 · 阅读位置已锁定，可逐项调整`;
      renderManualPreview();
      return;
    }
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
    const reflow = state.bookKind === 'reflow';
    const maximum = reflow ? maximumOutlineLocation() : Math.max(pdf.pageCount, 1);
    const physical = document.createElement('label'); physical.className = 'manual-physical-page'; physical.textContent = reflow ? '位置' : 'PDF';
    const physicalInput = document.createElement('input');
    physicalInput.type = 'number'; physicalInput.min = 1; physicalInput.max = maximum; physicalInput.value = entry.pageIndex + 1;
    physicalInput.setAttribute('aria-label', reflow ? '电子书阅读位置' : '实际 PDF 页'); physicalInput.title = reflow ? '稳定的电子书阅读位置；可直接修改' : '自动校准后的实际跳转页；可直接修改以覆盖自动结果';
    physicalInput.onchange = () => {
      entry.pageIndex = Math.min(Math.max(Number(physicalInput.value || 1) - 1, 0), maximum - 1);
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
  $('#manualBatchLevel').disabled = selectedCount === 0;
  $('#deleteManualEntries').disabled = selectedCount === 0;
}

function addManualEntry(render = true) {
  const current = currentReadingPage();
  state.manualPreview.push({ id: crypto.randomUUID(), title: '', printedPage: Math.max(current + 1, 1), pageIndex: Math.max(current, 0), level: 0, source: 'manual', selected: false });
  if (render) renderManualPreview();
}

function insertManualEntry(index) {
  const previous = state.manualPreview[index];
  state.manualPreview.splice(index + 1, 0, { id: crypto.randomUUID(), title: '', printedPage: previous.printedPage || previous.pageIndex + 1, pageIndex: previous.pageIndex, level: previous.level, source: 'manual', selected: false });
}

function recalibrateManualPreview() {
  const previous = state.manualPreview;
  if (state.bookKind === 'reflow') {
    const maximum = maximumOutlineLocation();
    state.manualPreview = previous.map(entry => ({
      ...entry,
      pageIndex: Math.min(Math.max(Number(entry.printedPage || 1) - 1, 0), maximum - 1)
    }));
    return;
  }
  const calibrated = calibrateManualTOC(previous, state.pages, state.manualTOCPageIndices);
  state.manualPreview = calibrated.map((entry, index) => ({ ...previous[index], ...entry }));
}

function maximumOutlineLocation() {
  if (state.bookKind !== 'reflow') return Math.max(pdf.pageCount, 1);
  return Math.max(1, ...(state.reflowBook?.sections || []).map(section =>
    Number(section.startPageIndex || 0) + Math.max(1, Number(section.pageCount || 1))
  ));
}

function applyManualBatchLevel() {
  const level = Math.min(Math.max(Number($('#manualBatchLevel').value || 0), 0), 5);
  const selected = state.manualPreview.filter(entry => entry.selected);
  selected.forEach(entry => { entry.level = level; });
  $('#manualParseStatus').textContent = `已修改 ${selected.length} 项层级`;
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
  const index = state.bookmarks.findIndex(item => item.pageIndex === currentReadingPage());
  if (index >= 0) state.bookmarks.splice(index, 1);
  else { state.bookmarks.push({ id: crypto.randomUUID(), pageIndex: currentReadingPage(), name: `P${currentReadingPage() + 1}` }); switchSidebar('bookmarks'); }
  renderBookmarks(); updateBookmarkButton(); persistSoon();
}

function updateBookmarkButton() {
  const active = state.bookmarks.some(item => item.pageIndex === currentReadingPage());
  $('#toggleBookmark').classList.toggle('active', active);
  $('#toggleBookmark').title = active ? '取消当前页书签' : '添加当前页书签';
}

function renderBookmarks() {
  const root = $('#bookmarkList'); root.replaceChildren();
  state.bookmarks.sort((a, b) => a.pageIndex - b.pageIndex).forEach(bookmark => {
    const row = document.createElement('div'); row.className = 'record-row bookmark-row';
    const icon = document.createElement('button'); icon.className = 'bookmark-jump'; icon.title = '跳到书签'; icon.innerHTML = '<svg class="app-icon"><use href="#icon-bookmark"></use></svg>'; icon.onclick = () => goToReadingPage(bookmark.pageIndex);
    const input = document.createElement('input'); input.value = bookmark.name; input.onchange = () => { bookmark.name = input.value; persistSoon(); };
    const page = document.createElement('button'); page.textContent = `P${bookmark.pageIndex + 1}`; page.onclick = () => goToReadingPage(bookmark.pageIndex);
    row.append(icon, input, page); root.append(row);
  });
}

function characterOccurrenceCount(character) {
  let count = 0;
  for (const page of state.pages) count += state.characters.occurrences(page.text, character.id).length;
  return count;
}

function characterOccurrenceRecords(character) {
  const records = [];
  state.pages.forEach((page, pageOffset) => {
    const hits = state.characters.occurrences(page.text, character.id);
    const nameCounts = new Map();
    hits.forEach(hit => {
      const key = String(hit.name || '').toLocaleLowerCase('zh-CN');
      const queryOccurrenceIndex = nameCounts.get(key) || 0;
      nameCounts.set(key, queryOccurrenceIndex + 1);
      records.push({
        ...hit,
        pageIndex: page.pageIndex,
        pageOffset,
        queryOccurrenceIndex,
        sectionID: page.sectionID,
        text: String(page.text || '').slice(Math.max(0, hit.start - 38), Math.min(String(page.text || '').length, hit.end + 62)).replace(/\s+/g, ' ').trim()
      });
    });
  });
  return records;
}

function characterOccurrenceWindow(records, limit = 11) {
  if (records.length <= limit) return records;
  let nearest = 0;
  let distance = Infinity;
  records.forEach((record, index) => {
    const next = Math.abs(record.pageIndex - currentReadingPage());
    if (next < distance) { distance = next; nearest = index; }
  });
  const before = Math.floor((limit - 1) / 2);
  let start = Math.max(0, nearest - before);
  start = Math.min(start, records.length - limit);
  return records.slice(start, start + limit);
}

function goToCharacterOccurrence(character, record, globalIndex = null) {
  const query = record.name || character.name;
  if (state.bookKind === 'reflow' && record.sectionID) {
    const pageText = state.pages[record.pageOffset]?.text || '';
    state.reflowReader?.goToSearch({
      query,
      sectionID: record.sectionID,
      ratio: record.start / Math.max(pageText.length, 1),
      snippet: record.text,
      fallbackLocation: record.pageIndex
    });
  } else {
    pdf.goToTextOccurrence(record.pageIndex, query, record.queryOccurrenceIndex);
  }
  if (Number.isInteger(globalIndex)) characterNavigationIndices.set(character.id, globalIndex);
  setStatus(`已定位到「${character.name}」第 ${(globalIndex ?? 0) + 1} 处`);
}

function navigateCharacterOccurrence(character, records, direction) {
  if (!records.length) return;
  let target = characterNavigationIndices.get(character.id);
  if (Number.isInteger(target)) {
    target = Math.max(0, Math.min(records.length - 1, target + direction));
  } else if (direction < 0) {
    target = records.findLastIndex(record => record.pageIndex <= currentReadingPage());
    if (target < 0) target = 0;
  } else {
    target = records.findIndex(record => record.pageIndex >= currentReadingPage());
    if (target < 0) target = records.length - 1;
  }
  goToCharacterOccurrence(character, records[target], target);
}

function renderCharacters() {
  const root = $('#characterList'); if (!root) return;
  root.replaceChildren();
  if ($('#characterHighlightsToggle')) $('#characterHighlightsToggle').checked = state.characters.highlightsEnabled !== false;
  $('#charactersStatus').textContent = state.characters.characters.length
    ? `${state.characters.characters.length} 位人物`
    : '为小说中的人物建立档案';
  if (!state.characters.characters.length) {
    const empty = document.createElement('p'); empty.className = 'characters-empty';
    empty.textContent = '还没有人物。点击右上角“管理”，可批量识别或逐个添加人物。';
    root.append(empty);
    return;
  }
  state.characters.characters.forEach(character => {
    const item = document.createElement('div'); item.className = 'character-item';
    const expanded = expandedCharacterIDs.has(character.id);
    item.classList.toggle('expanded', expanded);
    const dot = document.createElement('span'); dot.className = 'character-color-dot'; dot.style.background = character.cssColorFor(true);
    const info = document.createElement('div'); info.className = 'character-info-block';
    const name = document.createElement('div'); name.className = 'character-name'; name.textContent = character.name;
    info.append(name);
    if (character.aliases.length) {
      const aliases = document.createElement('div'); aliases.className = 'character-aliases'; aliases.textContent = `别名：${character.aliases.join('、')}`;
      info.append(aliases);
    }
    if (character.information) {
      const detail = document.createElement('div'); detail.className = 'character-info'; detail.textContent = character.information;
      info.append(detail);
    }
    const records = characterOccurrenceRecords(character);
    const occurrences = document.createElement('div'); occurrences.className = 'character-occurrences'; occurrences.textContent = `全文 ${records.length} 处`;
    info.append(occurrences);
    const actions = document.createElement('div'); actions.className = 'character-item-actions';
    if (records.length) {
      const previous = document.createElement('button'); previous.textContent = '←'; previous.title = '上一次出现';
      previous.onclick = event => { event.stopPropagation(); navigateCharacterOccurrence(character, records, -1); };
      const next = document.createElement('button'); next.textContent = '→'; next.title = '下一次出现';
      next.onclick = event => { event.stopPropagation(); navigateCharacterOccurrence(character, records, 1); };
      actions.append(previous, next);
    }
    const expand = document.createElement('button'); expand.textContent = expanded ? '收起' : '展开';
    expand.onclick = event => { event.stopPropagation(); if (expanded) expandedCharacterIDs.delete(character.id); else expandedCharacterIDs.add(character.id); renderCharacters(); };
    actions.append(expand);
    item.append(dot, info, actions);
    item.onclick = () => { if (expanded) expandedCharacterIDs.delete(character.id); else expandedCharacterIDs.add(character.id); renderCharacters(); };
    if (expanded) {
      const list = document.createElement('div'); list.className = 'character-occurrence-list';
      if (!records.length) list.textContent = '书中尚未出现该人物';
      characterOccurrenceWindow(records).forEach(record => {
        const button = document.createElement('button');
        const globalIndex = records.indexOf(record);
        button.textContent = `${globalIndex + 1} · P${record.pageIndex + 1}　${record.text}`;
        button.onclick = event => { event.stopPropagation(); goToCharacterOccurrence(character, record, globalIndex); };
        list.append(button);
      });
      item.append(list);
    }
    root.append(item);
  });
}

function addCharacterBatch() {
  const input = $('#characterBatchInput');
  const manager = characterDraft || state.characters;
  const count = manager.addFromBatch(input.value);
  if (!count) return setStatus('没有识别到有效的人物行；格式：人物：身份，关系等信息。');
  input.value = '';
  manager.assignUniqueColors();
  if (characterDraft) renderCharacterEditors();
  else { syncDocumentCharacters(); renderCharacters(); persistSoon(); }
  setStatus(`已添加或更新 ${count} 位人物`);
}

function addSingleCharacter() {
  const name = $('#newCharacterName').value.trim();
  if (!name) return;
  const manager = characterDraft || state.characters;
  manager.addOrUpdate(name, { information: $('#newCharacterInfo').value.trim() });
  manager.assignUniqueColors();
  $('#newCharacterName').value = '';
  $('#newCharacterInfo').value = '';
  if (characterDraft) renderCharacterEditors();
  else { syncDocumentCharacters(); renderCharacters(); persistSoon(); }
}

function renderCharacterEditors() {
  const root = $('#characterEditorList');
  if (!root || !characterDraft) return;
  root.replaceChildren();
  if (!characterDraft.characters.length) {
    const empty = document.createElement('p'); empty.className = 'subtle'; empty.textContent = '识别或添加后，可在这里逐个修改。'; root.append(empty); return;
  }
  characterDraft.characters.forEach(character => {
    const row = document.createElement('div'); row.className = 'character-editor-row';
    const dot = document.createElement('span'); dot.className = 'character-color-dot'; dot.style.background = character.cssColorFor(true);
    const fields = document.createElement('div'); fields.className = 'character-editor-fields';
    const name = document.createElement('input'); name.value = character.name; name.placeholder = '人物名字';
    name.onchange = () => { const value = name.value.trim(); if (value) character.names = [value, ...character.aliases]; };
    const aliases = document.createElement('input'); aliases.value = character.aliases.join('、'); aliases.placeholder = '其他名字（顿号或逗号分隔）';
    aliases.onchange = () => { character.names = [character.name, ...aliases.value.split(/[、,，/；;]+/).map(value => value.trim()).filter(Boolean)]; };
    const detail = document.createElement('input'); detail.value = character.information; detail.placeholder = '身份、关系等信息';
    detail.onchange = () => { character.identity = detail.value.trim(); character.relationship = ''; };
    fields.append(name, aliases, detail);
    const remove = document.createElement('button'); remove.textContent = '删除'; remove.onclick = () => { characterDraft.delete(character.id); renderCharacterEditors(); };
    row.append(dot, fields, remove); root.append(row);
  });
}

function showSelectionToolbar(event, selection) {
  state.selectedText = selection.text; state.selectedFragments = selection.fragments;
  if (!state.highlights.some(mark => mark.id === state.selectedMarkID)) state.selectedMarkID = null;
  const toolbar = $('#selectionToolbar'); toolbar.classList.remove('hidden');
  const width = toolbar.offsetWidth || 300;
  const height = toolbar.offsetHeight || 42;
  toolbar.style.left = `${Math.max(8, Math.min(window.innerWidth - width - 8, event.clientX - width / 2))}px`;
  const below = event.clientY + 10;
  toolbar.style.top = `${Math.max(8, below)}px`;
}

function hideSelectionToolbar() {
  $('#selectionToolbar').classList.add('hidden');
  state.selectedText = '';
  state.selectedFragments = [];
  state.selectedMarkID = null;
  state.reflowSelection = null;
  if (state.bookKind === 'reflow') state.reflowReader?.clearSelection();
  else pdf.clearSelection();
}

function activeSelection() {
  if (state.bookKind === 'reflow') {
    if (state.reflowSelection) return state.reflowSelection;
    if (state.selectedText) return { text: state.selectedText };
    return null;
  }
  if (state.selectedText && state.selectedFragments.length) return { text: state.selectedText, fragments: state.selectedFragments };
  return pdf.captureSelection(true);
}

function createMark(record) {
  if (state.bookKind === 'reflow') {
    if (!record.text || !record.sectionID || record.start == null) return;
    const anchor = { sectionID: record.sectionID, start: record.start, end: record.end };
    const created = { id: crypto.randomUUID(), text: normalizeGroupedSelectionText(record.text), reflowAnchor: anchor, reflowAnchors: record.anchors || [anchor], pageIndex: Math.max(0, record.location ?? state.lastPageIndex), color: record.color || 'yellow', kind: record.kind || 'highlight', note: record.note || '', createdAt: new Date().toISOString() };
    state.highlights.push(created);
    syncReflowMarks(); renderHighlights(); persistSoon(); setStatus(record.kind === 'annotation' ? '批注已添加' : '划线已添加');
    return;
  }
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
  editor.style.left = toolbar.style.left; editor.classList.remove('hidden');
  const toolbarTop = parseFloat(toolbar.style.top || 100);
  const below = toolbarTop + toolbar.offsetHeight + 6;
  const editorHeight = editor.offsetHeight || 88;
  editor.style.top = `${below + editorHeight <= window.innerHeight - 8 ? below : Math.max(8, toolbarTop - editorHeight - 6)}px`;
  $('#annotationText').value = state.highlights.find(mark => mark.id === state.selectedMarkID)?.note || '';
  $('#annotationText').focus(); toolbar.classList.add('hidden');
}

function commitAnnotation() {
  const note = $('#annotationText').value.trim(); if (!pendingAnnotation || !note) return cancelAnnotation();
  if (state.bookKind === 'reflow') {
    const existing = state.highlights.find(mark => mark.id === state.selectedMarkID);
    if (existing) {
      existing.kind = 'annotation'; existing.color = 'green'; existing.note = note;
      syncReflowMarks(); renderHighlights(); persistSoon(); setStatus('批注已保存');
    } else {
      createMark({ ...pendingAnnotation, kind: 'annotation', color: 'green', note });
    }
    cancelAnnotation();
    return;
  }
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
    const content = document.createElement('button'); content.className = 'record-content'; content.onclick = () => goToReadingPage(mark.pageIndex);
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
function deleteSelectedMarks() { const ids = selectedMarkIDs(); state.highlights = state.highlights.filter(mark => !ids.has(mark.id)); syncMarksToView(); renderHighlights(); persistSoon(); setStatus(`已删除 ${ids.size} 条`); }
function mergeSelectedMarks() {
  const ids = selectedMarkIDs(); const selected = state.highlights.filter(mark => ids.has(mark.id)).sort((a, b) => a.pageIndex - b.pageIndex || a.createdAt.localeCompare(b.createdAt));
  if (selected.length < 2) return showError('请至少选择两条划线或批注。');
  const first = selected[0]; const allAnnotations = selected.every(mark => mark.kind === 'annotation');
  const merged = { ...first, id: crypto.randomUUID(), text: selected.map(mark => `• ${mark.text}`).join('\n'), fragments: selected.flatMap(mark => mark.fragments || []), kind: allAnnotations ? 'annotation' : 'highlight', color: allAnnotations ? 'green' : first.color, note: selected.map(mark => mark.note).filter(Boolean).join('\n'), pageIndex: Math.min(...selected.map(mark => mark.pageIndex)) };
  state.highlights = state.highlights.filter(mark => !ids.has(mark.id)); state.highlights.push(merged); syncMarksToView(); renderHighlights(); persistSoon(); setStatus('已合并为一条');
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
    const source = String(page.text || '');
    searchMatchRanges(query, source).forEach((range, occurrenceIndex) => {
      const start = Math.max(0, range.start - 46);
      const end = Math.min(source.length, range.end + 74);
      results.push({
        pageIndex: page.pageIndex,
        sectionID: page.sectionID,
        occurrenceIndex,
        ratio: range.start / Math.max(source.length, 1),
        sentence: source.slice(start, end).replace(/\s+/g, ' ').trim()
      });
    });
  }
  $('#searchCount').textContent = `${results.length} 条结果`;
  results.slice(0, 500).forEach(result => {
    const button = document.createElement('button'); button.className = 'search-result'; button.innerHTML = highlightHTML(result.sentence, query); button.onclick = () => {
      if (state.bookKind === 'reflow' && result.sectionID) {
        state.reflowReader?.goToSearch({ query, sectionID: result.sectionID, ratio: result.ratio, snippet: result.sentence, fallbackLocation: result.pageIndex });
      } else {
        pdf.goToTextOccurrence(result.pageIndex, query, result.occurrenceIndex);
      }
    }; root.append(button);
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
  if (state.bookKind === 'reflow') {
    let query = '';
    if ($('#highlightsPanel').classList.contains('active') && highlightSearchActive) query = normalizeText($('#highlightSearchInput').value);
    else if ($('#searchPanel').classList.contains('active') && fullSearchActive) query = normalizeText($('#searchInput').value);
    state.reflowReader?.find(query);
    return;
  }
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

function companionMode() {
  return state.bookCategory === 'fiction' ? 'free' : 'academic';
}

async function sendQuestion() {
  if (state.currentRequest) return;
  const visibleQuestion = $('#questionInput').value.trim(); if (!visibleQuestion) return;
  if (!settings.apiKey || !settings.model) { openDialog('settingsDialog'); return showError('请先连接 API 并选择模型。'); }
  if (!state.chunks.length) return showError('请等待全文索引完成。');
  const focusPage = state.selectedFragments.length ? Math.min(...state.selectedFragments.map(item => item.pageIndex)) : (state.reflowSelection ? Math.max(0, reflowSectionIndex(state.reflowSelection.sectionID)) : currentReadingPage());
  const scope = contextScope(visibleQuestion); const wholeBook = $('#wholeBook').checked; const depthKey = currentReadingDepth(); const depth = DEPTHS[depthKey];
  const mode = companionMode();
  const retrievalQuery = `${state.selectedText}\n${visibleQuestion}`.trim();
  const contextChunks = prepareForPrompt(retrieveForReading(retrievalQuery, focusPage, state.chunks, { limit: depth.contextLimit, wholeBook, scope }), Math.round(depth.budgets[scope] * (wholeBook ? 1.12 : 1)));
  const quoteIsInQuestion = state.selectedText && normalizeText(visibleQuestion).includes(normalizeText(state.selectedText));
  const promptChunks = quoteIsInQuestion
    ? contextChunks.map(chunk => ({ ...chunk, text: chunk.text.replace(normalizeText(state.selectedText), '〔当前划选位置〕') }))
    : contextChunks;
  const context = promptContext(promptChunks);
  const sourceIdentity = state.selectedText ? await api.sha256(`${focusPage}|${state.selectedText}`) : null;
  const history = contextualHistory(sourceIdentity, focusPage, depth.historyLimit);
  const usesLJGReadSkill = mode === 'academic' && state.ljgReadSkillEnabled !== false;
  const cacheKey = await api.sha256(JSON.stringify({ visibleQuestion, context, model: settings.model, depth: depthKey, mode, usesLJGReadSkill, history: history.map(turn => turn.content) }));
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
    const response = await api.requestAI({ id: requestId, apiKey: settings.apiKey, baseURL: settings.baseURL || '', model: settings.model, companionMode: mode, system: systemPrompt(depth, wholeBook, /链接资源/.test(visibleQuestion), usesLJGReadSkill), messages: [...history.map(turn => ({ role: turn.role, content: turn.content })), { role: 'user', content: `${context ? `<book_context>\n${context}\n</book_context>\n\n` : ''}${visibleQuestion}` }], maxTokens: mode === 'free' ? 900 : depth.outputLimit, maxContinuations: depth.maxContinuations, reasoningEffort: mode === 'free' ? 'low' : depth.reasoningEffort });
    placeholder.content = response.text || state.currentRequest?.partial || ''; placeholder.loading = false; placeholder.usage = response.usage;
    state.lastUsage = { ...response.usage, retrievedChunks: contextChunks.length, estimatedContextTokens: estimatedTokens(context), wholeBook, scope, model: settings.model, depth: depthKey, localCache: false };
    if (!response.incomplete) {
      state.answerCache[cacheKey] = structuredClone(placeholder);
      if (Object.keys(state.answerCache).length > 160) delete state.answerCache[Object.keys(state.answerCache)[0]];
    }
    const continuationStatus = response.continuationCount ? ` · 已自动续写 ${response.continuationCount} 次` : '';
    const completionStatus = response.incomplete ? 'AI 已保留可用回答（服务端再次触顶）' : 'AI 回答完成';
    setStatus(`${completionStatus}${continuationStatus} · 输入 ${response.usage?.inputTokens || 0} / 输出 ${response.usage?.outputTokens || 0}`);
  } catch (error) {
    state.apiChats = state.apiChats.filter(turn => turn.id !== placeholder.id);
    if (String(error).includes('aborted') || String(error).includes('取消')) setStatus('已取消 AI 请求');
    else showError(error);
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

function systemPrompt(depth, wholeBook, resources, usesLJGReadSkill = true) {
  if (companionMode() === 'free') {
    return `你是 Reading Companion 的虚构类伴读，主要陪读小说、戏剧和其他叙事文本。直接回答读者提出的事实问题；需要文学分析时，只做与当前问题有关的适度分析。严格依据提供的原文，不编造人物、情节、页码或作者意图；证据不足就简短说明。默认使用中文，不加载学术伴读框架，不追加碰撞问题，不强制小标题、列表或固定结构。\n\n默认用 120–300 个汉字完成回答；简单事实问题尽量在 1–3 句内回答，文学分析最多使用三个短段。只保留直接答案和必要依据，不重复问题，不写开场白、总结或延伸提问，并在篇幅内完整结束。${wholeBook ? '\n已开启联系全书：可跨章节比较人物与情节。' : ''}${resources ? '\n资源模式：只给与问题直接相关、真实可访问的高质量链接。' : ''}`;
  }
  const visible = depth === DEPTHS.economical ? '约 448–640 个汉字，最多 3 个短节' : depth === DEPTHS.deep ? '约 1,280–1,920 个汉字，最多 6 个短节' : '约 768–1,152 个汉字，最多 4 个短节';
  if (!usesLJGReadSkill) {
    return `你是 Reading Companion 的原文问答助手。默认使用中文，只依据给定原文和明确标注的外部资料回答。涉及文本判断时引用提供的页码；证据不足时直接说明，不编造页码、章节、引文或作者观点。先给出直接答案，再补充回答所必需的原文依据。使用自然、清晰的 Markdown，不强制固定结构，不追加碰撞问题，不使用额外伴读框架。\n\n本轮目标篇幅：${visible}。在篇幅内完整结束。${wholeBook ? '\n已开启联系全书：可跨章节比较，但仍只引用最相关证据。' : ''}${resources ? '\n资源模式：优先官方页面、馆藏、作者/机构页面和高质量资料，链接必须真实可访问。' : ''}`;
  }
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

function selectedPendingChats() {
  const ids = selectedChatIDs();
  return state.apiChats.filter(turn => ids.has(turn.id) && !state.exportedChatIDs.includes(turn.id));
}

function openChatNoteExportDialog() {
  const selected = selectedPendingChats();
  if (!selected.length) return showError('没有尚未加入笔记的选中对话。');
  $('#chatNoteExportCount').textContent = `已选 ${selected.length} 条`;
  openDialog('chatNoteExportDialog');
}

async function confirmChatNoteExport() {
  const button = $('#confirmChatNoteExport');
  const mode = document.querySelector('input[name=quickChatExport]:checked')?.value || 'original';
  const collapsed = $('#quickCollapseConversation').checked;
  button.disabled = true;
  try {
    if (await addSelectedChatsToNotes({ mode, collapsed })) closeDialog('chatNoteExportDialog');
  } catch (error) {
    showError(error);
  } finally {
    button.disabled = false;
  }
}

async function addSelectedChatsToNotes(options = {}) {
  const ids = selectedChatIDs(); const selected = state.apiChats.filter(turn => ids.has(turn.id) && !state.exportedChatIDs.includes(turn.id));
  if (!selected.length) return showError('没有尚未加入笔记的选中对话。');
  const mode = options.mode ?? document.querySelector('input[name=chatExport]:checked')?.value ?? 'original';
  const collapsed = options.collapsed ?? $('#collapseConversation').checked;
  let block; if (mode === 'condensed') block = aiBlock(selected, { collapsed, condensed: await condenseConversation(selected) }); else block = aiBlock(selected, { collapsed });
  const anchor = selected.find(turn => Number.isInteger(turn.noteAnchorPageIndex))?.noteAnchorPageIndex;
  const source = selected.find(turn => turn.sourceText)?.sourceText || '';
  let markdown = await ensureNotebook(); markdown = insertUnderChapter(markdown, block, chapterForPage(anchor ?? currentReadingPage(), state.outline, source));
  await api.writeTextFile(state.notePath, markdown); state.exportedChatIDs.push(...selected.map(turn => turn.id)); await persist(); setStatus('AI 对话已加入笔记');
  return true;
}

async function condenseConversation(turns) {
  if (!settings.apiKey || !settings.model) throw new Error('整理浓缩需要 AI。请先在设置中连接 API 并选择模型，或选择“保留原文”。');
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
  if (!state.sourcePath) throw new Error('请先打开图书。');
  await saveSettingsFromUI();
  const registeredVault = await api.resolveObsidianVault(settings.vaultPath);
  if (!registeredVault) {
    const registered = await api.listObsidianVaults();
    throw new Error(`当前设置的文件夹不是 Obsidian 已注册的 Vault。请先在 Obsidian 中使用“打开文件夹作为仓库”，再在“设置 > Obsidian”选择它。\n\n已注册 Vault：\n${registered.length ? registered.join('\n') : '没有检测到已注册 Vault'}`);
  }
  settings.vaultPath = registeredVault;
  state.notePath = await api.joinPath(settings.vaultPath, settings.vaultFolder, `${safeFileName(state.title)}.md`);
  const exists = await api.pathExists(state.notePath);
  if (!exists || forceSkeleton) await api.writeTextFile(state.notePath, skeleton(state.title, state.outline, state.sourcePath));
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

async function refreshBookshelfData() {
  const [projects, folders] = await Promise.all([api.listProjects(), api.listBookshelfFolders()]);
  const withCovers = await Promise.all(projects.map(async project => {
    if (project.coverVersion && project.sourcePath) {
      const dataURL = await api.loadCover(project.sourcePath).catch(() => null);
      if (dataURL) return { ...project, coverPath: dataURL };
    }
    return project;
  }));
  return { projects: withCovers, folders };
}

async function showBookshelf() {
  await persist();
  if (!libraryView) {
    libraryView = new LibraryView($('#bookshelfDialog'));
    libraryView.onOpenBook(async project => {
      closeDialog('bookshelfDialog');
      await api.openProject(project.sourcePath, state.sourcePath);
    });
    libraryView.onCreateFolder(async () => {
      const name = prompt('文件夹名称：');
      if (!name || !name.trim()) return;
      await api.createBookshelfFolder(name.trim(), null);
      await renderBookshelf();
    });
    libraryView.onMoveProject(async (projects, folderID, included) => {
      await api.setProjectsFolderMembership(projects.map(project => project.sourcePath), folderID, included);
      await renderBookshelf();
    });
    libraryView.onSetCategory(async (projects, category) => {
      await api.setProjectsCategory(projects.map(project => project.sourcePath), category);
      if (projects.some(project => project.sourcePath === state.sourcePath)) {
        state.bookCategory = category;
        if (category !== 'fiction') {
          expandedCharacterIDs.clear();
          if ($('#characterManagementPanel').classList.contains('active')) closeCharacterManagement();
        }
        applyBookKindChrome();
        await persist();
      }
      await renderBookshelf();
    });
    libraryView.onDeleteProjects(async projects => {
      await Promise.all(projects.map(project => api.deleteProject(project.sourcePath)));
      setStatus(`已重置 ${projects.length} 本书的伴读数据`);
      await renderBookshelf();
    });
    libraryView.onDeleteFolder(async folder => {
      await api.deleteBookshelfFolder(folder.id);
      setStatus(`已删除文件夹“${folder.name}”`);
      await renderBookshelf();
    });
  }
  openDialog('bookshelfDialog');
  await renderBookshelf();
}

async function renderBookshelf() {
  if (!libraryView) return;
  const { projects, folders } = await refreshBookshelfData();
  libraryView.render(projects, folders);
}

function populateSettings() {
  $('#apiKey').value = settings.apiKey || ''; $('#baseURL').value = settings.baseURL || ''; $('#vaultPath').value = settings.vaultPath || ''; $('#vaultFolder').value = settings.vaultFolder || 'Reading Companion'; settings.depth = normalizedReadingDepth(settings.depth); $('#depthSelector').value = settings.depth;
  setConnectionMode(settings.connectionMode || (settings.baseURL ? 'custom' : 'official'));
  setConnectionStatus(settings.apiKey && settings.model ? '连接成功' : '未连接', !!(settings.apiKey && settings.model));
  populateModels(settings.models || [], settings.model);
  renderDepthMenu();
}
function populateModels(models, selected) {
  const uniqueModels = [...new Set((models || []).map(model => String(model).trim()).filter(Boolean))].sort();
  if (selected && !uniqueModels.includes(selected)) uniqueModels.push(selected);
  uniqueModels.sort();
  const selector = $('#modelSelector');
  selector.innerHTML = '<option value="">选择模型</option>';
  uniqueModels.forEach(model => selector.add(new Option(model, model, false, model === selected)));
  settings.models = uniqueModels;
  renderModelMenu();
}

const DEPTH_DETAILS = {
  economical: ['节省', '较短上下文，适合释义和快速问答'],
  balanced: ['均衡', '兼顾上下文、回答完整度与用量'],
  deep: ['深读', '更长上下文与更高推理强度']
};

function normalizedReadingDepth(value) { return DEPTHS[value] ? value : 'balanced'; }
function currentReadingDepth() {
  const value = normalizedReadingDepth(settings.depth || $('#depthSelector').value);
  settings.depth = value;
  $('#depthSelector').value = value;
  return value;
}

function closeAISelectorMenus() {
  $('#modelMenu').classList.add('hidden');
  $('#depthMenu').classList.add('hidden');
  $('#modelMenuButton').setAttribute('aria-expanded', 'false');
  $('#depthMenuButton').setAttribute('aria-expanded', 'false');
}

function toggleAISelectorMenu(kind) {
  const menu = kind === 'model' ? $('#modelMenu') : $('#depthMenu');
  const button = kind === 'model' ? $('#modelMenuButton') : $('#depthMenuButton');
  const shouldOpen = menu.classList.contains('hidden');
  closeAISelectorMenus();
  if (shouldOpen) { menu.classList.remove('hidden'); button.setAttribute('aria-expanded', 'true'); }
}

function renderModelMenu() {
  const menu = $('#modelMenu');
  menu.replaceChildren();
  const models = settings.models || [];
  $('#modelMenuLabel').textContent = settings.model || '选择模型';
  $('#modelMenuButton').title = settings.model ? `当前模型：${settings.model}` : '切换模型';
  if (!models.length) {
    const empty = document.createElement('div'); empty.className = 'ai-selector-empty'; empty.textContent = '请先在设置中验证 API Key。'; menu.append(empty);
  } else {
    models.forEach(model => {
      const button = document.createElement('button');
      button.type = 'button'; button.setAttribute('role', 'menuitemradio'); button.setAttribute('aria-checked', String(model === settings.model));
      button.classList.toggle('selected', model === settings.model);
      const name = document.createElement('span'); name.textContent = model;
      const check = document.createElement('span'); check.className = 'ai-selector-check'; check.textContent = model === settings.model ? '✓' : '';
      button.append(name, check); button.onclick = () => selectAIModel(model);
      menu.append(button);
    });
  }
  const refresh = document.createElement('button'); refresh.type = 'button'; refresh.className = 'refresh-models'; refresh.innerHTML = '<span>刷新模型</span><span>↻</span>'; refresh.onclick = refreshAvailableModels;
  menu.append(refresh);
}

function renderDepthMenu() {
  const selected = currentReadingDepth();
  const menu = $('#depthMenu'); menu.replaceChildren();
  $('#depthMenuLabel').textContent = DEPTH_DETAILS[selected][0];
  $('#depthMenuButton').title = `当前阅读模式：${DEPTH_DETAILS[selected][0]}`;
  Object.entries(DEPTH_DETAILS).forEach(([value, [label, detail]]) => {
    const button = document.createElement('button'); button.type = 'button'; button.setAttribute('role', 'menuitemradio'); button.setAttribute('aria-checked', String(value === selected)); button.classList.toggle('selected', value === selected);
    const copy = document.createElement('span'); copy.innerHTML = `<span>${label}</span><span class="depth-menu-detail">${detail}</span>`;
    const check = document.createElement('span'); check.className = 'ai-selector-check'; check.textContent = value === selected ? '✓' : '';
    button.append(copy, check); button.onclick = () => selectReadingDepth(value); menu.append(button);
  });
}

function queueSettingsSave() {
  const snapshot = structuredClone(settings);
  settingsSaveChain = settingsSaveChain.catch(() => {}).then(() => api.saveSettings(snapshot));
  return settingsSaveChain;
}

async function selectAIModel(model) {
  const resolved = String(model || '').trim();
  if (!resolved) return;
  settings.model = resolved; $('#modelSelector').value = resolved;
  renderModelMenu(); closeAISelectorMenus();
  await queueSettingsSave(); setStatus(`已切换模型：${resolved}`);
}

async function selectReadingDepth(value) {
  const resolved = normalizedReadingDepth(value);
  settings.depth = resolved; $('#depthSelector').value = resolved;
  renderDepthMenu(); closeAISelectorMenus();
  await queueSettingsSave(); setStatus(`已切换阅读模式：${DEPTH_DETAILS[resolved][0]}`);
}

async function refreshAvailableModels() {
  closeAISelectorMenus();
  if (!settings.apiKey) { switchSettingsTab('api'); openDialog('settingsDialog'); return showError('请先连接 API。'); }
  try {
    setStatus('正在刷新模型…');
    const connectionMode = settings.connectionMode === 'custom' ? 'custom' : 'official';
    const detection = connectionMode === 'custom'
      ? { models: await api.listModels({ apiKey: settings.apiKey, baseURL: settings.baseURL || '' }), baseURL: settings.baseURL || '' }
      : await api.detectProvider(settings.apiKey);
    const models = detection.models || [];
    if (!models.length) throw new Error('没有读取到可用模型。');
    settings.baseURL = detection.baseURL || settings.baseURL || '';
    settings.models = models;
    if (!models.includes(settings.model)) settings.model = models[0];
    populateModels(models, settings.model); await queueSettingsSave(); setStatus(`已刷新 ${models.length} 个模型`);
  } catch (error) { showError(error); }
}

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
    settings = { ...settings, ...candidate, connectionMode, models, model: models.includes(settings.model) ? settings.model : models[0], depth: currentReadingDepth(), vaultPath: $('#vaultPath').value.trim(), vaultFolder: $('#vaultFolder').value.trim() || 'Reading Companion' };
    await queueSettingsSave(); populateModels(models, settings.model); setConnectionStatus(`连接成功 · ${models.length} 个模型`, true); setStatus('API 连接成功'); setTimeout(() => closeDialog('settingsDialog'), 650);
  } catch (error) { setConnectionStatus('连接失败', false); showError(error); }
}

async function saveSettingsFromUI() {
  const connectionMode = settings.connectionMode === 'custom' ? 'custom' : 'official';
  settings = { ...settings, connectionMode, apiKey: $('#apiKey').value.trim() || settings.apiKey, baseURL: connectionMode === 'custom' ? $('#baseURL').value.trim() : (settings.baseURL || ''), model: $('#modelSelector').value || settings.model, depth: currentReadingDepth(), vaultPath: $('#vaultPath').value.trim() || settings.vaultPath, vaultFolder: $('#vaultFolder').value.trim() || 'Reading Companion' };
  await queueSettingsSave();
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
      if (state.layoutLocked) return;
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
function updateZoom() {
  if (state.bookKind === 'reflow') {
    $('#zoomLabel').textContent = `${Math.round(state.reflowScale * 100)}%`;
  } else {
    $('#zoomLabel').textContent = `${Math.round(pdf.pdfViewer.currentScale * 100)}%`;
  }
  $('#fitMode').value = 'custom';
}

function adjustZoom(delta) {
  if (state.layoutLocked) return;
  if (state.bookKind === 'reflow') {
    state.reflowScale = Math.min(2.25, Math.max(0.65, state.reflowScale + delta));
    state.reflowReader?.setScale(state.reflowScale);
    updateZoom();
    return;
  }
  pdf.zoom(delta);
  updateZoom();
}

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
