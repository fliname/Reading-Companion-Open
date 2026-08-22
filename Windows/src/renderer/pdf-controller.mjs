import * as pdfjsLib from './vendor/pdf.mjs';
import { EventBus, PDFViewer, PDFLinkService, PDFFindController } from './vendor/pdf_viewer.mjs';
import { normalizeText } from '../shared/retrieval.mjs';
import { reconstructText } from '../shared/pdf-layout.mjs';
import { normalizeOCRLines, rotateNormalizedBox } from '../shared/ocr-layer.mjs';
import { needsOCRCorrection } from '../shared/selection.mjs';
import { compareOCRSelectionLines, nearestOCRSelectionLine, ocrCharacterOffsetAtPoint, selectedOCRClientRect } from '../shared/ocr-selection.mjs';
import { formatSelectionParts, normalizeSelectionPart } from '../shared/selection-group.mjs';
import { ocrSearchBoxes } from '../shared/ocr-search.mjs';
import {
  boundedRasterScale,
  PDF_VIEWER_MAX_CANVAS_DIMENSION,
  PDF_VIEWER_MAX_CANVAS_PIXELS
} from '../shared/pdf-render-policy.mjs';

pdfjsLib.GlobalWorkerOptions.workerSrc = './vendor/pdf.worker.mjs';

export class PDFController {
  constructor({ container, viewer, onPageChange, onSelection, onStatus, onOCRProgress, onScaleChange }) {
    this.container = container;
    this.viewerElement = viewer;
    this.onPageChange = onPageChange;
    this.onSelection = onSelection;
    this.onStatus = onStatus;
    this.onOCRProgress = onOCRProgress;
    this.onScaleChange = onScaleChange;
    this.eventBus = new EventBus();
    this.linkService = new PDFLinkService({ eventBus: this.eventBus });
    this.findController = new PDFFindController({ eventBus: this.eventBus, linkService: this.linkService });
    this.pdfViewer = new PDFViewer({
      container,
      viewer,
      eventBus: this.eventBus,
      linkService: this.linkService,
      findController: this.findController,
      textLayerMode: 1,
      annotationMode: 2,
      // A scanned page is usually one large bitmap. Capping the backing canvas
      // prevents a handful of zoomed pages from exhausting Chromium's graphics
      // memory and turning already-rendered pages black on Windows.
      maxCanvasPixels: PDF_VIEWER_MAX_CANVAS_PIXELS,
      maxCanvasDim: PDF_VIEWER_MAX_CANVAS_DIMENSION,
      // PDF.js' detail canvas is replaced asynchronously while scrolling. That
      // replacement is a common source of stale/black frames after context loss.
      enableDetailCanvas: false,
      enableOptimizedPartialRendering: false,
      minDurationToUpdateCanvas: 0
    });
    this.linkService.setViewer(this.pdfViewer);
    this.pdfDocument = null;
    this.pageLabels = [];
    this.pages = [];
    this.marks = [];
    this.locked = false;
    this.rotation = 0;
    this.highlightMode = false;
    this.highlightColor = 'yellow';
    this.searchQuery = '';
    this.searchFragments = [];
    this.pendingSelection = { text: [], fragments: [] };
    this.ocrDragStart = null;
    this.ocrDragFrame = null;
    this.activeTouches = new Map();
    this.pinchStart = null;
    this.hiddenAt = 0;
    this.recoveryFrame = null;
    this.pageRecoveryTimes = new Map();
    this.callbacks = {};
    this.bindEvents();
  }

