const TOKEN_RE = /[\p{Script=Han}]|[A-Za-z0-9_]+/gu;

export const DEPTHS = {
  economical: { label: '节省', contextLimit: 6, historyLimit: 4, outputLimit: 1500, reasoningEffort: 'low', budgets: { explanation: 3200, standard: 5000, context: 6500 } },
  balanced: { label: '均衡', contextLimit: 9, historyLimit: 8, outputLimit: 3000, reasoningEffort: 'low', budgets: { explanation: 4800, standard: 7200, context: 9600 } },
  deep: { label: '深读', contextLimit: 14, historyLimit: 12, outputLimit: 5000, reasoningEffort: 'medium', budgets: { explanation: 6500, standard: 10000, context: 14000 } }
};

export function normalizeText(source = '') {
  let text = String(source).normalize('NFKC').replace(/[\u200b\u2060]/g, '').replace(/\u00a0/g, ' ');
  let previous;
  do {
    previous = text;
    text = text.replace(/([\p{Script=Han}，。！？；：“”‘’（）【】])\s+([\p{Script=Han}，。！？；：“”‘’（）【】])/gu, '$1$2');
  } while (text !== previous);
  text = text.replace(/(?<=\p{L})-\s*\n\s*(?=\p{L})/gu, '');
  text = text.replace(/(?<=[。！？.!?；;：:])\s*\n\s*/g, '\n');
  text = text.replace(/(?<![。！？.!?；;：:])\s*\n\s*(?=\S)/g, ' ');
  return text.replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
}

/** Match visible text while ignoring OCR-inserted spaces, punctuation and width variants. */
export function searchMatchRanges(query = '', source = '') {
  const project = value => {
    const text = [];
    const positions = [];
    for (let offset = 0; offset < value.length;) {
      const codePoint = value.codePointAt(offset);
      const character = String.fromCodePoint(codePoint);
      const nextOffset = offset + character.length;
      const folded = character.normalize('NFKD').toLocaleLowerCase('zh-CN');
      for (const scalar of folded) {
        if (!/[\p{L}\p{N}]/u.test(scalar)) continue;
        text.push(scalar);
        positions.push({ start: offset, end: nextOffset });
      }
      offset = nextOffset;
    }
    return { text: text.join(''), positions };
  };
  const haystack = project(String(source));
  const needle = project(String(query)).text;
  if (!needle || !haystack.text) return [];
  const ranges = [];
  let cursor = 0;
  while ((cursor = haystack.text.indexOf(needle, cursor)) >= 0) {
    const first = haystack.positions[cursor];
    const last = haystack.positions[cursor + needle.length - 1];
    ranges.push({ start: first.start, end: last.end });
    cursor += needle.length;
  }
  return ranges;
}

export function estimatedTokens(text = '') {
  let units = 0;
  for (const token of text.match(TOKEN_RE) || []) units += /[\p{Script=Han}]/u.test(token) ? 1 : Math.max(1, token.length / 4);
  return Math.max(text ? 1 : 0, Math.ceil(units));
}

function outlinePaths(outline) {
  const result = [];
  const stack = [];
  outline.forEach((entry, index) => {
    const level = Math.min(Math.max(Number(entry.level) || 0, 0), stack.length);
    stack.splice(level);
    stack.push(entry.title);
    result[index] = [...stack];
  });
  return result;
}

export function chapterPathForPage(pageIndex, outline = [], selectedText = '') {
  if (!outline.length) return [];
  const paths = outlinePaths(outline);
  const eligible = outline.map((entry, index) => ({ entry, index }))
    .filter(item => Number(item.entry.pageIndex) <= pageIndex);
  if (!eligible.length) return [];
  const samePage = eligible.filter(item => Number(item.entry.pageIndex) === pageIndex);
  if (samePage.length > 1 && selectedText) {
    const compact = normalizeText(selectedText).replace(/\s/g, '').toLowerCase();
    const matched = [...samePage].reverse().find(item => compact.includes(normalizeText(item.entry.title).replace(/\s/g, '').toLowerCase()));
    if (matched) return paths[matched.index];
  }
  // Content before the first child heading on a shared page belongs to its
  // parent chapter, not to the last child on that page.
  const last = eligible.at(-1);
  if (samePage.length && last.entry.level > 0 && !selectedText) return paths[last.index].slice(0, -1);
  return paths[last.index];
}

export function makeChunks(pages, outline = [], targetLength = 1200, overlap = 180) {
  const chunks = [];
  for (const page of pages) {
    const source = normalizeText(page.text);
    if (!source) continue;
    const path = chapterPathForPage(page.pageIndex, outline);
    let start = 0;
    while (start < source.length) {
      let end = Math.min(source.length, start + targetLength);
      if (end < source.length) {
        const boundary = Math.max(source.lastIndexOf('。', end), source.lastIndexOf('\n', end), source.lastIndexOf('. ', end));
        if (boundary > start + targetLength * 0.55) end = boundary + 1;
      }
      const text = source.slice(start, end).trim();
      if (text) chunks.push({ id: crypto.randomUUID(), pageIndex: page.pageIndex, chapterTitle: path.at(-1) || null, chapterPath: path, text });
      if (end >= source.length) break;
      start = Math.max(start + 1, end - overlap);
    }
  }
  return chunks;
}

