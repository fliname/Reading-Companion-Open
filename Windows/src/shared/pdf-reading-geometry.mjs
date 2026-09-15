const clamp = (value, low, high) => Math.max(low, Math.min(high, value));

// Normalized visible page rectangle: independent of page size and render scale.
export function visiblePageRegion(page, viewport) {
  const x = clamp((viewport.left - page.left) / page.width, 0, 1);
  const y = clamp((viewport.top - page.top) / page.height, 0, 1);
  const right = clamp((viewport.right - page.left) / page.width, x, 1);
  const bottom = clamp((viewport.bottom - page.top) / page.height, y, 1);
  return { x, y, width: Math.max(.01, right - x), height: Math.max(.01, bottom - y) };
}

export function lockedPageScale(region, page, viewport, spread = 1) {
  return clamp(Math.min(viewport.width / spread / (page.width * region.width), viewport.height / (page.height * region.height)), .25, 5);
}

// Work in screen coordinates after PDF rotation. Merge only near-collinear,
// adjacent pieces; keep columns and neighboring lines separate.
export function highlightLineRects(rectangles) {
  const rows = [];
  for (const rect of rectangles.filter(r => r.width > 0 && r.height > 0).sort((a, b) => a.top - b.top || a.left - b.left)) {
    const center = rect.top + rect.height / 2;
    const row = rows.find(r => Math.abs(r.center - center) <= Math.min(r.height, rect.height) * .28 && Math.max(r.height, rect.height) <= Math.min(r.height, rect.height) * 1.65);
    if (row) row.rects.push(rect);
    else rows.push({ center, height: rect.height, rects: [rect] });
  }
  return rows.flatMap(row => {
    const result = [];
    for (const rect of row.rects.sort((a, b) => a.left - b.left)) {
      const previous = result.at(-1);
      if (previous && rect.left - (previous.left + previous.width) <= Math.min(previous.height, rect.height) * .65) {
        previous.width = Math.max(previous.left + previous.width, rect.left + rect.width) - previous.left;
        previous.height = Math.min(previous.height, rect.height);
      } else result.push({ ...rect });
    }
    return result.map(rect => ({ ...rect, top: row.center - rect.height * .35, height: Math.max(1, rect.height * .70) }));
  });
}