  bindEvents() {
    this.eventBus.on('pagesinit', () => {
      this.pdfViewer.currentScaleValue = 'page-width';
      this.renderMarks();
    });
    this.eventBus.on('pagechanging', event => this.onPageChange?.(event.pageNumber - 1));
    this.eventBus.on('scalechanging', () => this.onScaleChange?.(this.pdfViewer.currentScale));
    this.eventBus.on('pagerendered', event => {
      const pageIndex = (event.pageNumber || 1) - 1;
      if (event.error) {
        console.warn('PDF page render failed', pageIndex, event.error);
        this.schedulePageRecovery(pageIndex);
        return;
      }
      this.bindCanvasRecovery(pageIndex);
      this.renderMarks();
      this.renderOCRTextLayer(pageIndex);
      this.renderSearchHighlights(pageIndex);
    });
    this.eventBus.on('textlayerrendered', event => {
      const pageIndex = (event.pageNumber || 1) - 1;
      this.renderOCRTextLayer(pageIndex);
      this.renderSearchHighlights(pageIndex);
    });
    this.container.addEventListener('mousedown', event => this.handleMouseDown(event));
    this.container.addEventListener('mousemove', event => this.handleMouseMove(event));
    this.container.addEventListener('mouseup', event => this.handleMouseUp(event));
    this.container.addEventListener('scroll', () => { if (this.locked && this.container.scrollLeft !== 0) this.container.scrollLeft = 0; }, { passive: true });
    this.container.addEventListener('wheel', event => {
      if (event.ctrlKey || event.metaKey) {
        event.preventDefault();
        if (!this.locked) this.zoom(Math.max(-0.35, Math.min(0.35, -event.deltaY * 0.0025)));
        return;
      }
      if (!this.locked) return;
      if (Math.abs(event.deltaX) > Math.abs(event.deltaY)) event.preventDefault();
      this.container.scrollLeft = 0;
    }, { passive: false });
    this.container.addEventListener('pointerdown', event => this.handleTouchPointer(event), { passive: false });
    this.container.addEventListener('pointermove', event => this.handleTouchPointer(event), { passive: false });
    this.container.addEventListener('pointerup', event => this.releaseTouchPointer(event), { passive: false });
    this.container.addEventListener('pointercancel', event => this.releaseTouchPointer(event), { passive: false });
    document.addEventListener('keydown', event => {
      if (event.target?.matches('textarea,input,[contenteditable=true]')) return;
      if (event.key === 'ArrowDown') { event.preventDefault(); this.nextPage(); }
      if (event.key === 'ArrowUp') { event.preventDefault(); this.previousPage(); }
    });
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) {
        this.hiddenAt = Date.now();
        return;
      }
      // Chromium may discard a backing surface while the app is covered or
      // minimized. Recreate visible canvases after a meaningful suspension.
      if (this.hiddenAt && Date.now() - this.hiddenAt > 1000) this.recoverVisiblePages(true);
      this.hiddenAt = 0;
    });
    window.addEventListener('pageshow', event => {
      if (event.persisted) this.recoverVisiblePages(true);
    });
  }

  bindCanvasRecovery(pageIndex) {
    const pageView = this.pdfViewer.getPageView(pageIndex);
    const canvas = pageView?.canvas;
    if (!canvas || canvas.dataset.readingCompanionRecovery === '1') return;
    canvas.dataset.readingCompanionRecovery = '1';
    canvas.addEventListener('contextlost', event => {
      event.preventDefault();
      this.schedulePageRecovery(pageIndex);
    }, { once: true });
  }

  schedulePageRecovery(pageIndex) {
    const now = Date.now();
    if (now - (this.pageRecoveryTimes.get(pageIndex) || 0) < 2000) return;
    this.pageRecoveryTimes.set(pageIndex, now);
    requestAnimationFrame(() => {
      const pageView = this.pdfViewer.getPageView(pageIndex);
      if (!pageView?.div?.isConnected || !this.pdfDocument) return;
      pageView.reset();
      this.pdfViewer.forceRendering();
    });
  }

  recoverVisiblePages(force = false) {
    if (!this.pdfDocument) return;
    if (this.recoveryFrame) cancelAnimationFrame(this.recoveryFrame);
    this.recoveryFrame = requestAnimationFrame(() => {
      this.recoveryFrame = null;
      const visible = this.pdfViewer._getVisiblePages?.();
      let needsRendering = false;
      for (const item of visible?.views || []) {
        const pageView = item.view;
        const canvas = pageView?.canvas;
        const lost = canvas?.isContextLost?.() === true;
        const missing = !canvas || !canvas.isConnected || canvas.width < 2 || canvas.height < 2;
        if (!force && !lost && !missing) continue;
        pageView.reset();
        needsRendering = true;
      }
      if (needsRendering) this.pdfViewer.forceRendering();
    });
  }

  handleTouchPointer(event) {
    if (event.pointerType !== 'touch') return;
    this.activeTouches.set(event.pointerId, { x: event.clientX, y: event.clientY });
    if (this.activeTouches.size < 2) return;
    event.preventDefault();
    const [first, second] = [...this.activeTouches.values()];
    const distance = Math.hypot(first.x - second.x, first.y - second.y);
    if (!this.pinchStart) {
      this.pinchStart = { distance: Math.max(distance, 1), scale: this.pdfViewer.currentScale };
      return;
    }
    if (this.locked) return;
    this.pdfViewer.currentScale = Math.max(0.25, Math.min(5, this.pinchStart.scale * distance / this.pinchStart.distance));
  }

  releaseTouchPointer(event) {
    if (event.pointerType !== 'touch') return;
    this.activeTouches.delete(event.pointerId);
    if (this.activeTouches.size < 2) this.pinchStart = null;
  }

  async load(data) {
    this.onStatus?.('正在打开 PDF…');
    this.pages = [];
    if (this.pdfDocument) {
      const previousDocument = this.pdfDocument;
      this.pdfDocument = null;
      this.pdfViewer.setDocument(null);
      this.linkService.setDocument(null);
      this.findController.setDocument(null);
      await previousDocument.destroy().catch(error => console.warn('Unable to release previous PDF', error));
    }
    this.pdfDocument = await pdfjsLib.getDocument({
      data: new Uint8Array(data),
      cMapUrl: './vendor/cmaps/',
      cMapPacked: true,
      standardFontDataUrl: './vendor/standard_fonts/',
      wasmUrl: './vendor/wasm/',
      // Keep PDF.js on the stable 2D path. These are explicit because newer
      // PDF.js releases may otherwise change browser-dependent defaults.
      enableHWA: false,
      enableWebGPU: false
    }).promise;
    this.pageLabels = await this.pdfDocument.getPageLabels() || [];
    this.linkService.setDocument(this.pdfDocument);
    this.pdfViewer.setDocument(this.pdfDocument);
    await this.eventBus._on?.pagesloaded;
    this.onStatus?.(`PDF 已打开 · ${this.pdfDocument.numPages} 页`);
    return { pageCount: this.pdfDocument.numPages, outline: await this.readEmbeddedOutline() };
  }

  async readEmbeddedOutline() {
    const source = await this.pdfDocument.getOutline();
    if (!source?.length) return [];
    const result = [];
    const walk = async (items, level = 0) => {
      for (const item of items) {
        let destination = item.dest;
        if (typeof destination === 'string') destination = await this.pdfDocument.getDestination(destination);
        let pageIndex = 0;
        if (Array.isArray(destination)) pageIndex = await this.pdfDocument.getPageIndex(destination[0]);
        result.push({ id: crypto.randomUUID(), title: normalizeText(item.title), pageIndex, printedPage: null, level, source: 'PDF' });
        if (item.items?.length) await walk(item.items, level + 1);
      }
    };
    await walk(source);
    return result;
  }

  async extractPages(cachedPages = null) {
    const cached = new Map((cachedPages || []).map(page => [page.pageIndex, page]));
    const pages = [];
    for (let pageIndex = 0; pageIndex < this.pdfDocument.numPages; pageIndex += 1) {
      const existing = cached.get(pageIndex);
      if (existing?.text) {
        if (existing.pageLabel == null) existing.pageLabel = this.pageLabels[pageIndex] || null;
        pages.push(existing);
        this.onStatus?.(`正在载入索引缓存 ${pageIndex + 1}/${this.pdfDocument.numPages}`);
        continue;
      }
      const page = await this.pdfDocument.getPage(pageIndex + 1);
      const content = await page.getTextContent({ includeMarkedContent: false, disableNormalization: false });
      const embedded = reconstructText(content.items, page.getViewport({ scale: 1 }).width);
      const embeddedText = normalizePageText(embedded);
      let text = embedded;
      let cameFromOCR = false;
      let ocrLines = [];
      const semanticLength = (embedded.match(/[\p{L}\p{N}\p{Script=Han}]/gu) || []).length;
      const suspiciousTextLayer = embedded.replace(/\s/g, '').length < 24
        || (content.items.length > 80 && semanticLength < Math.min(400, content.items.length * 1.2));
      if (suspiciousTextLayer) {
        try {
          const raster = await this.renderPageRaster(page, 1.8);
          const jobId = `page-${pageIndex}-${Date.now()}`;
          const recognized = await window.readingCompanion.recognizeOCR({ image: raster.bytes, jobId });
          if (recognized.text.replace(/\s/g, '').length >= embedded.replace(/\s/g, '').length) {
            text = recognized.text;
            cameFromOCR = true;
            ocrLines = normalizeOCRLines(recognized.lines, raster.width, raster.height);
          }
        } catch (error) {
          console.warn('OCR failed', pageIndex, error);
        }
      }
      pages.push({
        pageIndex,
        text: normalizePageText(text),
        embeddedText,
        cameFromOCR,
        ocrLines,
        pageLabel: this.pageLabels[pageIndex] || null
      });
      this.pages = pages;
      this.renderOCRTextLayer(pageIndex);
      this.onStatus?.(`正在提取文本与 OCR ${pageIndex + 1}/${this.pdfDocument.numPages}`);
      await new Promise(resolve => setTimeout(resolve, 0));
    }
    this.setOCRPages(pages);
    return pages;
  }

  async renderPageRaster(page, scale = 2) {
    const baseViewport = page.getViewport({ scale: 1 });
    const viewport = page.getViewport({ scale: boundedRasterScale(baseViewport.width, baseViewport.height, scale) });
    const canvas = document.createElement('canvas');
    canvas.width = Math.ceil(viewport.width);
    canvas.height = Math.ceil(viewport.height);
    const width = canvas.width;
    const height = canvas.height;
    try {
      await page.render({ canvasContext: canvas.getContext('2d', { alpha: false }), viewport }).promise;
      const blob = await new Promise(resolve => canvas.toBlob(resolve, 'image/png'));
      if (!blob) throw new Error('无法创建页面图像');
      const bytes = new Uint8Array(await blob.arrayBuffer());
      return { bytes, width, height };
    } finally {
      // Setting both dimensions to zero releases the backing store immediately;
      // merely dropping the DOM reference leaves reclamation to a later GC pass.
      canvas.width = 0;
      canvas.height = 0;
    }
  }

  async renderPageImage(page, scale = 2) { return (await this.renderPageRaster(page, scale)).bytes; }

  async renderThumbnail(pageIndex, canvas, maxWidth = 92) {
    const page = await this.pdfDocument.getPage(pageIndex + 1);
    const original = page.getViewport({ scale: 1 });
    const viewport = page.getViewport({ scale: Math.min(1, maxWidth / Math.max(original.width, 1)) });
    canvas.width = Math.ceil(viewport.width);
    canvas.height = Math.ceil(viewport.height);
    await page.render({ canvasContext: canvas.getContext('2d', { alpha: false }), viewport }).promise;
  }

  async forceOCRPage(pageIndex, legacyLayout = false) {
    const page = await this.pdfDocument.getPage(pageIndex + 1);
    const content = await page.getTextContent({ includeMarkedContent: false, disableNormalization: false });
    const embeddedText = normalizePageText(reconstructText(content.items, page.getViewport({ scale: 1 }).width));
    const raster = await this.renderPageRaster(page, 2.25);
    const jobId = `toc-${pageIndex}-${Date.now()}`;
    const result = await window.readingCompanion.recognizeOCR({ image: raster.bytes, jobId, legacyLayout });
    const ocrLines = normalizeOCRLines(result.lines, raster.width, raster.height);
    return {
      pageIndex,
      text: normalizePageText(result.text),
      // Windows OCR can miss white chapter titles drawn over complex artwork.
      // Keep the PDF text layer as a secondary calibration source instead of
      // destroying a usable title when a forced OCR refresh is written back.
      embeddedText,
      cameFromOCR: true,
      ocrLines,
      lines: result.lines,
      pageLabel: this.pageLabels[pageIndex] || null
    };
  }

  setOCRPages(pages = []) {
    this.pages = pages;
    this.pages.forEach(page => { if (page.pageLabel == null) page.pageLabel = this.pageLabels[page.pageIndex] || null; });
    for (let pageIndex = 0; pageIndex < this.pageCount; pageIndex += 1) this.renderOCRTextLayer(pageIndex);
  }

  renderOCRTextLayer(pageIndex) {
    const page = this.pages.find(item => item.pageIndex === pageIndex);
    const pageView = this.pdfViewer.getPageView(pageIndex);
    if (!pageView?.div) return;
    pageView.div.querySelector('.ocr-text-layer')?.remove();
    const nativeLayer = pageView.div.querySelector('.textLayer');
    if (!page?.cameFromOCR || !page.ocrLines?.length) {
      nativeLayer?.classList.remove('ocr-replaced-text-layer');
      pageView.div.classList.remove('ocr-selectable-page');
      return;
    }
    nativeLayer?.classList.add('ocr-replaced-text-layer');
    pageView.div.classList.add('ocr-selectable-page');
    const layer = document.createElement('div');
    layer.className = 'ocr-text-layer';
    layer.setAttribute('aria-label', 'OCR 可选择文本');
    const width = pageView.div.clientWidth;
    const height = pageView.div.clientHeight;
    for (const line of page.ocrLines) {
      const [x0, y0, x1, y1] = rotateNormalizedBox(line.box, this.rotation);
      const span = document.createElement('span');
      span.textContent = line.text;
      span.style.left = `${x0 * width}px`;
      span.style.top = `${y0 * height}px`;
      const targetWidth = Math.max(1, (x1 - x0) * width);
      span.style.height = `${Math.max(1, (y1 - y0) * height)}px`;
      span.style.fontSize = `${Math.max(6, (y1 - y0) * height * .86)}px`;
      layer.append(span);
      const naturalWidth = Math.max(span.getBoundingClientRect().width, 1);
      span.style.transform = `scaleX(${targetWidth / naturalWidth})`;
    }
    pageView.div.append(layer);
    if (this.searchQuery || this.searchFragments.length) {
      requestAnimationFrame(() => this.renderSearchHighlights(page.pageIndex));
    }
  }

  handleMouseDown(event) {
    if (event.button !== 0) return;
    const pageElement = this.pageElementAtPoint(event.clientX, event.clientY);
    if (!pageElement) { this.ocrDragStart = null; return; }
    const pageIndex = Number(pageElement.dataset.pageNumber) - 1;
    const page = this.pages.find(item => item.pageIndex === pageIndex);
    if ((event.ctrlKey || event.metaKey) && this.pendingSelection.fragments.length) window.getSelection()?.removeAllRanges();
    this.ocrDragStart = page?.cameFromOCR && page.ocrLines?.length
      ? { clientX: event.clientX, clientY: event.clientY, pageIndex }
      : null;
    if (this.ocrDragStart) {
      event.preventDefault();
      window.getSelection()?.removeAllRanges();
    }
  }

  handleMouseMove(event) {
    if (!this.ocrDragStart || !(event.buttons & 1)) return;
    if (Math.hypot(event.clientX - this.ocrDragStart.clientX, event.clientY - this.ocrDragStart.clientY) < 3) return;
    if (this.ocrDragFrame) cancelAnimationFrame(this.ocrDragFrame);
    const start = this.ocrDragStart;
    const end = { clientX: event.clientX, clientY: event.clientY };
    this.ocrDragFrame = requestAnimationFrame(() => {
      this.ocrDragFrame = null;
      if (this.ocrDragStart !== start) return;
      const selection = this.captureOCRDragSelection(start, end);
      if (selection.fragments.length) this.renderTransientSelection(this.combineWithPending(selection).fragments);
    });
  }

  captureOCRDragSelection(start, end) {
    if (!start || Math.hypot(end.clientX - start.clientX, end.clientY - start.clientY) < 3) return { text: '', fragments: [] };
    const endPageElement = this.pageElementAtPoint(end.clientX, end.clientY);
    const endPageIndex = endPageElement ? Number(endPageElement.dataset.pageNumber) - 1 : start.pageIndex;
    const lowerPage = Math.min(start.pageIndex, endPageIndex);
    const upperPage = Math.max(start.pageIndex, endPageIndex);
    const lines = [];
    for (let pageIndex = lowerPage; pageIndex <= upperPage; pageIndex += 1) {
      const page = this.pages.find(item => item.pageIndex === pageIndex);
      const pageView = this.pdfViewer.getPageView(pageIndex);
      if (!page?.cameFromOCR || !page.ocrLines?.length || !pageView?.div || !pageView.viewport) continue;
      const pageRect = pageView.div.getBoundingClientRect();
      page.ocrLines.forEach((line, lineIndex) => {
        const text = String(line.text || '').trim();
        if (!text) return;
        const [x0, y0, x1, y1] = rotateNormalizedBox(line.box, this.rotation);
        lines.push({
          pageIndex,
          lineIndex,
          text,
          pageRect,
          pageView,
          words: (line.words || []).map(word => {
            const [wordX0, wordY0, wordX1, wordY1] = rotateNormalizedBox(word.box, this.rotation);
            const left = pageRect.left + wordX0 * pageRect.width;
            const top = pageRect.top + wordY0 * pageRect.height;
            const right = pageRect.left + wordX1 * pageRect.width;
            const bottom = pageRect.top + wordY1 * pageRect.height;
            return { text: word.text, clientRect: { left, top, right, bottom, width: Math.max(1, right - left), height: Math.max(1, bottom - top) } };
          }),
          clientRect: {
            left: pageRect.left + x0 * pageRect.width,
            top: pageRect.top + y0 * pageRect.height,
            right: pageRect.left + x1 * pageRect.width,
            bottom: pageRect.top + y1 * pageRect.height,
            width: Math.max(1, (x1 - x0) * pageRect.width),
            height: Math.max(1, (y1 - y0) * pageRect.height)
          }
        });
      });
    }
    if (!lines.length) return { text: '', fragments: [] };
    lines.sort(compareOCRSelectionLines);
    const startCandidates = lines.filter(line => line.pageIndex === start.pageIndex);
    const endCandidates = lines.filter(line => line.pageIndex === endPageIndex);
    const startLine = nearestOCRSelectionLine(startCandidates.length ? startCandidates : lines, start.clientX, start.clientY);
    const endLine = nearestOCRSelectionLine(endCandidates.length ? endCandidates : lines, end.clientX, end.clientY);
    if (!startLine || !endLine) return { text: '', fragments: [] };

    let startIndex = lines.indexOf(startLine);
    let endIndex = lines.indexOf(endLine);
    let startOffset = ocrCharacterOffsetAtPoint(startLine, start.clientX, start.clientY);
    let endOffset = ocrCharacterOffsetAtPoint(endLine, end.clientX, end.clientY);
    if (startIndex > endIndex || (startIndex === endIndex && startOffset > endOffset)) {
      [startIndex, endIndex] = [endIndex, startIndex];
      [startOffset, endOffset] = [endOffset, startOffset];
    }

    const fragments = [];
    const texts = [];
    for (let index = startIndex; index <= endIndex; index += 1) {
      const line = lines[index];
      const characters = [...line.text];
      if (!characters.length) continue;
      let from = index === startIndex ? startOffset : 0;
      let to = index === endIndex ? endOffset : characters.length;
      from = Math.max(0, Math.min(characters.length, from));
      to = Math.max(0, Math.min(characters.length, to));
      if (startIndex === endIndex && to === from) to = Math.min(characters.length, from + 1);
      if (to <= from) continue;
      texts.push(characters.slice(from, to).join(''));
      const selectedClientRect = selectedOCRClientRect(line, from, to);
      const first = line.pageView.viewport.convertToPdfPoint(selectedClientRect.left - line.pageRect.left, selectedClientRect.top - line.pageRect.top);
      const second = line.pageView.viewport.convertToPdfPoint(selectedClientRect.right - line.pageRect.left, selectedClientRect.bottom - line.pageRect.top);
      fragments.push({ pageIndex: line.pageIndex, rect: [Math.min(first[0], second[0]), Math.min(first[1], second[1]), Math.max(first[0], second[0]), Math.max(first[1], second[1])] });
    }
    return { text: normalizeSelectedText(texts.join(' ')), fragments: deduplicateFragments(fragments) };
  }

  pageElementAtPoint(clientX, clientY) {
    const direct = document.elementFromPoint(clientX, clientY)?.closest?.('.page');
    if (direct && this.viewerElement.contains(direct)) return direct;
    const pages = [...this.viewerElement.querySelectorAll('.page')];
    return pages.sort((left, right) => distanceToClientRect(clientX, clientY, left.getBoundingClientRect()) - distanceToClientRect(clientX, clientY, right.getBoundingClientRect()))[0] || null;
  }

  combineWithPending(selection) {
    return {
      text: formatSelectionParts([...this.pendingSelection.text, selection.text].filter(Boolean)),
      fragments: deduplicateFragments([...this.pendingSelection.fragments, ...(selection.fragments || [])])
    };
  }

  renderTransientSelection(fragments) {
    this.viewerElement.querySelectorAll('.reading-mark-layer[data-mark-id="selection-preview"]').forEach(node => node.remove());
    this.drawFragments(fragments, 'selection-preview');
  }

  captureSelection(includePending = true) {
    const selection = window.getSelection();
    const fragments = [];
    const texts = [];
    if (selection && !selection.isCollapsed) {
      for (let rangeIndex = 0; rangeIndex < selection.rangeCount; rangeIndex += 1) {
        const range = selection.getRangeAt(rangeIndex);
        const text = normalizeSelectedText(range.toString());
        if (text) texts.push(text);
        const rectangles = [...range.getClientRects()].filter(rectangle => rectangle.width >= 1 && rectangle.height >= 1);
        if (!rectangles.length) {
          const bounds = range.getBoundingClientRect();
          if (bounds.width >= 1 && bounds.height >= 1) rectangles.push(bounds);
        }
        for (const rectangle of rectangles) {
          for (const pageElement of this.pagesForSelectionRectangle(rectangle, range)) {
            const pageRect = pageElement.getBoundingClientRect();
            const clipped = {
              left: Math.max(rectangle.left, pageRect.left),
              top: Math.max(rectangle.top, pageRect.top),
              right: Math.min(rectangle.right, pageRect.right),
              bottom: Math.min(rectangle.bottom, pageRect.bottom)
            };
            if (clipped.right - clipped.left < 1 || clipped.bottom - clipped.top < 1) continue;
            const pageIndex = Number(pageElement.dataset.pageNumber) - 1;
            const pageView = this.pdfViewer.getPageView(pageIndex);
            if (!pageView?.viewport) continue;
            const first = pageView.viewport.convertToPdfPoint(clipped.left - pageRect.left, clipped.top - pageRect.top);
            const second = pageView.viewport.convertToPdfPoint(clipped.right - pageRect.left, clipped.bottom - pageRect.top);
            fragments.push({ pageIndex, rect: [Math.min(first[0], second[0]), Math.min(first[1], second[1]), Math.max(first[0], second[0]), Math.max(first[1], second[1])] });
          }
        }
      }
    }
    const captured = includePending
      ? { text: formatSelectionParts([...this.pendingSelection.text, ...texts]), fragments: [...this.pendingSelection.fragments, ...fragments] }
      : { text: normalizeSelectedText(texts.join(' ')), fragments };
    captured.fragments = deduplicateFragments(captured.fragments);
    return captured;
  }

  pagesForSelectionRectangle(rectangle, range) {
    const result = [];
    const seen = new Set();
    const add = element => {
      const page = element?.closest?.('.page');
      if (!page || !this.viewerElement.contains(page) || seen.has(page)) return;
      const bounds = page.getBoundingClientRect();
      if (!clientRectanglesOverlap(rectangle, bounds)) return;
      seen.add(page);
      result.push(page);
    };

    const commonElement = range.commonAncestorContainer.nodeType === Node.ELEMENT_NODE
      ? range.commonAncestorContainer
      : range.commonAncestorContainer.parentElement;
    add(commonElement);

    const insetX = Math.min(2, rectangle.width / 2);
    const insetY = Math.min(2, rectangle.height / 2);
    const samplePoints = [
      [rectangle.left + rectangle.width / 2, rectangle.top + rectangle.height / 2],
      [rectangle.left + insetX, rectangle.top + rectangle.height / 2],
      [rectangle.right - insetX, rectangle.top + rectangle.height / 2],
      [rectangle.left + rectangle.width / 2, rectangle.top + insetY],
      [rectangle.left + rectangle.width / 2, rectangle.bottom - insetY]
    ];
    for (const [x, y] of samplePoints) add(document.elementFromPoint(x, y));
    if (result.length) return result;

    const intersecting = [...this.viewerElement.querySelectorAll('.page')]
      .map(page => ({ page, area: clientIntersectionArea(rectangle, page.getBoundingClientRect()) }))
      .filter(item => item.area > 0)
      .sort((left, right) => right.area - left.area);
    if (!intersecting.length) return [];
    const largest = intersecting[0].area;
    return intersecting.filter(item => item.area >= largest * 0.12).map(item => item.page);
  }

  handleMouseUp(event) {
    const ocrDragStart = this.ocrDragStart;
    this.ocrDragStart = null;
    if (this.ocrDragFrame) cancelAnimationFrame(this.ocrDragFrame);
    this.ocrDragFrame = null;
    setTimeout(() => {
      const ocrCaptured = this.captureOCRDragSelection(ocrDragStart, event);
      const nativeCaptured = this.captureSelection(false);
      const usedOCRCapture = Boolean(ocrCaptured.text && ocrCaptured.fragments.length);
      const captured = usedOCRCapture ? ocrCaptured : nativeCaptured;
      if (!captured.text || !captured.fragments.length) {
        this.renderTransientSelection([]);
        const mark = this.markAtPoint(event.clientX, event.clientY);
        if (mark) this.callbacks.onMarkClick?.(mark, event);
        return;
      }
      if (usedOCRCapture) {
        window.getSelection()?.removeAllRanges();
        this.renderTransientSelection(this.combineWithPending(captured).fragments);
      }
      if (event.ctrlKey || event.metaKey) {
        this.pendingSelection.text.push(normalizeSelectionPart(captured.text));
        this.pendingSelection.fragments.push(...captured.fragments);
      } else {
        this.pendingSelection = { text: [normalizeSelectionPart(captured.text)], fragments: [...captured.fragments] };
      }
      this.pendingSelection.fragments = deduplicateFragments(this.pendingSelection.fragments);
      this.renderSelectionPreview();
      const complete = this.combineWithPending({ text: '', fragments: [] });
      if (this.highlightMode) {
        this.callbacks.onCreateMark?.({ ...complete, color: this.highlightColor, kind: 'highlight' });
        this.clearSelection();
      } else this.onSelection?.(event, complete);
    }, 0);
  }

  markAtPoint(clientX, clientY) {
    const pageElement = document.elementFromPoint(clientX, clientY)?.closest?.('.page');
    if (!pageElement) return null;
    const pageIndex = Number(pageElement.dataset.pageNumber) - 1;
    const pageView = this.pdfViewer.getPageView(pageIndex);
    const bounds = pageElement.getBoundingClientRect();
    const [pdfX, pdfY] = pageView.viewport.convertToPdfPoint(clientX - bounds.left, clientY - bounds.top);
    return [...this.marks].reverse().find(mark => mark.fragments?.some(fragment => fragment.pageIndex === pageIndex
      && pdfX >= fragment.rect[0] && pdfX <= fragment.rect[2] && pdfY >= fragment.rect[1] && pdfY <= fragment.rect[3]));
  }

  async correctSelectionText(fragments, original) {
    // A searchable PDF's text layer is the authoritative source for a user's
    // exact selection. Re-running every selection through OCR used to change
    // simplified Chinese into traditional Chinese and pull neighbouring
    // characters into the saved quote. OCR is now only a last resort for
    // visibly broken PDF character maps.
    if (!needsOCRCorrection(original)) return original;
    const byPage = new Map();
    for (const fragment of fragments) byPage.set(fragment.pageIndex, [...(byPage.get(fragment.pageIndex) || []), fragment]);
    const recognized = [];
    for (const [pageIndex, pageFragments] of byPage) {
      const page = await this.pdfDocument.getPage(pageIndex + 1);
      const baseViewport = page.getViewport({ scale: 1 });
      const viewport = page.getViewport({ scale: boundedRasterScale(baseViewport.width, baseViewport.height, 2.5) });
      const rectangles = pageFragments.map(fragment => {
        const a = viewport.convertToViewportPoint(fragment.rect[0], fragment.rect[1]);
        const b = viewport.convertToViewportPoint(fragment.rect[2], fragment.rect[3]);
        return [Math.min(a[0], b[0]), Math.min(a[1], b[1]), Math.max(a[0], b[0]), Math.max(a[1], b[1])];
      });
      const x0 = Math.max(0, Math.floor(Math.min(...rectangles.map(rect => rect[0])) - 2));
      const y0 = Math.max(0, Math.floor(Math.min(...rectangles.map(rect => rect[1])) - 2));
      const x1 = Math.min(viewport.width, Math.ceil(Math.max(...rectangles.map(rect => rect[2])) + 2));
      const y1 = Math.min(viewport.height, Math.ceil(Math.max(...rectangles.map(rect => rect[3])) + 2));
      const canvas = document.createElement('canvas'); canvas.width = Math.ceil(viewport.width); canvas.height = Math.ceil(viewport.height);
      const crop = document.createElement('canvas'); crop.width = Math.max(1, x1 - x0); crop.height = Math.max(1, y1 - y0);
      let bytes;
      try {
        await page.render({ canvasContext: canvas.getContext('2d', { alpha: false }), viewport }).promise;
        crop.getContext('2d', { alpha: false }).drawImage(canvas, x0, y0, crop.width, crop.height, 0, 0, crop.width, crop.height);
        const blob = await new Promise(resolve => crop.toBlob(resolve, 'image/png'));
        if (!blob) throw new Error('无法创建选区图像');
        bytes = new Uint8Array(await blob.arrayBuffer());
      } finally {
        canvas.width = canvas.height = 0;
        crop.width = crop.height = 0;
      }
      const result = await window.readingCompanion.recognizeOCR({ image: bytes, jobId: `selection-${pageIndex}-${Date.now()}` });
      if (result.text) recognized.push(result.text);
    }
    const candidate = normalizeSelectedText(recognized.join(' '));
    if (!candidate) return original;
    const originalCompact = normalizeSelectedText(original).replace(/\s/g, '');
    const candidateCompact = candidate.replace(/\s/g, '');
    if ([...candidateCompact].length !== [...originalCompact].length) return original;
    return candidate;
  }

  clearSelection() {
    window.getSelection()?.removeAllRanges();
    this.pendingSelection = { text: [], fragments: [] };
    this.viewerElement.querySelectorAll('.selection-preview').forEach(node => node.remove());
  }

  renderSelectionPreview() {
    this.viewerElement.querySelectorAll('.selection-preview').forEach(node => node.remove());
    this.drawFragments(this.pendingSelection.fragments, 'selection-preview');
  }

  setMarks(marks) { this.marks = marks || []; this.renderMarks(); }

  renderMarks() {
    this.viewerElement.querySelectorAll('.reading-mark-layer').forEach(node => node.remove());
    for (const mark of this.marks) this.drawFragments(mark.fragments || [], `reading-mark ${mark.kind === 'annotation' ? 'annotation' : mark.color}`, mark.id);
    if (this.pendingSelection.fragments.length) this.renderSelectionPreview();
  }

  drawFragments(fragments, className, markId = '') {
    const grouped = new Map();
    for (const fragment of fragments) {
      if (!grouped.has(fragment.pageIndex)) grouped.set(fragment.pageIndex, []);
      grouped.get(fragment.pageIndex).push(fragment);
    }
    for (const [pageIndex, pageFragments] of grouped) {
      const pageView = this.pdfViewer.getPageView(pageIndex);
      if (!pageView?.div) continue;
      let layer = pageView.div.querySelector(`.reading-mark-layer[data-mark-id="${CSS.escape(markId || className)}"]`);
      if (!layer) {
        layer = document.createElement('div');
        layer.className = 'reading-mark-layer';
        layer.dataset.markId = markId || className;
        pageView.div.append(layer);
      }
      for (const fragment of pageFragments) {
        const first = pageView.viewport.convertToViewportPoint(fragment.rect[0], fragment.rect[1]);
        const second = pageView.viewport.convertToViewportPoint(fragment.rect[2], fragment.rect[3]);
        const viewportRect = [first[0], first[1], second[0], second[1]];
        const left = Math.min(viewportRect[0], viewportRect[2]);
        const top = Math.min(viewportRect[1], viewportRect[3]);
        const node = document.createElement('span');
        node.className = className;
        node.style.left = `${left}px`;
        node.style.top = `${top}px`;
        node.style.width = `${Math.abs(viewportRect[2] - viewportRect[0])}px`;
        node.style.height = `${Math.abs(viewportRect[3] - viewportRect[1])}px`;
        if (markId) node.dataset.markId = markId;
        layer.append(node);
      }
    }
  }

  goToPage(pageIndex) {
    const target = Math.max(0, Math.min(this.pageCount - 1, pageIndex));
    this.pdfViewer.currentPageNumber = target + 1;
    requestAnimationFrame(() => this.renderSearchHighlights(target));
  }
  nextPage() { this.goToPage(this.currentPage + 1); }
  previousPage() { this.goToPage(this.currentPage - 1); }
  get currentPage() { return (this.pdfViewer.currentPageNumber || 1) - 1; }
  get pageCount() { return this.pdfDocument?.numPages || 0; }
  setScale(value) { this.pdfViewer.currentScaleValue = value; }
  zoom(delta) { this.pdfViewer.currentScale = Math.max(0.25, Math.min(5, this.pdfViewer.currentScale + delta)); }
  rotate() {
    this.rotation = (this.rotation + 90) % 360;
    this.pdfViewer.pagesRotation = this.rotation;
    requestAnimationFrame(() => this.setOCRPages(this.pages));
  }
  setLocked(value) { this.locked = value; if (value) this.container.scrollLeft = 0; }
  find(query, fragments = []) {
    this.searchQuery = String(query || '').trim();
    this.searchFragments = deduplicateFragments(fragments);
    this.viewerElement.querySelectorAll('.original-search-layer').forEach(node => node.remove());
    for (let pageIndex = 0; pageIndex < this.pageCount; pageIndex += 1) this.renderSearchHighlights(pageIndex);
  }

  clearFind() {
    this.searchQuery = '';
    this.searchFragments = [];
    this.viewerElement.querySelectorAll('.original-search-layer').forEach(node => node.remove());
  }

  renderSearchHighlights(pageIndex) {
    const pageView = this.pdfViewer.getPageView(pageIndex);
    if (!pageView?.div || !pageView.viewport) return;
    pageView.div.querySelector('.original-search-layer')?.remove();
    const pageFragments = this.searchFragments.filter(fragment => fragment.pageIndex === pageIndex);
    if (!this.searchQuery && !pageFragments.length) return;
    const layer = document.createElement('div');
    layer.className = 'original-search-layer';
    for (const fragment of pageFragments) {
      const first = pageView.viewport.convertToViewportPoint(fragment.rect[0], fragment.rect[1]);
      const second = pageView.viewport.convertToViewportPoint(fragment.rect[2], fragment.rect[3]);
      const mark = document.createElement('span');
      mark.className = 'original-search-highlight search-fragment-highlight';
      mark.style.left = `${Math.min(first[0], second[0])}px`;
      mark.style.top = `${Math.min(first[1], second[1])}px`;
      mark.style.width = `${Math.abs(second[0] - first[0])}px`;
      mark.style.height = `${Math.abs(second[1] - first[1])}px`;
      layer.append(mark);
    }
    const ocrPage = this.pages.find(page => page.pageIndex === pageIndex && page.cameFromOCR && page.ocrLines?.length);
    if (this.searchQuery && ocrPage) {
      const width = pageView.div.clientWidth;
      const height = pageView.div.clientHeight;
      for (const box of ocrSearchBoxes(ocrPage.ocrLines, this.searchQuery)) {
        const [x0, y0, x1, y1] = rotateNormalizedBox(box, this.rotation);
        const mark = document.createElement('span');
        mark.className = 'original-search-highlight';
        mark.style.left = `${x0 * width}px`;
        mark.style.top = `${y0 * height}px`;
        mark.style.width = `${Math.max(1, (x1 - x0) * width)}px`;
        mark.style.height = `${Math.max(1, (y1 - y0) * height)}px`;
        layer.append(mark);
      }
      if (layer.childElementCount) pageView.div.append(layer);
      return;
    }
    const textLayer = pageView.div.querySelector('.ocr-text-layer, .textLayer:not(.ocr-replaced-text-layer)');
    if (!this.searchQuery || !textLayer) {
      if (layer.childElementCount) pageView.div.append(layer);
      return;
    }
    const walker = document.createTreeWalker(textLayer, NodeFilter.SHOW_TEXT);
    const projection = [];
    const positions = [];
    let node;
    while ((node = walker.nextNode())) {
      const value = node.nodeValue || '';
      for (let offset = 0; offset < value.length;) {
        const codePoint = value.codePointAt(offset);
        const character = String.fromCodePoint(codePoint);
        const nextOffset = offset + character.length;
        const folded = character.normalize('NFKD').toLocaleLowerCase('zh-CN');
        for (const scalar of folded) {
          if (!/[\p{L}\p{N}]/u.test(scalar)) continue;
          projection.push(scalar);
          positions.push({ node, start: offset, end: nextOffset });
        }
        offset = nextOffset;
      }
    }
    const needle = [...this.searchQuery.normalize('NFKD').toLocaleLowerCase('zh-CN')].filter(character => /[\p{L}\p{N}]/u.test(character)).join('');
    const haystack = projection.join('');
    if (!needle || !haystack.includes(needle)) {
      if (layer.childElementCount) pageView.div.append(layer);
      return;
    }
    const pageBounds = pageView.div.getBoundingClientRect();
    let start = 0;
    while ((start = haystack.indexOf(needle, start)) >= 0) {
      const first = positions[start];
      const last = positions[start + needle.length - 1];
      const range = document.createRange();
      range.setStart(first.node, first.start);
      range.setEnd(last.node, last.end);
      for (const rectangle of range.getClientRects()) {
        if (rectangle.width < 1 || rectangle.height < 1) continue;
        const mark = document.createElement('span');
        mark.className = 'original-search-highlight';
        mark.style.left = `${rectangle.left - pageBounds.left}px`;
        mark.style.top = `${rectangle.top - pageBounds.top}px`;
        mark.style.width = `${rectangle.width}px`;
        mark.style.height = `${rectangle.height}px`;
        layer.append(mark);
      }
      start += needle.length;
    }
    if (layer.childElementCount) pageView.div.append(layer);
  }
}

