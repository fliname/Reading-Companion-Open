export function normalizeOCRLines(lines = [], imageWidth = 0, imageHeight = 0) {
  if (!(imageWidth > 0) || !(imageHeight > 0)) return [];
  return lines.flatMap(line => {
    const box = line?.bbox;
    const text = String(line?.text || '').trim();
    if (!text || !box) return [];
    const x0 = Math.max(0, Math.min(1, Number(box.x0) / imageWidth));
    const y0 = Math.max(0, Math.min(1, Number(box.y0) / imageHeight));
    const x1 = Math.max(x0, Math.min(1, Number(box.x1) / imageWidth));
    const y1 = Math.max(y0, Math.min(1, Number(box.y1) / imageHeight));
    if (x1 - x0 < .0001 || y1 - y0 < .0001) return [];
    const words = (line.words || []).flatMap(word => {
      const wordText = String(word?.text || '').trim();
      const wordBox = word?.bbox;
      if (!wordText || !wordBox) return [];
      const wx0 = Math.max(0, Math.min(1, Number(wordBox.x0) / imageWidth));
      const wy0 = Math.max(0, Math.min(1, Number(wordBox.y0) / imageHeight));
      const wx1 = Math.max(wx0, Math.min(1, Number(wordBox.x1) / imageWidth));
      const wy1 = Math.max(wy0, Math.min(1, Number(wordBox.y1) / imageHeight));
      return wx1 - wx0 >= .0001 && wy1 - wy0 >= .0001 ? [{ text: wordText, box: [wx0, wy0, wx1, wy1] }] : [];
    });
    return [{ text, box: [x0, y0, x1, y1], ...(words.length ? { words } : {}) }];
  });
}

export function rotateNormalizedBox(box, rotation = 0) {
  const [x0, y0, x1, y1] = box;
  switch (((rotation % 360) + 360) % 360) {
    case 90: return [1 - y1, x0, 1 - y0, x1];
    case 180: return [1 - x1, 1 - y1, 1 - x0, 1 - y0];
    case 270: return [y0, 1 - x1, y1, 1 - x0];
    default: return [x0, y0, x1, y1];
  }
}
