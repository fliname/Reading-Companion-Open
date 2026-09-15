import {
  buildTOCText,
  detectTOCPages,
  inferHierarchy,
  parseAutomaticTOC,
  resolveTOCPages,
} from './toc.mjs';

function automaticError(message) {
  const error = new Error(message);
  error.code = 'AUTO_TOC_NOT_FOUND';
  return error;
}

/**
 * Lightweight, dependency-free automatic outline recognizer.
 *
 * It reuses text already extracted for reading, and asks the caller to OCR
 * only a bounded prefix when the PDF has no useful text layer. No Python,
 * Torch, image model, or network service is involved.
 */
export async function recognizeAutomaticOutline({
  kind = 'pdf',
  pages = [],
  bookNavigation = [],
  readNativeOutline,
  refreshPage,
  onProgress,
  makeID = () => '',
  maxOCRPages = 48,
} = {}) {
  if (kind === 'reflow') {
    const outline = bookNavigation
      .filter(entry => String(entry?.title || '').trim())
      .map(entry => ({
        id: makeID(),
        title: String(entry.title).trim(),
        pageIndex: Math.max(0, Number(entry.location) || 0),
        level: Math.max(0, Number(entry.level) || 0),
        source: 'book',
      }));
    if (!outline.length) throw automaticError('正文中没有可识别的标题，请使用“手动添加”。');
    return { outline, nativeOutline: outline.map(entry => ({ ...entry })), refreshedPages: [], label: `图书目录 · ${outline.length} 条` };
  }

  const nativeOutline = typeof readNativeOutline === 'function'
    ? await readNativeOutline()
    : [];
  if (nativeOutline.length) {
    return { outline: nativeOutline, nativeOutline, refreshedPages: [], label: `PDF 目录 · ${nativeOutline.length} 条` };
  }

  const orderedPages = [...pages].sort((left, right) => left.pageIndex - right.pageIndex);
  const scanLimit = Math.min(orderedPages.length, Math.max(36, Math.ceil(orderedPages.length * 0.25)));
  let working = orderedPages.slice(0, scanLimit);
  let indices = detectTOCPages(working);
  const refreshedPages = [];

  if (!indices.length && typeof refreshPage === 'function') {
    const count = Math.min(scanLimit, Math.max(0, maxOCRPages));
    for (let index = 0; index < count; index += 1) {
      onProgress?.({ index, count, message: `定位目录 ${index + 1}/${count}` });
      const refreshed = await refreshPage(index);
      if (refreshed) refreshedPages.push(refreshed);
      if (index >= 5) {
        const found = detectTOCPages(refreshedPages);
        if (found.length && index > found.at(-1) + 2) break;
      }
    }
    const merged = new Map(working.map(page => [page.pageIndex, page]));
    refreshedPages.forEach(page => merged.set(page.pageIndex, page));
    working = [...merged.values()].sort((left, right) => left.pageIndex - right.pageIndex);
    indices = detectTOCPages(working);
  }

  if (!indices.length) throw automaticError('未定位到可信目录页，请使用“手动添加”。');
  const entries = parseAutomaticTOC(buildTOCText(working, indices));
  if (!entries.length) throw automaticError('目录页已找到，但没有解析出有效条目。');
  const outline = resolveTOCPages(inferHierarchy(entries), indices, working).map(entry => ({
    ...entry,
    id: makeID(),
    source: 'automatic',
  }));
  return { outline, nativeOutline: [], refreshedPages, label: `${outline.length} 条` };
}
