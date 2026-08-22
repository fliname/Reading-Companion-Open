function axisGap(value, start, end) {
  if (value < start) return start - value;
  if (value > end) return value - end;
  return 0;
}

function verticalOverlapRatio(left, right) {
  const overlap = Math.max(0, Math.min(left.bottom, right.bottom) - Math.max(left.top, right.top));
  return overlap / Math.max(1, Math.min(left.height, right.height));
}

export function compareOCRSelectionLines(left, right) {
  if (left.pageIndex !== right.pageIndex) return left.pageIndex - right.pageIndex;
  if (verticalOverlapRatio(left.clientRect, right.clientRect) >= .52) {
    return left.clientRect.left - right.clientRect.left || left.clientRect.top - right.clientRect.top;
  }
  return left.clientRect.top - right.clientRect.top || left.clientRect.left - right.clientRect.left;
}

/** Prefer the line under the pointer's y-coordinate. Horizontal distance is
 * only a tie-breaker, so dragging through the right margin cannot jump to a
 * longer line above or below the intended row. */
export function nearestOCRSelectionLine(lines = [], clientX = 0, clientY = 0) {
  return [...lines].sort((left, right) => {
    const leftVertical = axisGap(clientY, left.clientRect.top, left.clientRect.bottom);
    const rightVertical = axisGap(clientY, right.clientRect.top, right.clientRect.bottom);
    if (leftVertical !== rightVertical) return leftVertical - rightVertical;
    const leftHorizontal = axisGap(clientX, left.clientRect.left, left.clientRect.right);
    const rightHorizontal = axisGap(clientX, right.clientRect.left, right.clientRect.right);
    return leftHorizontal - rightHorizontal
      || Math.abs(clientY - (left.clientRect.top + left.clientRect.bottom) / 2)
        - Math.abs(clientY - (right.clientRect.top + right.clientRect.bottom) / 2);
  })[0] || null;
}

function wordRanges(line) {
  const lineCharacters = [...String(line.text || '')];
  const result = [];
  let cursor = 0;
  for (const word of line.words || []) {
    const wordCharacters = [...String(word.text || '').trim()];
    if (!wordCharacters.length || !word.clientRect) continue;
    while (cursor < lineCharacters.length && /\s/u.test(lineCharacters[cursor])) cursor += 1;
    let found = -1;
    for (let index = cursor; index <= lineCharacters.length - wordCharacters.length; index += 1) {
      if (wordCharacters.every((character, offset) => lineCharacters[index + offset] === character)) { found = index; break; }
    }
    const start = found >= 0 ? found : cursor;
    const end = Math.min(lineCharacters.length, start + wordCharacters.length);
    if (end > start) result.push({ ...word, start, end });
    cursor = Math.max(cursor, end);
  }
  return result;
}

export function ocrCharacterOffsetAtPoint(line, clientX, clientY) {
  const characters = [...String(line.text || '')];
  if (!characters.length) return 0;
  const vertical = line.clientRect.height > line.clientRect.width * 1.25;
  const ranges = wordRanges(line).sort((left, right) => vertical
    ? left.clientRect.top - right.clientRect.top
    : left.clientRect.left - right.clientRect.left);
  if (ranges.length) {
    const coordinate = vertical ? clientY : clientX;
    const startKey = vertical ? 'top' : 'left';
    const endKey = vertical ? 'bottom' : 'right';
    if (coordinate <= ranges[0].clientRect[startKey]) return ranges[0].start;
    if (coordinate >= ranges.at(-1).clientRect[endKey]) return ranges.at(-1).end;
    for (let index = 0; index < ranges.length; index += 1) {
      const word = ranges[index];
      if (coordinate >= word.clientRect[startKey] && coordinate <= word.clientRect[endKey]) {
        const ratio = (coordinate - word.clientRect[startKey]) / Math.max(1, word.clientRect[endKey] - word.clientRect[startKey]);
        return Math.max(word.start, Math.min(word.end, word.start + Math.round(ratio * (word.end - word.start))));
      }
      const next = ranges[index + 1];
      if (next && coordinate > word.clientRect[endKey] && coordinate < next.clientRect[startKey]) {
        return coordinate - word.clientRect[endKey] <= next.clientRect[startKey] - coordinate ? word.end : next.start;
      }
    }
  }
  const ratio = vertical
    ? (clientY - line.clientRect.top) / Math.max(line.clientRect.height, 1)
    : (clientX - line.clientRect.left) / Math.max(line.clientRect.width, 1);
  return Math.max(0, Math.min(characters.length, Math.round(ratio * characters.length)));
}

function unionRect(rectangles) {
  if (!rectangles.length) return null;
  const left = Math.min(...rectangles.map(rectangle => rectangle.left));
  const top = Math.min(...rectangles.map(rectangle => rectangle.top));
  const right = Math.max(...rectangles.map(rectangle => rectangle.right));
  const bottom = Math.max(...rectangles.map(rectangle => rectangle.bottom));
  return { left, top, right, bottom, width: right - left, height: bottom - top };
}

/** Return the ink-aligned rectangle for a substring. Word coordinates keep a
 * completed row from painting through the blank right margin. */
export function selectedOCRClientRect(line, from, to) {
  const characters = [...String(line.text || '')];
  const vertical = line.clientRect.height > line.clientRect.width * 1.25;
  const ranges = wordRanges(line).filter(word => word.end > from && word.start < to);
  const pieces = ranges.map(word => {
    const length = Math.max(1, word.end - word.start);
    const localFrom = Math.max(0, from - word.start);
    const localTo = Math.min(length, to - word.start);
    const rectangle = word.clientRect;
    if (vertical) {
      return {
        left: rectangle.left,
        right: rectangle.right,
        top: rectangle.top + rectangle.height * localFrom / length,
        bottom: rectangle.top + rectangle.height * localTo / length
      };
    }
    return {
      left: rectangle.left + rectangle.width * localFrom / length,
      right: rectangle.left + rectangle.width * localTo / length,
      top: rectangle.top,
      bottom: rectangle.bottom
    };
  }).filter(rectangle => rectangle.right > rectangle.left && rectangle.bottom > rectangle.top);
  const inkRect = unionRect(pieces);
  if (inkRect) return inkRect;
  const length = Math.max(1, characters.length);
  if (vertical) {
    return {
      left: line.clientRect.left,
      right: line.clientRect.right,
      top: line.clientRect.top + line.clientRect.height * from / length,
      bottom: line.clientRect.top + line.clientRect.height * to / length
    };
  }
  return {
    left: line.clientRect.left + line.clientRect.width * from / length,
    right: line.clientRect.left + line.clientRect.width * to / length,
    top: line.clientRect.top,
    bottom: line.clientRect.bottom
  };
}
