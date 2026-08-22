function projection(value = '') {
  const characters = [];
  const positions = [];
  for (let offset = 0; offset < value.length;) {
    const codePoint = value.codePointAt(offset);
    const character = String.fromCodePoint(codePoint);
    const nextOffset = offset + character.length;
    for (const scalar of character.normalize('NFKD').toLocaleLowerCase('zh-CN')) {
      if (!/[\p{L}\p{N}]/u.test(scalar)) continue;
      characters.push(scalar);
      positions.push({ start: offset, end: nextOffset });
    }
    offset = nextOffset;
  }
  return { text: characters.join(''), positions };
}

function wordRanges(line) {
  const source = String(line.text || '');
  const ranges = [];
  let cursor = 0;
  for (const word of line.words || []) {
    const text = String(word.text || '').trim();
    if (!text || !word.box) continue;
    const start = source.indexOf(text, cursor);
    const resolvedStart = start >= 0 ? start : cursor;
    const end = Math.min(source.length, resolvedStart + text.length);
    if (end > resolvedStart) ranges.push({ start: resolvedStart, end, box: word.box });
    cursor = Math.max(cursor, end);
  }
  return ranges;
}

function sliceBox(box, startRatio, endRatio) {
  const [x0, y0, x1, y1] = box;
  if (y1 - y0 > (x1 - x0) * 1.25) return [x0, y0 + (y1 - y0) * startRatio, x1, y0 + (y1 - y0) * endRatio];
  return [x0 + (x1 - x0) * startRatio, y0, x0 + (x1 - x0) * endRatio, y1];
}

export function ocrSearchBoxes(lines = [], query = '') {
  const needle = projection(String(query || '')).text;
  if (!needle) return [];
  const matches = [];
  lines.forEach(line => {
    const source = String(line.text || '');
    const projected = projection(source);
    if (!projected.text) return;
    let index = 0;
    while ((index = projected.text.indexOf(needle, index)) >= 0) {
      const start = projected.positions[index].start;
      const end = projected.positions[index + needle.length - 1].end;
      const words = wordRanges(line).filter(word => word.end > start && word.start < end);
      if (words.length) {
        words.forEach(word => {
          const localStart = Math.max(start, word.start);
          const localEnd = Math.min(end, word.end);
          matches.push(sliceBox(word.box, (localStart - word.start) / Math.max(word.end - word.start, 1), (localEnd - word.start) / Math.max(word.end - word.start, 1)));
        });
      } else if (line.box) {
        matches.push(sliceBox(line.box, start / Math.max(source.length, 1), end / Math.max(source.length, 1)));
      }
      index += needle.length;
    }
  });
  return matches;
}
