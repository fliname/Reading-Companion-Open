const test = require('node:test');
const assert = require('node:assert/strict');

test('同页子标题之前的内容归入父章节', async () => {
  const { chapterPathForPage } = await import('../src/shared/retrieval.mjs');
  const outline = [
    { title: 'CHAPTER02 结构图谱', pageIndex: 10, level: 0 },
    { title: '故事设计术语', pageIndex: 11, level: 1 },
    { title: '场景', pageIndex: 11, level: 2 },
    { title: '节拍', pageIndex: 12, level: 2 },
    { title: '序列', pageIndex: 13, level: 2 },
    { title: '幕', pageIndex: 14, level: 2 }
  ];
  assert.deepEqual(chapterPathForPage(11, outline), ['CHAPTER02 结构图谱', '故事设计术语']);
});

test('章节范围检索可覆盖同一父章节下的相邻小节', async () => {
  const { makeChunks, retrieveForReading } = await import('../src/shared/retrieval.mjs');
  const outline = [
    { title: '结构图谱', pageIndex: 0, level: 0 },
    { title: '故事设计术语', pageIndex: 1, level: 1 },
    { title: '场景', pageIndex: 1, level: 2 },
    { title: '幕', pageIndex: 2, level: 2 }
  ];
  const chunks = makeChunks([{ pageIndex: 1, text: '场景是连续时空中的行动。' }, { pageIndex: 2, text: '幕是由一系列序列构成的重大运动。' }], outline, 100, 0);
  const found = retrieveForReading('场景和幕的关系', 1, chunks, { scope: 'context', limit: 9 });
  assert.ok(found.some(chunk => chunk.pageIndex === 2));
});

