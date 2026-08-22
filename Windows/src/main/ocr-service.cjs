const path = require('node:path');
const { createWorker, OEM, PSM } = require('tesseract.js');

let workerPromise = null;
let activeJob = null;
const DEFAULT_LANGUAGES = ['chi_sim', 'eng'];

function normalizeOCRText(value = '') {
  let text = String(value).normalize('NFKC')
    .replace(/[\u200b\u2060]/g, '')
    .replace(/\u00a0/g, ' ');
  let previous;
  do {
    previous = text;
    text = text.replace(/([\p{Script=Han}，。！？；：“”‘’（）【】])\s+([\p{Script=Han}，。！？；：“”‘’（）【】])/gu, '$1$2');
  } while (text !== previous);
  text = text
    .replace(/\s+([，。！？；：、）】])/g, '$1')
    .replace(/([（【])\s+/g, '$1');
  // OCR sometimes spaces every Latin letter: “re p re sen ta tion”. Join
  // only short alphabetic pieces, while retaining ordinary word boundaries.
  text = text.replace(/\b(?:[A-Za-z]{1,3}\s+){2,}[A-Za-z]{1,4}\b/g, run => {
    const pieces = run.trim().split(/\s+/);
    return pieces.every(piece => piece.length <= 3) ? pieces.join('') : run;
  });
  return text.replace(/[ \t]+/g, ' ').replace(/ *\n */g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}

function overlapRatio(left, right) {
  const x1 = Math.max(left.x0, right.x0);
  const y1 = Math.max(left.y0, right.y0);
  const x2 = Math.min(left.x1, right.x1);
  const y2 = Math.min(left.y1, right.y1);
  const intersection = Math.max(0, x2 - x1) * Math.max(0, y2 - y1);
  const smaller = Math.min((left.x1 - left.x0) * (left.y1 - left.y0), (right.x1 - right.x0) * (right.y1 - right.y0));
  return smaller > 0 ? intersection / smaller : 0;
}

function deduplicateLines(lines) {
  const kept = [];
  for (const candidate of lines.sort((a, b) => b.confidence - a.confidence)) {
    const duplicate = kept.some(existing => overlapRatio(existing.bbox, candidate.bbox) > 0.7
      && (existing.text.includes(candidate.text) || candidate.text.includes(existing.text)));
    if (!duplicate) kept.push(candidate);
  }
  return kept.sort((a, b) => {
    const height = Math.max(a.bbox.y1 - a.bbox.y0, b.bbox.y1 - b.bbox.y0);
    return Math.abs(a.bbox.y0 - b.bbox.y0) < height * 0.55 ? a.bbox.x0 - b.bbox.x0 : a.bbox.y0 - b.bbox.y0;
  });
}

function linesFromTSV(tsv = '') {
  const groups = new Map();
  const rows = String(tsv).split(/\r?\n/);
  for (const row of rows.slice(1)) {
    const columns = row.split('\t');
    if (columns.length < 12 || Number(columns[0]) !== 5) continue;
    const text = normalizeOCRText(columns.slice(11).join('\t'));
    const left = Number(columns[6]);
    const top = Number(columns[7]);
    const width = Number(columns[8]);
    const height = Number(columns[9]);
    const confidence = Number(columns[10]);
    if (!text || ![left, top, width, height].every(Number.isFinite) || width <= 0 || height <= 0) continue;
    const key = columns.slice(1, 5).join(':');
    const word = { text, confidence: Number.isFinite(confidence) ? confidence : 0, bbox: { x0: left, y0: top, x1: left + width, y1: top + height } };
    const group = groups.get(key) || [];
    group.push(word);
    groups.set(key, group);
  }
  return [...groups.values()].map(words => ({
    text: normalizeOCRText(words.map(word => word.text).join(' ')),
    confidence: words.reduce((total, word) => total + word.confidence, 0) / Math.max(words.length, 1),
    words,
    bbox: {
      x0: Math.min(...words.map(word => word.bbox.x0)),
      y0: Math.min(...words.map(word => word.bbox.y0)),
      x1: Math.max(...words.map(word => word.bbox.x1)),
      y1: Math.max(...words.map(word => word.bbox.y1))
    }
  })).filter(line => line.text);
}

async function getWorker(langPath, onProgress) {
  if (!workerPromise) {
    workerPromise = createWorker(DEFAULT_LANGUAGES, OEM.LSTM_ONLY, {
      langPath,
      gzip: true,
      logger: message => onProgress?.(message)
    }).then(async worker => {
      await worker.setParameters({
        tessedit_pageseg_mode: PSM.AUTO,
        preserve_interword_spaces: '1',
        user_defined_dpi: '220'
      });
      return worker;
    }).catch(error => {
      workerPromise = null;
      throw error;
    });
  }
  return workerPromise;
}

function topDown(lines) {
  return [...lines].sort((a, b) => Math.abs(a.bbox.y0 - b.bbox.y0) > Math.max(a.bbox.y1 - a.bbox.y0, b.bbox.y1 - b.bbox.y0) * .45 ? a.bbox.y0 - b.bbox.y0 : a.bbox.x0 - b.bbox.x0);
}

function legacyTOCOrder(lines) {
  if (lines.length < 4) return topDown(lines);
  const width = Math.max(...lines.map(line => line.bbox.x1), 1);
  const vertical = lines.filter(line => line.bbox.y1 - line.bbox.y0 > (line.bbox.x1 - line.bbox.x0) * 1.35);
  const candidates = [topDown(lines)];
  if (vertical.length >= 3 && vertical.length / lines.length >= .35) {
    const horizontal = lines.filter(line => !vertical.includes(line));
    candidates.push([...topDown(horizontal), ...vertical.sort((a, b) => b.bbox.x0 - a.bbox.x0 || a.bbox.y0 - b.bbox.y0)]);
  } else {
    const spanning = lines.filter(line => line.bbox.x1 - line.bbox.x0 >= width * .68);
    const body = lines.filter(line => !spanning.includes(line));
    const left = body.filter(line => (line.bbox.x0 + line.bbox.x1) / 2 < width * .5);
    const right = body.filter(line => !left.includes(line));
    if (left.length >= 2 && right.length >= 2) candidates.push([...topDown(spanning), ...topDown(left), ...topDown(right)]);
  }
  return candidates.sort((a, b) => tocLayoutScore(b) - tocLayoutScore(a))[0];
}

function tocLayoutScore(lines) {
  const pages = lines.flatMap(line => {
    const match = line.text.match(/(?:^|[\/／.·…:\s])\s*[（(\[【{]?\s*(\d{1,4})\s*[）)\]】}]?\s*$/);
    return match ? [Number(match[1])] : [];
  });
  const monotonic = pages.slice(1).filter((page, index) => page >= pages[index]).length;
  return pages.length * 4 + (pages.length > 1 ? monotonic / (pages.length - 1) * 8 : 0);
}

async function recognize({ image, rectangle, jobId, legacyLayout = false }, resourcesPath, onProgress) {
  const worker = await getWorker(path.join(resourcesPath, 'tessdata'), onProgress);
  activeJob = jobId;
  const options = rectangle ? { rectangle } : {};
  const result = await worker.recognize(Buffer.from(image), options, { text: true, blocks: true, hocr: false, tsv: true });
  if (activeJob !== jobId) throw new Error('OCR 已取消。');
  const rawLines = [];
  for (const block of result.data.blocks || []) {
    for (const paragraph of block.paragraphs || []) {
      for (const line of paragraph.lines || []) {
        const text = normalizeOCRText(line.text || '');
        const words = (line.words || []).flatMap(word => {
          const wordText = normalizeOCRText(word.text || '');
          return wordText && word.bbox ? [{ text: wordText, confidence: word.confidence || 0, bbox: word.bbox }] : [];
        });
        if (text) rawLines.push({ text, confidence: line.confidence || 0, bbox: line.bbox, words });
      }
    }
  }
  const coordinateLines = rawLines.length ? rawLines : linesFromTSV(result.data.tsv);
  const lines = deduplicateLines(coordinateLines);
  const ordered = legacyLayout ? legacyTOCOrder(lines) : lines;
  return {
    text: normalizeOCRText(ordered.length ? ordered.map(line => line.text).join('\n') : result.data.text),
    confidence: result.data.confidence || 0,
    lines
  };
}

function cancel(jobId) {
  if (activeJob !== jobId) return false;
  activeJob = null;
  return true;
}

async function terminate() {
  if (!workerPromise) return;
  try { (await workerPromise).terminate(); } catch {}
  workerPromise = null;
  activeJob = null;
}

module.exports = { recognize, cancel, terminate, normalizeOCRText, deduplicateLines, legacyTOCOrder, linesFromTSV, DEFAULT_LANGUAGES };