function frequencies(text) {
  const map = new Map();
  for (const token of (normalizeText(text).toLowerCase().match(TOKEN_RE) || [])) map.set(token, (map.get(token) || 0) + 1);
  return map;
}

export function retrieve(query, chunks, limit = 8) {
  const queryTerms = frequencies(query);
  if (!queryTerms.size) return chunks.slice(0, limit);
  const documentFrequency = new Map();
  chunks.forEach(chunk => new Set(frequencies(chunk.text).keys()).forEach(token => documentFrequency.set(token, (documentFrequency.get(token) || 0) + 1)));
  const queryCompact = normalizeText(query).replace(/\s/g, '').toLowerCase();
  return chunks.map(chunk => {
    const terms = frequencies(chunk.text);
    let score = 0;
    for (const [term, count] of queryTerms) {
      const frequency = terms.get(term) || 0;
      if (!frequency) continue;
      score += Math.log(1 + (chunks.length + 0.5) / ((documentFrequency.get(term) || 0) + 0.5)) * Math.min(3, frequency) * Math.min(1.6, 1 + Math.log(count));
    }
    if (chunk.chapterPath?.some(title => queryCompact.includes(normalizeText(title).replace(/\s/g, '').toLowerCase()))) score += 7;
    if (queryCompact.length >= 8 && normalizeText(chunk.text).replace(/\s/g, '').toLowerCase().includes(queryCompact.slice(0, 160))) score += 12;
    return { chunk, score };
  }).filter(item => item.score > 0).sort((a, b) => b.score - a.score || a.chunk.pageIndex - b.chunk.pageIndex).slice(0, limit).map(item => item.chunk);
}

export function retrieveForReading(query, focusPageIndex, chunks, { limit = 9, wholeBook = false, scope = 'standard' } = {}) {
  let pool = chunks;
  if (!wholeBook && Number.isInteger(focusPageIndex)) {
    const focus = retrieve(query, chunks.filter(chunk => chunk.pageIndex === focusPageIndex), 1)[0]
      || chunks.findLast(chunk => chunk.pageIndex <= focusPageIndex);
    if (focus?.chapterPath?.length) {
      const path = focus.chapterPath;
      const hasDescendants = chunks.some(chunk => chunk.chapterPath?.length > path.length && path.every((part, index) => chunk.chapterPath[index] === part));
      const scopePath = hasDescendants || path.length === 1 ? path : path.slice(0, -1);
      pool = chunks.filter(chunk => scopePath.every((part, index) => chunk.chapterPath?.[index] === part));
    } else pool = chunks.filter(chunk => Math.abs(chunk.pageIndex - focusPageIndex) <= 3);
  }
  const seedCount = scope === 'explanation' ? (wholeBook ? 4 : 3) : scope === 'context' ? (wholeBook ? 10 : 7) : (wholeBook ? 7 : 5);
  const radius = scope === 'context' ? 2 : scope === 'standard' ? 1 : 0;
  const seeds = retrieve(query, pool, seedCount);
  const selected = new Map();
  for (const seed of seeds) {
    const index = chunks.findIndex(chunk => chunk.id === seed.id);
    for (let offset = -radius; offset <= radius; offset += 1) {
      const candidate = chunks[index + offset];
      if (candidate && (wholeBook || pool.some(item => item.id === candidate.id))) selected.set(candidate.id, candidate);
    }
  }
  if (Number.isInteger(focusPageIndex)) {
    for (const candidate of pool) if (Math.abs(candidate.pageIndex - focusPageIndex) <= radius) selected.set(candidate.id, candidate);
  }
  return [...selected.values()].sort((a, b) => a.pageIndex - b.pageIndex).slice(0, limit);
}

export function prepareForPrompt(chunks, tokenBudget) {
  let remaining = tokenBudget;
  const seen = new Set();
  const result = [];
  for (const source of chunks) {
    let text = source.text;
    const key = normalizeText(text).toLowerCase();
    if (!key || seen.has(key)) continue;
    seen.add(key);
    const metadata = 12 + estimatedTokens(source.chapterTitle || '');
    if (remaining - metadata < 80) break;
    const available = remaining - metadata;
    if (estimatedTokens(text) > available) text = text.slice(0, Math.max(80, Math.floor(text.length * available / estimatedTokens(text))));
    result.push({ ...source, text });
    remaining -= metadata + estimatedTokens(text);
  }
  return result;
}

export function renderMarkdown(title, pages, outline = []) {
  const headings = new Map();
  outline.forEach(entry => headings.set(entry.pageIndex, [...(headings.get(entry.pageIndex) || []), entry]));
  const lines = [`# ${title}`, ''];
  for (const page of pages) {
    for (const entry of headings.get(page.pageIndex) || []) lines.push(`${'#'.repeat(Math.min(6, Math.max(2, entry.level + 2)))} ${entry.title}`, '');
    if (page.text) lines.push(`<!-- P${page.pageIndex + 1} -->`, normalizeText(page.text), '');
  }
  return lines.join('\n');
}

export function promptContext(chunks) {
  return chunks.map(chunk => `[P${chunk.pageIndex + 1}${chunk.chapterPath?.length ? ` · ${chunk.chapterPath.join(' › ')}` : ''}]\n${chunk.text}`).join('\n\n');
}