test('Obsidian AI 对话写入准确章节并默认展开', async () => {
  const { aiBlock, insertUnderChapter, skeleton } = await import('../src/shared/notes.mjs');
  const outline = [{ title: '导论', level: 0 }, { title: '第一节', level: 1 }];
  const source = skeleton('测试书', outline);
  const block = aiBlock([{ role: 'user', content: '问题', pageReferences: [2] }, { role: 'assistant', content: '**答案**', pageReferences: [2] }]);
  const result = insertUnderChapter(source, block, '导论');
  assert.match(result, /## 导论[\s\S]*\[!example\]\+ AI 讨论/);
  assert.ok(result.indexOf('[!example]') < result.indexOf('### 第一节'));
});

test('PDF 双栏文本按左栏完整读完再读右栏', async () => {
  const { reconstructText } = await import('../src/shared/pdf-layout.mjs');
  const items = [];
  for (let row = 0; row < 6; row += 1) {
    items.push({ str: `左${row}`, transform: [1, 0, 0, 10, 40, 700 - row * 20], width: 35, height: 10 });
    items.push({ str: `右${row}`, transform: [1, 0, 0, 10, 340, 700 - row * 20], width: 35, height: 10 });
  }
  assert.equal(reconstructText(items, 600), '左0\n左1\n左2\n左3\n左4\n左5\n右0\n右1\n右2\n右3\n右4\n右5');
});

test('窄栏间距不会把左右栏误拼为同一行', async () => {
  const { reconstructText } = await import('../src/shared/pdf-layout.mjs');
  const items = [];
  for (let row = 0; row < 6; row += 1) {
    items.push({ str: `左栏段落${row}`, transform: [1, 0, 0, 10, 60, 700 - row * 20], width: 220, height: 10 });
    items.push({ str: `右栏段落${row}`, transform: [1, 0, 0, 10, 295, 700 - row * 20], width: 220, height: 10 });
  }
  assert.equal(reconstructText(items, 600), '左栏段落0\n左栏段落1\n左栏段落2\n左栏段落3\n左栏段落4\n左栏段落5\n右栏段落0\n右栏段落1\n右栏段落2\n右栏段落3\n右栏段落4\n右栏段落5');
});

test('搜索命中忽略 OCR 空格与标点并返回原文字符范围', async () => {
  const { searchMatchRanges } = await import('../src/shared/retrieval.mjs');
  const source = '作者讨论“再 现—研 究”的方法。';
  const ranges = searchMatchRanges('再现研究', source);
  assert.equal(ranges.length, 1);
  assert.equal(source.slice(ranges[0].start, ranges[0].end), '再 现—研 究');
});

test('扫描页 OCR 行框可归一化并随页面旋转', async () => {
  const { normalizeOCRLines, rotateNormalizedBox } = await import('../src/shared/ocr-layer.mjs');
  const lines = normalizeOCRLines([{ text: '扫描文字', bbox: { x0: 100, y0: 200, x1: 500, y1: 260 } }], 1000, 2000);
  assert.deepEqual(lines, [{ text: '扫描文字', box: [.1, .1, .5, .13] }]);
  assert.deepEqual(rotateNormalizedBox(lines[0].box, 90), [.87, .1, .9, .5]);
});

test('正常 PDF 选区不做 OCR 改写，乱码选区才纠错', async () => {
  const { needsOCRCorrection } = await import('../src/shared/selection.mjs');
  assert.equal(needsOCRCorrection('这段简体中文必须原样保留'), false);
  assert.equal(needsOCRCorrection('這段繁體中文也必须原样保留'), false);
  assert.equal(needsOCRCorrection('文字□映射'), true);
  assert.equal(needsOCRCorrection(`文字${String.fromCodePoint(0xE000)}映射`), true);
});

test('扫描页拖到下一行时按纵向锁行，不被右侧空白吸回上一行', async () => {
  const { compareOCRSelectionLines, nearestOCRSelectionLine } = await import('../src/shared/ocr-selection.mjs');
  const line = (lineIndex, left, top, right, bottom) => ({
    pageIndex: 0,
    lineIndex,
    clientRect: { left, top, right, bottom, width: right - left, height: bottom - top }
  });
  const previous = line(9, 100, 100, 900, 120);
  const next = line(2, 100, 132, 480, 152);
  assert.equal(nearestOCRSelectionLine([previous, next], 880, 140), next);
  assert.deepEqual([next, previous].sort(compareOCRSelectionLines), [previous, next]);
});

test('扫描页选区按逐词坐标收口，不涂到行末空白', async () => {
  const { ocrCharacterOffsetAtPoint, selectedOCRClientRect } = await import('../src/shared/ocr-selection.mjs');
  const line = {
    text: '扫描文字',
    clientRect: { left: 100, top: 100, right: 600, bottom: 124, width: 500, height: 24 },
    words: [
      { text: '扫描', clientRect: { left: 100, top: 100, right: 160, bottom: 124, width: 60, height: 24 } },
      { text: '文字', clientRect: { left: 168, top: 100, right: 228, bottom: 124, width: 60, height: 24 } }
    ]
  };
  assert.equal(ocrCharacterOffsetAtPoint(line, 520, 112), 4);
  assert.deepEqual(selectedOCRClientRect(line, 0, 4), { left: 100, top: 100, right: 228, bottom: 124, width: 128, height: 24 });
});

test('划线与批注搜索同时匹配原文和批注内容', async () => {
  const { markMatchesQuery } = await import('../src/shared/mark-search.mjs');
  const mark = { text: '媒介改变人的感知比例', note: '这与麦克卢汉有关' };
  assert.equal(markMatchesQuery(mark, '感知比例'), true);
  assert.equal(markMatchesQuery(mark, '麦克卢汉'), true);
  assert.equal(markMatchesQuery(mark, '不存在'), false);
});

test('Ctrl 连续划线以圆点和换行组合并保留单段原貌', async () => {
  const { formatSelectionParts, normalizeGroupedSelectionText } = await import('../src/shared/selection-group.mjs');
  assert.equal(formatSelectionParts(['第一处内容']), '第一处内容');
  assert.equal(formatSelectionParts(['第一处内容', '第二处内容']), '• 第一处内容\n• 第二处内容');
  assert.equal(normalizeGroupedSelectionText('• 第一处 内容\n• 第二处 内容'), '• 第一处内容\n• 第二处内容');
});

test('扫描页搜索按 OCR 逐词坐标生成精确高亮框', async () => {
  const { ocrSearchBoxes } = await import('../src/shared/ocr-search.mjs');
  const boxes = ocrSearchBoxes([{
    text: '《故事》论述的是原理', box: [.1, .2, .8, .25],
    words: [
      { text: '《故事》', box: [.1, .2, .28, .25] },
      { text: '论述的是原理', box: [.3, .2, .8, .25] }
    ]
  }], '故事');
  assert.equal(boxes.length, 1);
  assert.ok(boxes[0][0] > .1 && boxes[0][2] < .28);
  assert.deepEqual(boxes[0].slice(1, 4).filter((_value, index) => index !== 1), [.2, .25]);
});
