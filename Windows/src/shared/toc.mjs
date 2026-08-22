const romanValues = { i: 1, v: 5, x: 10, l: 50, c: 100, d: 500, m: 1000 };

export function comparisonKey(value = '') {
  return value.normalize('NFKC').toLowerCase().replace(/[^\p{L}\p{N}\p{Script=Han}]/gu, '');
}

export function removeSpuriousCJKSpaces(value = '') {
  let result = value.normalize('NFKC').replace(/[\u200b\u2060]/g, ' ').replace(/\u00a0/g, ' ');
  let previous;
  do {
    previous = result;
    result = result.replace(/([\p{Script=Han}，。！？；：“”‘’（）【】])\s+([\p{Script=Han}，。！？；：“”‘’（）【】])/gu, '$1$2');
  } while (result !== previous);
  return result.replace(/\s+([，。！？；：、）】])/g, '$1').replace(/([（【])\s+/g, '$1');
}

export function normalizeTOCInput(source = '') {
  let lines = source.normalize('NFKC')
    .replace(/\u00a0/g, ' ')
    .replace(/[\u200b\u2060]/g, '')
    .replace(/\r\n?/g, '\n')
    .split('\n')
    .map(joinSpacedTrailingDigits);
  const meaningful = lines.map((line, index) => ({ line: line.trim(), index })).filter(item => item.line);
  if (meaningful.length >= 2 && meaningful[0].line.startsWith('目') && /^[录錄]/.test(meaningful[1].line)) {
    lines[meaningful[0].index] = lines[meaningful[0].index].replace(/^\s*目\s*/, '');
    lines[meaningful[1].index] = lines[meaningful[1].index].replace(/^\s*[录錄]\s*/, '');
  }
  lines = lines.flatMap(line => {
    let cleaned = line
      .replace(/^\s*目\s+(?=\S.{0,160}(?:[/／]|\.{1,}|…|·)\s*\d{1,4}(?:\s|$))/, '')
      .replace(/(?<=\d)\s+[录錄]\s+(?=\S.{0,160}(?:[/／]|\.{1,}|…|·)\s*\d{1,4}(?:\s|$))/, ' ');
    if (cleaned !== line) cleaned = cleaned.replace(/((?:[/／]|(?<!\d)\.)\s*\d{1,4})\s+(?=\S)/g, '$1\n');
    return cleaned.split('\n');
  });
  return lines.join('\n');
}

function joinSpacedTrailingDigits(line) {
  return line.replace(/(?<!\d)((?:\d[ \t　]+){1,3}\d)[ \t　]*$/, match => match.replace(/\s/g, ''));
}

export function cleanEntryTitle(source = '') {
  let title = removeSpuriousCJKSpaces(source)
    .replace(/\s*([•·])\s*/g, '$1')
    .replace(/[.·…\s]+$/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  const patterns = [
    /^(第\s*[0-9一二三四五六七八九十百千零〇两]+\s*(?:部分|篇|部|卷|章|节))(?=\S)/,
    /^([上中下前后](?:篇|部|卷))(?=\S)/,
    /^(\d{1,3}(?:\.\d{1,3})+)(?=[\p{Script=Han}A-Za-z])/u,
    /^(\d{1,3})(?=[\p{Script=Han}A-Za-z])/u,
    /^([0-9一二三四五六七八九十百千零〇两]+[、．。)）])(?=\S)/
  ];
  for (const pattern of patterns) title = title.replace(pattern, '$1 ');
  return title;
}

export function parsePrintedPage(token = '') {
  const cleaned = token.toLowerCase().replace(/^\s*[\/／]?\s*p\.?\s*[\/／]?\s*/i, '').replace(/[()\[\]{}（）【】,，、:：/／.\s]/g, '');
  if (/^\d{1,4}$/.test(cleaned) && Number(cleaned) > 0) return { value: Number(cleaned), style: 'arabic' };
  if (!/^[ivxlcdm]{1,10}$/.test(cleaned)) return null;
  let total = 0;
  [...cleaned].forEach((character, index, values) => {
    const current = romanValues[character];
    total += index + 1 < values.length && current < romanValues[values[index + 1]] ? -current : current;
  });
  return total > 0 ? { value: total, style: 'roman' } : null;
}

function pageOnly(line) {
  if (!/^(?:[\/／]\s*)?(?:p\.?\s*)?(?:[\/／]\s*)?[（(\[【{]?\s*(?:\d{1,4}|[ivxlcdm]{1,10})\s*[）)\]】}]?$/i.test(line.trim())) return null;
  return parsePrintedPage(line);
}

function titleAndPage(line) {
  const match = line.match(/^(.{1,180}?)(?:(?<!\d)\.|\.{2,}|…+|·{2,}|[\/／]+|\s{2,}|[-—–]\s*|\s+)(?:p\.?\s*)?[（(\[【{]?\s*(\d{1,4}|[ivxlcdm]{1,10})\s*[）)\]】}]?\s*$/i);
  if (!match) return null;
  const page = parsePrintedPage(match[2]);
  const title = match[1].trim();
  return title && page ? { title, ...page } : null;
}

