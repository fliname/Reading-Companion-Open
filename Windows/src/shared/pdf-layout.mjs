export function reconstructText(items = [], pageWidth = 600) {
  const rows = [];
  for (const item of items.filter(item => typeof item.str === 'string' && item.str.trim())) {
    const x = item.transform?.[4] || 0;
    const y = item.transform?.[5] || 0;
    const height = Math.abs(item.height || item.transform?.[3] || 10);
    let row = rows.find(candidate => Math.abs(candidate.y - y) <= Math.max(candidate.height, height) * 0.55);
    if (!row) { row = { y, height, pieces: [] }; rows.push(row); }
    row.pieces.push({ x, width: Math.abs(item.width || 0), text: item.str });
  }
  const lines = rows.flatMap(row => {
    const ordered = row.pieces.sort((a, b) => a.x - b.x);
    const groups = [];
    for (const piece of ordered) {
      const previous = groups.at(-1);
      const previousEnd = previous ? Math.max(...previous.pieces.map(item => item.x + item.width)) : 0;
      const gap = previous ? piece.x - previousEnd : 0;
      // PDF text layers often leave only 12–20pt between two newspaper-style
      // columns.  Treat that gutter as a column break, while retaining the
      // much smaller gaps between glyph runs inside one line.
      if (!previous || gap > Math.max(9, row.height * 1.35)) groups.push({ y: row.y, height: row.height, pieces: [piece] });
      else previous.pieces.push(piece);
    }
    return groups.map(group => {
      const x0 = Math.min(...group.pieces.map(piece => piece.x));
      const x1 = Math.max(...group.pieces.map(piece => piece.x + piece.width));
      return { y: group.y, x0, x1, text: group.pieces.map(piece => piece.text).join(' ') };
    });
  });
  const narrow = lines.filter(line => line.x1 - line.x0 < pageWidth * .58);
  const left = narrow.filter(line => (line.x0 + line.x1) / 2 < pageWidth * .5);
  const right = narrow.filter(line => (line.x0 + line.x1) / 2 >= pageWidth * .5);
  const overlappingColumns = left.length >= 5 && right.length >= 5
    && Math.min(Math.max(...left.map(line => line.y)), Math.max(...right.map(line => line.y)))
      > Math.max(Math.min(...left.map(line => line.y)), Math.min(...right.map(line => line.y)));
  const byReadingOrder = list => [...list].sort((a, b) => b.y - a.y || a.x0 - b.x0);
  if (!overlappingColumns) return byReadingOrder(lines).map(line => line.text).join('\n');
  const top = Math.max(...narrow.map(line => line.y));
  const wide = lines.filter(line => line.x1 - line.x0 >= pageWidth * .58);
  const header = wide.filter(line => line.y >= top - Math.max(8, Math.abs(top) * 0.01));
  const footer = wide.filter(line => !header.includes(line));
  return [...byReadingOrder(header), ...byReadingOrder(left), ...byReadingOrder(right), ...byReadingOrder(footer)]
    .map(line => line.text).join('\n');
}