/** Preserve physical lines for TOC/title matching while applying the same
 * width, CJK-space and punctuation normalization used by the text index. */
function normalizePageText(value = '') {
  return String(value).replace(/\r\n?/g, '\n')
    .split('\n')
    .map(line => normalizeText(line))
    .filter(Boolean)
    .join('\n');
}

function normalizeSelectedText(value = '') {
  return normalizeText(value).replace(/(?<![-—])\n/g, ' ').replace(/\s+/g, ' ').trim();
}

function clientRectanglesOverlap(left, right) {
  return left.left < right.right && left.right > right.left && left.top < right.bottom && left.bottom > right.top;
}

function clientIntersectionArea(left, right) {
  const width = Math.max(0, Math.min(left.right, right.right) - Math.max(left.left, right.left));
  const height = Math.max(0, Math.min(left.bottom, right.bottom) - Math.max(left.top, right.top));
  return width * height;
}

function deduplicateFragments(fragments = []) {
  const result = [];
  const keys = new Set();
  for (const fragment of fragments) {
    if (!Number.isInteger(fragment.pageIndex) || !Array.isArray(fragment.rect) || fragment.rect.length !== 4) continue;
    const rect = fragment.rect.map(Number);
    if (rect.some(value => !Number.isFinite(value)) || rect[2] - rect[0] < .2 || rect[3] - rect[1] < .2) continue;
    const key = `${fragment.pageIndex}:${rect.map(value => Math.round(value * 4)).join(':')}`;
    if (keys.has(key)) continue;
    keys.add(key);
    result.push({ pageIndex: fragment.pageIndex, rect });
  }
  return result;
}

function distanceToClientRect(clientX, clientY, rectangle) {
  const dx = clientX < rectangle.left ? rectangle.left - clientX : clientX > rectangle.right ? clientX - rectangle.right : 0;
  const dy = clientY < rectangle.top ? rectangle.top - clientY : clientY > rectangle.bottom ? clientY - rectangle.bottom : 0;
  return dx * dx + dy * dy;
}

function bigramOverlap(left, right) {
  if (left.length < 2 || right.length < 2) return left === right ? 1 : 0;
  const grams = new Set(Array.from({ length: left.length - 1 }, (_, index) => left.slice(index, index + 2)));
  let hits = 0;
  for (let index = 0; index < right.length - 1; index += 1) if (grams.has(right.slice(index, index + 2))) hits += 1;
  return hits / Math.max(grams.size, 1);
}
