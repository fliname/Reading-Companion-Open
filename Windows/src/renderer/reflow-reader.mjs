// reflow-reader.mjs
// HTML-based paginated book reader for EPUB content (reflowable books).
// Port of ReflowReaderHTML.swift + ReflowReaderView.swift for Electron.
//
// Uses an iframe (loaded via srcdoc) to host the reflow HTML, which needs its
// own DOM context for the multi-column paginated layout. The parent
// (ReflowReader) sends commands to the iframe via postMessage; the iframe
// reports navigation/selection events back via postMessage.

function attributeEscaped(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function replaceAll(str, find, repl) {
  return str.split(find).join(repl);
}

// Shared reader generated from the macOS HTML; the bridge uses Electron messages.
import { TEMPLATE } from './reflow-template.mjs';

/**
 * Build the full reflow HTML document for a book.
 * Port of ReflowReaderHTML.make(for:).
 *
 * @param {object} book - A ReflowBook object with `title` (string) and
 *   `sections` (array of { id, resourcePath, title, html, startPageIndex }).
 * @returns {string} The complete HTML document string.
 */
export function makeReflowHTML(book) {
  const list = book && book.sections ? book.sections : [];
  const sections = list.map(section =>
    '<section class="book-section" id="' + attributeEscaped(section.id) +
    '" data-location="' + attributeEscaped(String(section.startPageIndex == null ? 0 : section.startPageIndex)) +
    '">\n  ' + (section.html || '') + '\n</section>'
  ).join('\n');

  const pathMap = {};
  for (const section of list) {
    pathMap[String(section.resourcePath || '').toLowerCase()] = section.id;
  }
  const pathMapJSON = JSON.stringify(pathMap);

  let html = TEMPLATE;
  html = replaceAll(html, '__BOOK_TITLE__', attributeEscaped(book && book.title || ''));
  html = replaceAll(html, '__BOOK_SECTIONS__', sections);
  html = replaceAll(html, '__SECTION_PATHS__', pathMapJSON);
  return html;
}

/**
 * HTML-based paginated book reader for EPUB content.
 *
 * Loads a ReflowBook into an iframe (via srcdoc) that hosts a multi-column
 * CSS paginated layout. Commands are sent to the iframe via postMessage;
 * navigation and selection events are received via postMessage.
 *
 * Port of ReflowReaderView.swift (Coordinator + NSViewRepresentable).
 */
export class ReflowReader {
  /**
   * @param {HTMLElement} container - The element that will host the iframe.
   */
  constructor(container) {
    this.container = container;

    this.iframe = document.createElement('iframe');
    this.iframe.setAttribute('aria-label', 'Book content');
    this.iframe.setAttribute('title', 'Reflow Reader');
    this.iframe.style.cssText =
      'width:100%;height:100%;border:0;display:block;background:transparent;';

    this._ready = false;
    this._pendingCommands = [];
    this._textRequests = new Map(); // id -> { resolve, reject, timer }
    this._idCounter = 0;
    this._navigationCallback = null;
    this._selectionCallback = null;
    this._markCallback = null;
    this._readyTimer = 0;
    this._messageHandler = this._onMessage.bind(this);

    window.addEventListener('message', this._messageHandler);
    this.container.appendChild(this.iframe);
  }

  /**
   * Load a ReflowBook into the reader. Replaces any previously loaded book.
   * @param {object} reflowBook - A ReflowBook with title and sections array.
   */
  loadBook(reflowBook) {
    this._ready = false;
    this._pendingCommands = [];
    clearTimeout(this._readyTimer);

    // Reject any pending text-for-page-range requests from the previous book.
    for (const { reject, timer } of this._textRequests.values()) {
      clearTimeout(timer);
      reject(new Error('Book reloaded'));
    }
    this._textRequests.clear();

    const html = makeReflowHTML(reflowBook);
    this.iframe.srcdoc = html;

    // Fallback: if the ready signal never arrives (e.g. JS error), flush
    // pending commands after 2s so the reader is still usable.
    this._readyTimer = setTimeout(() => {
      if (!this._ready) {
        this._ready = true;
        for (const cmd of this._pendingCommands) cmd();
        this._pendingCommands = [];
      }
    }, 2000);
  }

  /**
   * Handle messages from the iframe.
   * @private
   */
  _onMessage(event) {
    if (event.source !== this.iframe.contentWindow) return;
    const data = event.data || {};
    switch (data.type) {
      case 'reader:ready':
        clearTimeout(this._readyTimer);
        this._ready = true;
        for (const cmd of this._pendingCommands) cmd();
        this._pendingCommands = [];
        break;
      case 'reader:navigation':
        if (this._ready && data.initialized && this._navigationCallback) {
          this._navigationCallback({
            location: data.location,
            pageNumber: data.pageNumber,
            pageCount: data.pageCount,
            spreadCount: data.spreadCount,
            position: data.position,
            layoutRevision: data.layoutRevision
          });
        }
        break;
      case 'reader:selection':
        if (this._selectionCallback) {
          // When there is no valid selection, the payload is empty.
          this._selectionCallback(data.text ? data : null);
        }
        break;
      case 'reader:mark':
        if (this._markCallback && data.id) this._markCallback(data);
        break;
      case 'reader:textForPageRangeResult': {
        const req = this._textRequests.get(data.id);
        if (req) {
          this._textRequests.delete(data.id);
          clearTimeout(req.timer);
          req.resolve(data.result);
        }
        break;
      }
    }
  }

  /**
   * Send a command to the iframe, queuing it if the iframe is not ready yet.
   * @private
   */
  _sendWhenReady(fn) {
    if (this._ready) {
      fn();
    } else {
      this._pendingCommands.push(fn);
    }
  }

  /**
   * Post a message to the iframe content window.
   * @private
   */
  _post(message) {
    this._sendWhenReady(() => {
      this.iframe.contentWindow?.postMessage(message, '*');
    });
  }

  /**
   * Set the zoom scale (0.65 - 2.25).
   * @param {number} value
   */
  configure({ scale = 1, count = 1, position = null, location = 0, legacyPage = null } = {}) {
    this._post({ type: 'reader:configure', scale, count, position, location, legacyPage });
  }

  goToAnchor(anchor) {
    this._post({ type: 'reader:goToAnchor', anchor: { sectionID: anchor.sectionID, offset: anchor.offset ?? anchor.startOffset ?? anchor.start ?? 0 } });
  }

  goToPage(page) { this._post({ type: 'reader:goToPage', page }); }

  resolveReferences(references) { return this._request('reader:resolveReferences', { references }); }

  _request(type, payload) {
    const id = 'r' + (this._idCounter++).toString(36);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this._textRequests.delete(id); reject(new Error(type + ' timed out')); }, 10000);
      this._textRequests.set(id, { resolve, reject, timer });
      this._post({ type, id, ...payload });
    });
  }

  setScale(value) {
    const bounded = Math.min(Math.max(value, 0.65), 2.25);
    this._post({ type: 'reader:setScale', value: bounded });
  }

  /**
   * Set the spread count (1 = single page, 2 = two pages).
   * @param {number} count
   */
  setSpreadCount(count) {
    this._post({ type: 'reader:setSpreadCount', count: count === 2 ? 2 : 1 });
  }

  /**
   * Turn the page by `direction` (-1 = back, 1 = forward).
   * @param {number} direction
   */
  turn(direction) {
    this._post({ type: 'reader:turn', direction: direction >= 0 ? 1 : -1 });
  }

  /**
   * Navigate to a location (page index).
   * @param {number} location
   */
  goToLocation(location) {
    this._post({ type: 'reader:goToLocation', location });
  }

  /**
   * Retrieve the text content for a range of pages (0-indexed).
   * Resolves with { pages: string[], pageCount, startPage, endPage }.
   * @param {number} start - Start page index (0-indexed).
   * @param {number} end - End page index (0-indexed, inclusive).
   * @returns {Promise<{pages: string[], pageCount: number, startPage: number, endPage: number}>}
   */
  textForPageRange(start, end) {
    const id = 'r' + (this._idCounter++).toString(36);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this._textRequests.delete(id);
        reject(new Error('textForPageRange timed out'));
      }, 5000);
      this._textRequests.set(id, { resolve, reject, timer });
      this._post({ type: 'reader:textForPageRange', id, start, end });
    });
  }

  /**
   * Apply highlight marks to the book.
   * @param {Array} marks - Array of mark objects: { id, sectionID, start, end, kind, tint }.
   */
  applyMarks(marks) {
    this._post({ type: 'reader:applyMarks', marks: marks || [] });
  }

  /**
   * Apply character name highlighting.
   * @param {Array} characters - Array of { id, names: string[], color: string }.
   */
  applyCharacters(characters) {
    this._post({ type: 'reader:applyCharacters', characters: characters || [] });
  }

  /**
   * Highlight search results matching `query`.
   * @param {string} query
   */
  find(query) {
    this._post({ type: 'reader:find', query: query || '' });
  }

  /**
   * Navigate to a specific search result.
   * @param {object} result - { query, sectionID, ratio, snippet, fallbackLocation }.
   */
  goToSearch(result) {
    this._post({
      type: 'reader:goToSearch',
      query: result.query || '',
      sectionID: result.sectionID,
      ratio: result.ratio,
      snippet: result.snippet || '',
      fallbackLocation: result.fallbackLocation == null ? 0 : result.fallbackLocation
    });
  }

  /**
   * Clear the current text selection in the iframe.
   */
  clearSelection() {
    this._post({ type: 'reader:clearSelection' });
  }

  /**
   * Register a callback for navigation (page/location) changes.
   * @param {Function} callback - Called with { location, pageNumber, pageCount, spreadCount }.
   */
  onNavigation(callback) {
    this._navigationCallback = callback;
  }

  /**
   * Register a callback for text selection events.
   * @param {Function} callback - Called with the selection payload, or null when
   *   the selection is cleared/empty. The payload has: text, sectionID, location,
   *   start, end, prefix, suffix, x, y, width, height.
   */
  onSelection(callback) {
    this._selectionCallback = callback;
  }

  /** Register a callback for clicks on an existing reflow highlight. */
  onMark(callback) {
    this._markCallback = callback;
  }

  /**
   * Clean up: remove event listeners, reject pending requests, remove the iframe.
   */
  destroy() {
    window.removeEventListener('message', this._messageHandler);
    clearTimeout(this._readyTimer);
    for (const { reject, timer } of this._textRequests.values()) {
      clearTimeout(timer);
      reject(new Error('ReflowReader destroyed'));
    }
    this._textRequests.clear();
    this._pendingCommands = [];
    this._navigationCallback = null;
    this._selectionCallback = null;
    this._markCallback = null;
    this.iframe.remove();
  }
}