function isNoise(line) {
  return /^\[目录页 · PDF 物理页/.test(line) || /^--- 下一目录页/.test(line)
    || /^(?:目\s*[录錄次]|contents|table of contents|目録)$/i.test(line.trim());
}

function looksLikeEntryStart(title) {
  return /^(?:第.{1,30}(?:部分|篇|部|卷|章|节)|[上中下前后](?:篇|部|卷)|chapter\s+\S+|part\s+\S+|(?:\d+\.)*\d+\s+|序言|前言|引言|导言|导论|绪论|结语|后记|附录|参考文献|索引)/i.test(title);
}

function isPart(title) {
  return /^(?:第.{1,20}(?:部分|篇|部|卷)|[上中下前后](?:篇|部|卷)|part\s+\S+)/i.test(title);
}

function isUnpagedDivision(title) {
  return isPart(cleanEntryTitle(title)) && !titleAndPage(title);
}

function rawLevel(title, hasPart) {
  if (isPart(title)) return 0;
  if (/^(?:第.{1,30}章|chapter\s+\S+)/i.test(title)) return hasPart ? 1 : 0;
  if (/^第.{1,30}节/.test(title)) return hasPart ? 2 : 1;
  const numeric = title.match(/^\d+(?:\.\d+)*/)?.[0];
  if (numeric) return Math.min((numeric.match(/\./g) || []).length, 5);
  return 0;
}

function cleanLine(line) {
  return line.normalize('NFKC')
    .replace(/^\s*(?:目\s*[录錄次]|contents|table\s+of\s+contents)\s*(?=\S)/i, '')
    .replace(/[／/]+\s*(?=(?:p\.?\s*)?[（(\[【{]?\s*(?:\d{1,4}|[ivxlcdm]{1,10})\s*[）)\]】}]?\s*$)/i, ' ')
    .replace(/^[•●▪◆◇※*#]+\s*/, '')
    .replace(/[\t ]+/g, ' ')
    .trim();
}

function splitCombinedEntries(line) {
  if (line.length < 6) return [line];
  const marker = /(?<![\p{Script=Han}A-Za-z])(?=(?:第\s*[0-9一二三四五六七八九十百千零〇两]+\s*[篇部卷章节]|chapter\s+(?:\d+|[ivxlcdm]+)|part\s+(?:\d+|[ivxlcdm]+)|section\s+\d+(?:\.\d+)*|\d{1,3}(?:\.\d{1,3})+\s+|序言|前言|引言|导言|导论|绪论|结语|后记|附录|参考文献|索引))/giu;
  const positions = [...line.matchAll(marker)].map(match => match.index);
  if (positions.length < 2) {
    return line
      .replace(/((?:(?<!\d)\.|\.{2,}|…+|·{2,}|[\/／])\s*(?:\d{1,4}|[ivxlcdm]{1,10}))\s+(?=\S.{1,160}(?:(?<!\d)\.|\.{2,}|…+|·{2,}|[\/／])\s*(?:\d{1,4}|[ivxlcdm]{1,10})\s*$)/i, '$1\n')
      .split('\n').map(item => item.trim()).filter(Boolean);
  }
  if (positions[0] !== 0) positions.unshift(0);
  positions.push(line.length);
  return positions.slice(0, -1).map((start, index) => line.slice(start, positions[index + 1]).trim()).filter(Boolean);
}

function pairDetachedPageColumns(lines) {
  const result = [...lines];
  let index = 0;
  while (index < result.length) {
    if (!pageOnly(result[index])) { index += 1; continue; }
    const pageStart = index;
    let pageEnd = pageStart;
    while (pageEnd < result.length && pageOnly(result[pageEnd])) pageEnd += 1;
    const pageCount = pageEnd - pageStart;
    if (pageCount < 2) { index = pageEnd; continue; }
    let titleStart = pageStart;
    let ordinaryCount = 0;
    let valid = true;
    while (titleStart > 0 && ordinaryCount < pageCount) {
      titleStart -= 1;
      const candidate = result[titleStart];
      if (pageOnly(candidate) || titleAndPage(candidate) || candidate.length < 2 || candidate.length > 180) { valid = false; break; }
      if (!isUnpagedDivision(candidate)) ordinaryCount += 1;
    }
    if (!valid || ordinaryCount !== pageCount) { index = pageEnd; continue; }
    const titles = result.slice(titleStart, pageStart);
    const pages = result.slice(pageStart, pageEnd);
    let pageIndex = 0;
    const paired = titles.map(title => {
      if (isUnpagedDivision(title)) return title;
      return `${title} ${pages[pageIndex++]}`;
    });
    result.splice(titleStart, pageEnd - titleStart, ...paired);
    index = titleStart + paired.length;
  }
  return result;
}

export function parseAutomaticTOC(source = '') {
  const cleaned = normalizeTOCInput(source).split('\n').map(cleanLine).flatMap(splitCombinedEntries).filter(line => line && !isNoise(line));
  const lines = pairDetachedPageColumns(cleaned);
  const pending = [];
  let parsed = [];
  for (const line of lines) {
    if (isUnpagedDivision(line)) { parsed.push({ title: line, printedPage: null, pageStyle: null }); continue; }
    const lonePage = pageOnly(line);
    if (lonePage) {
      if (pending.length) parsed.push({ title: pending.shift(), printedPage: lonePage.value, pageStyle: lonePage.style });
      continue;
    }
    const complete = titleAndPage(line);
    if (complete) {
      let title = complete.title;
      if (!looksLikeEntryStart(title) && pending.length) title = `${pending.pop()} ${title}`;
      parsed.push({ title, printedPage: complete.value, pageStyle: complete.style });
      continue;
    }
    if (looksLikeEntryStart(line) || !pending.length) pending.push(line);
    else if (line.length <= 90) pending[pending.length - 1] += ` ${line}`;
    else pending.push(line);
  }
  parsed.push(...pending.map(title => ({ title, printedPage: null, pageStyle: null })));
  let next = null;
  for (let index = parsed.length - 1; index >= 0; index -= 1) {
    if (parsed[index].printedPage) next = { page: parsed[index].printedPage, style: parsed[index].pageStyle };
    else if (isUnpagedDivision(parsed[index].title) && next) {
      parsed[index].printedPage = next.page;
      parsed[index].pageStyle = next.style;
    }
  }
  const hasPart = parsed.some(item => isPart(item.title));
  const seen = new Set();
  return parsed.flatMap(item => {
    const title = cleanEntryTitle(item.title);
    if (title.length < 2 || title.length > 180 || (!item.printedPage && !looksLikeEntryStart(title))) return [];
    const key = `${comparisonKey(title)}|${item.printedPage ?? 'nil'}`;
    if (seen.has(key)) return [];
    seen.add(key);
    return [{ ...item, title, level: rawLevel(title, hasPart) }];
  });
}

export function parseManualTOC(titleSource = '', pageSource = '', restartAfter = 0) {
  const candidates = normalizeTOCInput(titleSource).split('\n').map((line, originalIndex) => manualCandidate(line, originalIndex)).filter(Boolean);
  const sequencePosition = preferredManualSequencePosition(candidates);
  let parsed = candidates.map(candidate => parseManualCandidate(candidate, sequencePosition)).filter(Boolean);
  parsed = reorderManualEntries(parsed);
  const inlineEntries = parsed.map(item => item.entry);
  if (pageSource.trim()) {
    const pages = parseManualPages(pageSource, inlineEntries.length, restartAfter);
    inlineEntries.forEach((entry, index) => {
      if (pages[index]) { entry.printedPage = pages[index]; entry.pageStyle = 'arabic'; }
    });
  }
  let next = null;
  for (let index = inlineEntries.length - 1; index >= 0; index -= 1) {
    if (inlineEntries[index].printedPage) next = inlineEntries[index].printedPage;
    else if (isUnpagedDivision(inlineEntries[index].title) && next) inlineEntries[index].printedPage = next;
  }
  const hasPart = inlineEntries.some(item => isPart(item.title));
  return inlineEntries.map(item => ({ ...item, level: Math.min(Math.max(item.level, rawLevel(item.title, hasPart)), 5) }));
}

function manualCandidate(line, originalIndex) {
  const halfWidth = line.normalize('NFKC');
  const level = Math.min((halfWidth.match(/^[ \t　]*/) || [''])[0].length, 5);
  let body = halfWidth.replace(/^[ \t　]+/, '').trim();
  if (!body || isNoise(body)) return null;
  body = body
    .replace(/(?<=\S)([（(\[【{]\s*(?:\d{1,4}|[ivxlcdm]{1,10})\s*[）)\]】}])\s*$/i, ' $1')
    .replace(/(?<=\S)(第\d{1,4}页)\s*$/, ' $1')
    .replace(/(?<![pP]\.)(?<=[^\d\s])(\d{1,4})\s*$/, ' $1')
    .replace(/^(\d{1,4})(?=第|[\p{Script=Han}A-Za-z])/u, '$1 ')
    .replace(/^(\d+(?:\.\d+)+)(?=[^\d.\s])/, '$1 ')
    .replace(/(?<=[^\dpP])\.(?=\s*\d{1,4}\s*$)/g, ' ')
    .replace(/(?:\.{2,}|…+|·{2,}|\||[\/／]+)/g, ' ')
    .replace(/^[•●▪◆◇※*#]+\s*/, '')
    .replace(/\s+/g, ' ')
    .trim();
  const tokens = body.split(' ').filter(Boolean);
  if (tokens.length < 2) return null;
  const numberIndices = tokens.map((token, index) => manualPageValue(token) ? index : -1).filter(index => index >= 0);
  if (!numberIndices.length) return null;
  return { originalIndex, level, tokens, numberIndices };
}

function manualPageValue(token = '') {
  let cleaned = token.normalize('NFKC').toLowerCase().replace(/^[()\[\]{}（）【】,，、:：\/／]+|[()\[\]{}（）【】,，、:：\/／]+$/g, '');
  cleaned = cleaned.replace(/^(?:页码[:：]?|p\.?)\s*/i, '').replace(/^第(?=\d+页$)/, '').replace(/页$/, '');
  return parsePrintedPage(cleaned);
}

function preferredManualSequencePosition(candidates) {
  const first = candidates.flatMap(candidate => candidate.numberIndices.length >= 2 ? [manualSequenceKey(candidate.tokens[candidate.numberIndices[0]])?.[0]] : []).filter(Number.isFinite);
  const last = candidates.flatMap(candidate => candidate.numberIndices.length >= 2 ? [manualSequenceKey(candidate.tokens[candidate.numberIndices.at(-1)])?.[0]] : []).filter(Number.isFinite);
  return manualSequenceScore(last) > manualSequenceScore(first) + .15 ? 'last' : 'first';
}

function manualSequenceScore(values) {
  if (values.length < 2) return 0;
  const unique = [...new Set(values)];
  if (unique.length !== values.length) return 0;
  const minimum = Math.min(...unique);
  const maximum = Math.max(...unique);
  return unique.length / Math.max(maximum - minimum + 1, 1) + (minimum <= 2 ? .35 : 0);
}

function parseManualCandidate(candidate, sequencePosition) {
  const numeric = candidate.numberIndices;
  let pageIndex;
  let sequenceIndex = null;
  if (numeric.length === 1) pageIndex = numeric[0];
  else if (sequencePosition === 'last') { sequenceIndex = numeric.at(-1); pageIndex = numeric[0]; }
  else { sequenceIndex = numeric[0]; pageIndex = numeric.at(-1); }
  const page = manualPageValue(candidate.tokens[pageIndex]);
  if (!page) return null;
  const titleTokens = candidate.tokens.filter((_token, index) => index !== pageIndex && index !== sequenceIndex);
  if (!titleTokens.length) return null;
  const explicitSequence = sequenceIndex == null ? '' : cleanManualSequence(candidate.tokens[sequenceIndex]);
  if (explicitSequence) {
    if (/^(?:chapter|part|section)$/i.test(titleTokens[0] || '')) titleTokens.splice(1, 0, explicitSequence);
    else titleTokens.unshift(explicitSequence);
  }
  const title = cleanEntryTitle(titleTokens.join(' '));
  if (title.length < 2 || title.length > 180) return null;
  return {
    originalIndex: candidate.originalIndex,
    orderKey: manualSequenceKey(explicitSequence) || manualSequenceKeyFromTitle(title),
    entry: { title, printedPage: page.value, pageStyle: page.style, level: candidate.level }
  };
}

function reorderManualEntries(parsed) {
  const pages = parsed.map(item => item.entry.printedPage);
  if (pages.every((page, index) => index === 0 || page >= pages[index - 1])) return parsed;
  const positions = parsed.map((item, index) => item.orderKey ? index : -1).filter(index => index >= 0);
  if (positions.length < 2) return parsed;
  const keys = positions.map(index => parsed[index].orderKey.join('.'));
  if (new Set(keys).size !== keys.length) return parsed;
  const sorted = positions.map(index => parsed[index]).sort((left, right) => compareManualKeys(left.orderKey, right.orderKey) || left.originalIndex - right.originalIndex);
  const result = [...parsed];
  positions.forEach((position, index) => { result[position] = sorted[index]; });
  return result;
}

function compareManualKeys(left, right) {
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    if (left[index] == null) return -1;
    if (right[index] == null) return 1;
    if (left[index] !== right[index]) return left[index] - right[index];
  }
  return 0;
}

function cleanManualSequence(token = '') {
  return token.replace(/^[()\[\]{}（）【】,，、:：]+|[()\[\]{}（）【】,，、:：]+$/g, '').replace(/[、．。]$/, '');
}

function manualSequenceKey(token = '') {
  const cleaned = cleanManualSequence(token).toLowerCase();
  if (/^\d+(?:\.\d+)*$/.test(cleaned)) return cleaned.split('.').map(Number);
  const chinese = chineseSequenceNumber(cleaned);
  return chinese == null ? null : [chinese];
}

function manualSequenceKeyFromTitle(title = '') {
  const match = title.match(/^第\s*([0-9一二三四五六七八九十百千零〇两]+)\s*[篇部卷章节]/i)
    || title.match(/^(?:chapter|part|section)\s+([0-9]+)/i)
    || title.match(/^(\d+(?:\.\d+)*)/);
  return match ? manualSequenceKey(match[1]) : null;
}

function chineseSequenceNumber(token) {
  const digits = { 零: 0, 〇: 0, 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };
  const units = { 十: 10, 百: 100, 千: 1000 };
  if (!token || [...token].some(character => digits[character] == null && units[character] == null)) return null;
  let total = 0;
  let current = 0;
  for (const character of token) {
    if (digits[character] != null) current = digits[character];
    else { total += Math.max(current, 1) * units[character]; current = 0; }
  }
  return total + current;
}

export function parseManualPages(source, expectedCount, restartAfter = 0) {
  const rows = source.replace(/\r\n?/g, '\n').split('\n').map(row => row.replace(/\D/g, '')).filter(Boolean).map(Number).filter(value => value > 0);
  let values;
  if (rows.length >= Math.min(expectedCount, 2)) values = rows.slice(0, expectedCount);
  else values = segmentDigitRun(source.replace(/\D/g, ''), expectedCount);
  if (restartAfter > 0 && restartAfter < values.length) {
    return [...values.slice(0, restartAfter).sort((a,b) => a-b), ...values.slice(restartAfter).sort((a,b) => a-b)];
  }
  const restart = detectPaginationRestart(values);
  if (restart > 0) return [...values.slice(0, restart).sort((a,b) => a-b), ...values.slice(restart).sort((a,b) => a-b)];
  return values.sort((a,b) => a-b);
}

function segmentDigitRun(digits, expectedCount) {
  if (!digits || expectedCount <= 0) return [];
  const memo = new Map();
  function solve(position, remaining, previous) {
    const key = `${position}|${remaining}|${previous}`;
    if (memo.has(key)) return memo.get(key);
    if (remaining === 0) return position === digits.length ? { cost: 0, values: [] } : null;
    const available = digits.length - position;
    if (available < remaining || available > remaining * 4) return null;
    let best = null;
    for (let length = 1; length <= 4 && position + length <= digits.length; length += 1) {
      if (remaining > 1 && digits[position] === '0') continue;
      const value = Number(digits.slice(position, position + length));
      if (!value || value > 9999) continue;
      const tail = solve(position + length, remaining - 1, value);
      if (!tail) continue;
      const jump = previous == null ? 0 : value >= previous ? Math.min(value - previous, 200) * .01 : 8 + Math.min(previous - value, 200) * .04;
      const cost = tail.cost + jump + (length === 4 ? 1.5 : 0);
      if (!best || cost < best.cost) best = { cost, values: [value, ...tail.values] };
    }
    memo.set(key, best);
    return best;
  }
  return solve(0, expectedCount, null)?.values || [];
}

function detectPaginationRestart(values) {
  let best = 0;
  let drop = 0;
  for (let index = 1; index < values.length; index += 1) {
    const amount = values[index - 1] - values[index];
    if (amount >= 5 && values[index] <= Math.max(3, Math.floor(values[index - 1] / 3)) && amount > drop) {
      drop = amount; best = index;
    }
  }
  return best;
}

export function detectTOCPages(pages = []) {
  if (!pages.length) return [];
  const profiles = pages.map(page => profilePage(page, pages.length));
  const explicit = profiles.map((profile, position) => ({ profile, position })).filter(item => item.profile.hasHeading);
  const strong = profiles.map((profile, position) => ({ profile, position }))
    .filter(item => item.profile.isStrongTOCPage && item.profile.pageIndex < Math.max(Math.ceil(pages.length / 2), 1));
  const seeds = explicit.length ? explicit : strong;
  if (!seeds.length) return [];
  const seedPosition = [...seeds].sort((left, right) => right.profile.score - left.profile.score)[0].position;
  const selectedPositions = new Set([seedPosition]);
  for (let cursor = seedPosition - 1; cursor >= 0 && seedPosition - cursor <= 4; cursor -= 1) {
    if (!profiles[cursor].isContinuation) break;
    selectedPositions.add(cursor);
  }
  // Printed contents pages are physically contiguous. Crossing even one
  // non-directory page is what caused a chapter cover followed by numbered
  // prose/footnotes to be swallowed into the directory range.
  for (let cursor = seedPosition + 1; cursor < profiles.length && cursor - seedPosition <= 20; cursor += 1) {
    if (!profiles[cursor].isContinuation) break;
    selectedPositions.add(cursor);
  }
  const positions = [...selectedPositions].sort((left, right) => left - right);
  if (!positions.length) return [];
  return profiles.slice(positions[0], positions.at(-1) + 1).map(profile => profile.pageIndex);
}

function profilePage(page, pageCount) {
  const text = normalizeTOCInput(page.text || '');
  const lines = text.split('\n').map(line => line.trim()).filter(Boolean);
  const hasHeading = lines.slice(0, 30).some(line => /^(?:(?:目\s*[录錄次])(?:\s*contents)?|contents|table\s+of\s+contents|sommaire|inhaltsverzeichnis|índice|indice|目録)(?:\s+[0-9ivxlcdm]+)?$/i.test(line));
  const parsed = parseAutomaticTOC(text);
  const sameLineEntries = lines.filter(line => titleAndPage(cleanLine(line))).length;
  const numberOnly = lines.filter(line => pageOnly(cleanLine(line))).length;
  const trailingPages = lines.filter(line => line.length <= 180 && /(?:\.{1,}|…{1,}|·{1,}|[-—:/／]|\s)\s*(?:\d{1,4}|[ivxlcdm]{1,10})\s*$/i.test(line)).length;
  const pageSignal = Math.max(sameLineEntries, trailingPages) + numberOnly;
  const leaders = lines.filter(line => /(?:\.{2,}|…{1,}|·{2,})\s*(?:\d{1,4}|[ivxlcdm]{1,10})\s*$/i.test(line)).length;
  const structural = lines.filter(line => /^(?:第.{1,60}[篇部卷章节]|chapter\s+\S+|part\s+\S+|\d{1,3}(?:\.\d{1,3}){0,3}\s+\S)/i.test(line)).length;
  const pairedSplitEntries = Math.min(structural, numberOnly);
  const entryCount = Math.max(parsed.length, sameLineEntries, pairedSplitEntries, trailingPages);
  const shortLineRatio = lines.length ? lines.filter(line => line.length >= 2 && line.length <= 100).length / lines.length : 0;
  const early = 4 * (1 - page.pageIndex / Math.max(pageCount, 1));
  const isContinuation = hasHeading
    || leaders >= 2
    || sameLineEntries >= 4
    || (numberOnly >= 4 && entryCount >= 4 && shortLineRatio >= .55)
    || (structural >= 4 && pageSignal >= 3);
  const isStrongTOCPage = (leaders >= 3 && entryCount >= 3)
    || (pageSignal >= 6 && shortLineRatio >= .60)
    || (structural >= 4 && pageSignal >= 3);
  return {
    pageIndex: page.pageIndex,
    hasHeading,
    entryCount,
    pageSignal,
    leaders,
    structural,
    shortLineRatio,
    isContinuation,
    isStrongTOCPage,
    score: (hasHeading ? 20 : 0) + entryCount * 3 + leaders * 2 + pageSignal + structural + shortLineRatio * 3 + early
  };
}

export function buildTOCText(pages, indices) {
  const byIndex = new Map(pages.map(page => [page.pageIndex, page]));
  return indices.map(index => byIndex.get(index)).filter(Boolean).map(page => `[目录页 · PDF 物理页 ${page.pageIndex + 1}]\n${page.text}`).join('\n\n--- 下一目录页 ---\n\n');
}

export function resolveTOCPages(entries, tocPageIndices, pages, preserveUnmatched = true) {
  if (!entries.length || !pages.length) return [];
  entries = entries.map(entry => {
    if (entry.pageStyle === 'roman' || !(entry.printedPage > pages.length)) return entry;
    const digits = String(entry.printedPage);
    const corrected = digits.length === 4 && digits.startsWith('1') ? Number(digits.slice(1)) : 0;
    return corrected > 0 && corrected <= pages.length ? { ...entry, printedPage: corrected } : entry;
  });
  const toc = new Set(tocPageIndices);
  const firstContentPage = Math.max(-1, ...tocPageIndices) + 1;
  const searchable = pages.filter(page => !toc.has(page.pageIndex));
  const segments = paginationSegments(entries);
  const candidates = new Map();
  entries.forEach((entry, index) => {
    const matches = candidateMatches(entry.title, searchable);
    if (matches.length) candidates.set(index, matches);
  });
  const preferredOffsets = consistentOffsetsBySegment(entries, segments, candidates, firstContentPage);
  const anchors = chooseMonotonicTitleAnchors(entries, segments, candidates, preferredOffsets);
  let bodyArabicSegment = null;
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    if (entries[index].pageStyle !== 'roman' && entries[index].printedPage) { bodyArabicSegment = segments[index]; break; }
  }
  const labelPages = customPageLabelMap(pages);
  const minimum = Math.min(...pages.map(page => page.pageIndex));
  const maximum = Math.max(...pages.map(page => page.pageIndex));
  const seen = new Set();
  return entries.flatMap((entry, index) => {
    const segment = segments[index];
    const labelPage = entry.printedPage ? labelPages.get(pageLabelKey(entry.printedPage, entry.pageStyle || 'arabic')) : null;
    let pageIndex;
    if (labelPage != null && (entry.pageStyle === 'roman' || segment === bodyArabicSegment)) pageIndex = labelPage;
    else if (anchors.has(index)) pageIndex = anchors.get(index);
    else pageIndex = estimatedPage(index, entries, segments, anchors, firstContentPage, tocPageIndices);
    if (pageIndex == null && !preserveUnmatched) return [];
    if (pageIndex == null && entry.printedPage) pageIndex = entry.pageStyle === 'roman' ? entry.printedPage - 1 : firstContentPage + entry.printedPage - 1;
    if (pageIndex == null) pageIndex = firstContentPage;
    pageIndex = Math.min(Math.max(pageIndex, minimum), maximum);
    const key = `${comparisonKey(entry.title)}|${pageIndex}`;
    if (seen.has(key)) return [];
    seen.add(key);
    return [{ title: entry.title, pageIndex, level: Math.min(Math.max(entry.level || 0, 0), 5), generated: true, printedPage: entry.printedPage, pageStyle: entry.pageStyle || null }];
  });
}

export function calibrateManualTOC(entries = [], pages = [], tocPageIndices = null) {
  if (!entries.length) return [];
  if (!pages.length) return entries.map(entry => ({ ...entry, pageIndex: Math.max(0, Number(entry.printedPage || 1) - 1), generated: true }));
  const directoryPages = Array.isArray(tocPageIndices)
    ? [...new Set(tocPageIndices.filter(Number.isInteger))].sort((left, right) => left - right)
    : detectTOCPages(pages);
  return resolveTOCPages(entries, directoryPages, pages, true).map(entry => ({ ...entry, printedPage: entry.printedPage }));
}

/** Mirrors the Mac calibration window around likely top-level openings. */
export function manualCalibrationPageIndices(entries = [], tocPageIndices = [], pages = []) {
  if (!entries.length || !pages.length) return [];
  const pageCount = Math.max(...pages.map(page => page.pageIndex), -1) + 1;
  const firstContentPage = Math.max(-1, ...tocPageIndices) + 1;
  const segments = paginationSegments(entries);
  const finalSegment = Math.max(...segments, 0);
  const byIndex = new Map(pages.map(page => [page.pageIndex, page]));
  const toc = new Set(tocPageIndices);
  const candidates = new Set();
  entries.forEach((entry, index) => {
    if ((entry.level || 0) > 1 || !(entry.printedPage > 0)) return;
    const estimate = segments[index] < finalSegment ? entry.printedPage - 1 : firstContentPage + entry.printedPage - 1;
    for (let pageIndex = estimate - 3; pageIndex <= estimate + 3; pageIndex += 1) {
      if (pageIndex < 0 || pageIndex >= pageCount || toc.has(pageIndex) || byIndex.get(pageIndex)?.cameFromOCR === true) continue;
      candidates.add(pageIndex);
    }
  });
  return [...candidates].sort((left, right) => left - right);
}

export function inferManualTOCPages(entries = [], pages = []) {
  const selected = new Set(detectTOCPages(pages));
  const profiles = new Map(pages.map(page => [page.pageIndex, profilePage(page, pages.length)]));
  const matchesByPage = new Map();
  for (const page of pages) {
    const pageText = comparisonKey(page.text || '');
    let matches = 0;
    for (const entry of entries) {
      const alternatives = [comparisonKey(entry.title), comparisonKey(titleWithoutSequence(entry.title))].filter(value => value.length >= 2);
      if (alternatives.some(value => pageText.includes(value))) matches += 1;
    }
    matchesByPage.set(page.pageIndex, matches);
    const profile = profiles.get(page.pageIndex);
    const earlyLimit = Math.min(pages.length, Math.max(80, Math.ceil(pages.length * .35)));
    const early = page.pageIndex < earlyLimit;
    const enoughCoverage = early && (entries.length <= 2 ? matches === entries.length && matches >= 2 : matches >= Math.min(3, entries.length));
    const pairedDirectoryLines = matches >= 2 && (profile.hasHeading || (early && (profile.pageSignal >= 2 || profile.entryCount >= 2)));
    if (enoughCoverage || pairedDirectoryLines) selected.add(page.pageIndex);
  }
  let changed = true;
  while (changed) {
    changed = false;
    for (const page of pages) {
      if (selected.has(page.pageIndex)) continue;
      const adjacent = selected.has(page.pageIndex - 1) || selected.has(page.pageIndex + 1);
      const profile = profiles.get(page.pageIndex);
      if (adjacent && matchesByPage.get(page.pageIndex) >= 1 && (profile.pageSignal >= 1 || profile.entryCount >= 1)) {
        selected.add(page.pageIndex);
        changed = true;
      }
    }
  }
  return [...selected].sort((left, right) => left - right);
}

function paginationSegments(entries) {
  let segment = 0;
  let previous = null;
  return entries.map(entry => {
    if (entry.printedPage) {
      const style = entry.pageStyle || 'arabic';
      if (previous && (previous.style !== style || (previous.page - entry.printedPage >= 5 && entry.printedPage <= Math.max(3, Math.floor(previous.page / 3))))) segment += 1;
      previous = { page: entry.printedPage, style };
    }
    return segment;
  });
}

function candidateMatches(title, pages) {
  const alternatives = [comparisonKey(title), comparisonKey(titleWithoutSequence(title))].filter(value => value.length >= 2);
  return pages.flatMap(page => {
    const source = [page.text, page.embeddedText].filter(Boolean).join('\n');
    const lines = source.split('\n').map(line => line.trim()).filter(Boolean);
    const head = comparisonKey(lines.slice(0, 18).join(' ').slice(0, 900));
    const full = comparisonKey(source.slice(0, 6000));
    let score = 0;
    for (const alternative of alternatives) {
      const lineScore = titleLineScore(alternative, lines);
      score = Math.max(score, lineScore);
      // Two- and three-character Chinese headings (e.g. “自拍”“安静”)
      // occur frequently inside prose. Only a standalone/fragmented heading
      // is strong enough to anchor such a title to a physical page.
      if ([...alternative].length <= 3) continue;
      if (head.includes(alternative)) score = Math.max(score, head.startsWith(alternative) ? 1 : .94);
      else if (full.includes(alternative)) score = Math.max(score, .90);
      else score = Math.max(score, bigramScore(alternative, head.slice(0, Math.max(alternative.length * 4, 100))));
    }
    return score >= .82 ? [{ pageIndex: page.pageIndex, score }] : [];
  }).sort((a,b) => b.score - a.score || a.pageIndex - b.pageIndex).slice(0, 6);
}

function titleLineScore(title, lines) {
  for (const line of lines) {
    const key = comparisonKey(line);
    if (key === title) return 1;
    if (key.startsWith(title) && key.length <= title.length + 12) return .99;
    if (key.includes(title) && key.length <= title.length * 3 + 8) return .97;
  }
  // Decorative title pages are often split into several OCR/PDF text boxes.
  // Join only short Han fragments near the top, ignoring Latin artwork noise.
  const hanTitle = title.replace(/[^\p{Script=Han}]/gu, '');
  if (hanTitle.length >= 3) {
    const fragments = lines.slice(0, 36).flatMap(line => {
      const han = (line.match(/[\p{Script=Han}]+/gu) || []).join('');
      return han && han.length <= Math.max(hanTitle.length * 2, 12) ? [han] : [];
    });
    if (fragments.join('').includes(hanTitle)) return .96;
  }
  return 0;
}

function bigramScore(left, right) {
  const grams = value => new Set([...Array(Math.max(value.length - 1, 0)).keys()].map(index => value.slice(index, index + 2)));
  const leftGrams = grams(left);
  if (!leftGrams.size) return 0;
  const rightGrams = grams(right);
  return [...leftGrams].filter(value => rightGrams.has(value)).length / leftGrams.size;
}

function titleWithoutSequence(title = '') {
  return title.replace(/^(?:(?:第\s*[0-9一二三四五六七八九十百千零〇两]+\s*[篇部卷章节])|(?:chapter|part|section)\s+\S+|(?:\d+(?:\.\d+)*))[\s、.．:：\-]*/i, '');
}

function chooseMonotonicTitleAnchors(entries, segments, candidates, preferredOffsets) {
  const anchors = new Map();
  for (const segment of [...new Set(segments)].sort((a, b) => a - b)) {
    let previousEntry = null;
    let previousPage = null;
    entries.forEach((_entry, index) => {
      if (segments[index] !== segment || !candidates.has(index)) return;
      const available = candidates.get(index);
      const monotonic = available.filter(match => previousPage == null || match.pageIndex >= previousPage);
      const pool = monotonic.length ? monotonic : available;
      const selected = [...pool].sort((left, right) => anchorScore(right, index, previousEntry, previousPage, entries, preferredOffsets.get(segment)) - anchorScore(left, index, previousEntry, previousPage, entries, preferredOffsets.get(segment)))[0];
      anchors.set(index, selected.pageIndex);
      previousEntry = index;
      previousPage = selected.pageIndex;
    });
  }
  return anchors;
}

function anchorScore(match, index, previousEntry, previousPage, entries, preferredOffset = null) {
  let score = match.score * 20;
  if (preferredOffset != null && entries[index].printedPage) {
    const distance = Math.abs((match.pageIndex - entries[index].printedPage) - preferredOffset);
    score += distance <= 1 ? 5 : -distance * .7;
  }
  if (previousEntry != null && previousPage != null && entries[index].printedPage >= entries[previousEntry].printedPage) {
    score -= Math.abs((match.pageIndex - previousPage) - (entries[index].printedPage - entries[previousEntry].printedPage)) * .08;
  } else score -= match.pageIndex * .0001;
  return score;
}

function consistentOffsetsBySegment(entries, segments, candidates, firstContentPage) {
  const result = new Map();
  const finalSegment = Math.max(...segments, 0);
  for (const segment of new Set(segments)) {
    const byEntry = new Map();
    entries.forEach((entry, index) => {
      if (segments[index] !== segment || !entry.printedPage || !candidates.has(index)) return;
      byEntry.set(index, candidates.get(index).map(match => ({ offset: match.pageIndex - entry.printedPage, score: match.score })));
    });
    const preferred = segment === finalSegment ? firstContentPage - 1 : -1;
    const offset = consistentOffset(byEntry, preferred);
    if (offset == null) continue;
    if (offsetSupport(offset, byEntry, preferred).entries >= 2) result.set(segment, offset);
  }
  return result;
}

function consistentOffset(byEntry, preferred) {
  const offsets = [...new Set([...byEntry.values()].flatMap(values => values.map(value => value.offset)))];
  return offsets.sort((left, right) => {
    const a = offsetSupport(left, byEntry, preferred);
    const b = offsetSupport(right, byEntry, preferred);
    return b.entries - a.entries || b.weight - a.weight || a.distance - b.distance;
  })[0] ?? null;
}

function offsetSupport(offset, byEntry, preferred) {
  const best = [...byEntry.values()].flatMap(values => {
    const scores = values.filter(value => Math.abs(value.offset - offset) <= 1).map(value => value.score);
    return scores.length ? [Math.max(...scores)] : [];
  });
  return { entries: best.length, weight: best.reduce((sum, value) => sum + value, 0), distance: preferred == null ? 0 : Math.abs(preferred - offset) };
}

function estimatedPage(index, entries, segments, anchors, firstContentPage, tocPageIndices) {
  const printed = entries[index].printedPage;
  if (!printed) return null;
  const segment = segments[index];
  const segmentAnchors = [...anchors.keys()].filter(anchor => segments[anchor] === segment).sort((a, b) => a - b);
  const before = segmentAnchors.filter(anchor => anchor < index).pop();
  const after = segmentAnchors.find(anchor => anchor > index);
  let estimate;
  if (before != null && after != null && entries[after].printedPage > entries[before].printedPage) {
    const ratio = (printed - entries[before].printedPage) / (entries[after].printedPage - entries[before].printedPage);
    estimate = Math.round(anchors.get(before) + ratio * (anchors.get(after) - anchors.get(before)));
  } else {
    const nearest = [before, after].filter(value => value != null).sort((left, right) => Math.abs(left - index) - Math.abs(right - index))[0];
    estimate = nearest != null ? anchors.get(nearest) + printed - entries[nearest].printedPage : (segments.some(value => value > segment) ? printed - 1 : firstContentPage + printed - 1);
  }
  const anchorPages = segmentAnchors.map(anchor => anchors.get(anchor));
  const frontMatter = anchorPages.length ? anchorPages.filter(page => page < firstContentPage).length > anchorPages.length / 2 : segments.some(value => value > segment);
  if (frontMatter && tocPageIndices.length) estimate = Math.min(estimate, Math.max(Math.min(...tocPageIndices) - 1, 0));
  else {
    estimate = Math.max(estimate, firstContentPage);
    while (tocPageIndices.includes(estimate)) estimate += 1;
  }
  return estimate;
}

function pageLabelKey(value, style) { return `${style}:${value}`; }

function customPageLabelMap(pages) {
  const parsed = pages.flatMap(page => {
    if (!page.pageLabel) return [];
    const label = parsePDFPageLabel(page.pageLabel);
    return label ? [{ key: pageLabelKey(label.value, label.style), pageIndex: page.pageIndex, isDefault: label.style === 'arabic' && label.value === page.pageIndex + 1 }] : [];
  });
  if (!parsed.some(item => !item.isDefault)) return new Map();
  const result = new Map();
  parsed.forEach(item => { if (!result.has(item.key)) result.set(item.key, item.pageIndex); });
  return result;
}

function parsePDFPageLabel(source = '') {
  const normalized = String(source).normalize('NFKC').trim();
  const direct = parsePrintedPage(normalized.replace(/^第(?=\d+页$)/, '').replace(/页$/, ''));
  if (direct) return direct;
  const suffix = normalized.match(/(?:^|[-_:/／\s])(?:第)?(\d{1,4})(?:页)?$/i);
  return suffix ? parsePrintedPage(suffix[1]) : null;
}

export function inferHierarchy(entries) {
  const hasPart = entries.some(entry => isPart(entry.title));
  return entries.map(entry => ({ ...entry, level: entry.level ?? rawLevel(entry.title, hasPart) }));
}
