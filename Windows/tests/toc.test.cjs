const test = require('node:test');
const assert = require('node:assert/strict');

test('目录 OCR 分行样本保持一行一条并合并页码数字', async () => {
  const { parseAutomaticTOC } = await import('../src/shared/toc.mjs');
  const entries = parseAutomaticTOC('第 四 版 说 明 1\n推 荐 序 比 尔 • 尼 科 尔 斯 3\n撰 稿 人 简 介 1 9\n第 四 版 导 读 2 2');
  assert.deepEqual(entries.map(entry => entry.title), ['第四版说明', '推荐序比尔•尼科尔斯', '撰稿人简介', '第四版导读']);
  assert.deepEqual(entries.map(entry => entry.printedPage), [1, 3, 19, 22]);
});

test('竖排目录二字不会污染第一、第二条', async () => {
  const { parseAutomaticTOC } = await import('../src/shared/toc.mjs');
  const entries = parseAutomaticTOC('目 从物到非物/001\n录 从占有到体验/019\n智能手机/029\n自拍/049\n人工智能/063\n艺术对物的遗忘.104');
  assert.deepEqual(entries.map(entry => entry.title), ['从物到非物', '从占有到体验', '智能手机', '自拍', '人工智能', '艺术对物的遗忘']);
  assert.deepEqual(entries.map(entry => entry.printedPage), [1, 19, 29, 49, 63, 104]);
});

test('无页码上篇继承下一条页码且层级更高', async () => {
  const { parseAutomaticTOC } = await import('../src/shared/toc.mjs');
  const entries = parseAutomaticTOC('上篇\n第一章 起点……9\n第二章 推进……31');
  assert.equal(entries[0].title, '上篇');
  assert.equal(entries[0].printedPage, 9);
  assert.equal(entries[0].level, 0);
  assert.equal(entries[1].level, 1);
});

test('手动目录按 Mac 版逐行识别标题、序号、页码和缩进层级', async () => {
  const { parseManualTOC } = await import('../src/shared/toc.mjs');
  const entries = parseManualTOC('1 第一章 开端……（5）\n  1.1 第一节 转折 / 19\n第二章 发展35');
  assert.deepEqual(entries.map(entry => entry.title), ['1 第一章开端', '1.1 第一节转折', '第二章 发展']);
  assert.deepEqual(entries.map(entry => entry.printedPage), [5, 19, 35]);
  assert.deepEqual(entries.map(entry => entry.level), [0, 2, 0]);
});

test('自动目录页码校准器仍可用标题锚点定位 PDF 页', async () => {
  const { parseManualTOC, resolveTOCPages } = await import('../src/shared/toc.mjs');
  const entries = parseManualTOC('第一章 开端 1\n第二章 发展 19');
  const pages = Array.from({ length: 40 }, (_value, pageIndex) => ({ pageIndex, text: pageIndex === 7 ? '第一章 开端' : pageIndex === 25 ? '第二章 发展' : '' }));
  const resolved = resolveTOCPages(entries, [2, 3], pages, true);
  assert.deepEqual(resolved.map(entry => entry.pageIndex), [7, 25]);
});

test('手动目录保留印刷页码并排除目录页后校准 PDF 物理页', async () => {
  const { calibrateManualTOC, parseManualTOC } = await import('../src/shared/toc.mjs');
  const entries = parseManualTOC('第一章 开端 1\n第二章 发展 19\n第三章 收束 35');
  const pages = Array.from({ length: 60 }, (_value, pageIndex) => ({
    pageIndex,
    text: pageIndex === 2
      ? '目录\n第一章 开端……1\n第二章 发展……19\n第三章 收束……35'
      : pageIndex === 10 ? '第一章 开端\n正文'
        : pageIndex === 28 ? '第二章 发展\n正文'
          : pageIndex === 44 ? '第三章 收束\n正文' : ''
  }));
  const calibrated = calibrateManualTOC(entries, pages);
  assert.deepEqual(calibrated.map(entry => entry.printedPage), [1, 19, 35]);
  assert.deepEqual(calibrated.map(entry => entry.pageIndex), [10, 28, 44]);
});

test('手动目录页只有两条且没有目录标题时也不会被当成正文锚点', async () => {
  const { calibrateManualTOC, inferManualTOCPages, parseManualTOC } = await import('../src/shared/toc.mjs');
  const entries = parseManualTOC('第一章 开端 1\n第二章 发展 19');
  const pages = Array.from({ length: 50 }, (_value, pageIndex) => ({
    pageIndex,
    text: pageIndex === 5 ? '第一章 开端……1\n第二章 发展……19'
      : pageIndex === 12 ? '第一章 开端\n正文内容'
        : pageIndex === 30 ? '第二章 发展\n正文内容' : ''
  }));
  assert.deepEqual(inferManualTOCPages(entries, pages), [5]);
  const calibrated = calibrateManualTOC(entries, pages);
  assert.deepEqual(calibrated.map(entry => entry.printedPage), [1, 19]);
  assert.deepEqual(calibrated.map(entry => entry.pageIndex), [12, 30]);
});

test('手动目录使用非默认 PDF 页标签校准正文页', async () => {
  const { calibrateManualTOC, parseManualTOC } = await import('../src/shared/toc.mjs');
  const entries = parseManualTOC('第一章 开端 1\n第二章 发展 19');
  const pages = Array.from({ length: 30 }, (_value, pageIndex) => ({ pageIndex, text: '', pageLabel: pageIndex >= 7 ? String(pageIndex - 6) : null }));
  const calibrated = calibrateManualTOC(entries, pages);
  assert.deepEqual(calibrated.map(entry => entry.pageIndex), [7, 25]);
});

test('Mac 目录检测不会把紧邻目录的正文首页扩成目录页', async () => {
  const { calibrateManualTOC, detectTOCPages, parseManualTOC } = await import('../src/shared/toc.mjs');
  const entries = parseManualTOC('第一章 开端 1\n第二章 发展 19');
  const pages = Array.from({ length: 40 }, (_value, pageIndex) => ({
    pageIndex,
    text: pageIndex === 5 ? '目录\n第一章 开端……1\n第二章 发展……19'
      : pageIndex === 6 ? '第一章 开端\n1\n正文开始'
        : pageIndex === 24 ? '第二章 发展\n19\n正文开始' : ''
  }));
  const directoryPages = detectTOCPages(pages);
  assert.deepEqual(directoryPages, [5]);
  assert.deepEqual(calibrateManualTOC(entries, pages, directoryPages).map(entry => entry.pageIndex), [6, 24]);
});

test('前部说明页提到多个章节时不会覆盖已检测的目录物理页范围', async () => {
  const { calibrateManualTOC, detectTOCPages, parseManualTOC } = await import('../src/shared/toc.mjs');
  const entries = parseManualTOC('第一章 开端 1\n第二章 发展 19');
  const pages = Array.from({ length: 40 }, (_value, pageIndex) => ({
    pageIndex,
    text: pageIndex === 3 ? '目录\n第一章 开端……1\n第二章 发展……19'
      : pageIndex === 5 ? '本书将讨论第一章 开端与第二章 发展'
        : pageIndex === 12 ? '第一章 开端\n正文'
          : pageIndex === 30 ? '第二章 发展\n正文' : ''
  }));
  const directoryPages = detectTOCPages(pages);
  assert.deepEqual(directoryPages, [3]);
  assert.deepEqual(calibrateManualTOC(entries, pages, directoryPages).map(entry => entry.pageIndex), [12, 30]);
});

test('目录后的装饰章页会截断范围，不跨页吞入带脚注页码的正文', async () => {
  const { detectTOCPages } = await import('../src/shared/toc.mjs');
  const pages = Array.from({ length: 20 }, (_value, pageIndex) => ({
    pageIndex,
    text: pageIndex === 2 ? '目录\n第一章 起点 /001\n第二章 发展 /019\n第三章 收束 /029\n第四章 余波 /049'
      : pageIndex === 3 ? 'UNDINGE\n装饰封面'
        : pageIndex >= 4 && pageIndex <= 8 ? '正文段落\n[1] 参考文献 19\n[2] 参考文献 29\n003' : ''
  }));
  assert.deepEqual(detectTOCPages(pages), [2]);
});

test('带中文或字母前缀的 PDF 页标签可以校准正文页', async () => {
  const { calibrateManualTOC, parseManualTOC } = await import('../src/shared/toc.mjs');
  const entries = parseManualTOC('第一章 开端 1\n第二章 发展 19');
  const pages = Array.from({ length: 40 }, (_value, pageIndex) => ({
    pageIndex,
    text: '',
    pageLabel: pageIndex === 12 ? '正文-1' : pageIndex === 30 ? '第19页' : null
  }));
  assert.deepEqual(calibrateManualTOC(entries, pages, []).map(entry => entry.pageIndex), [12, 30]);
});

test('手动目录按 Mac 逻辑生成正文标题前后各三页 OCR 校准窗口', async () => {
  const { manualCalibrationPageIndices, parseManualTOC } = await import('../src/shared/toc.mjs');
  const entries = parseManualTOC('第一章 开端 1\n第二章 发展 19');
  const pages = Array.from({ length: 40 }, (_value, pageIndex) => ({ pageIndex, text: '', cameFromOCR: pageIndex === 7 }));
  assert.deepEqual(manualCalibrationPageIndices(entries, [5], pages), [3, 4, 6, 8, 9, 21, 22, 23, 24, 25, 26, 27]);
});

test('《非物》复杂底图章页保留文本层并插值校准全部 15 条', async () => {
  const { calibrateManualTOC, parseManualTOC } = await import('../src/shared/toc.mjs');
  const source = [
    ['从物到非物', 1], ['从占有到体验', 19], ['智能手机', 29], ['自拍', 49], ['人工智能', 63],
    ['对物的看法', 77], ['物中潜伏着的危险', 80], ['物的脊背', 84], ['鬼魂', 92], ['物的魔力', 96],
    ['艺术对物的遗忘', 104], ['海德格尔的手', 112], ['心物', 121], ['安静', 125], ['关于点唱机的附论', 139]
  ];
  const entries = parseManualTOC(source.map(([title, page]) => `${title} /${String(page).padStart(3, '0')}`).join('\n'));
  const pages = Array.from({ length: 153 }, (_value, pageIndex) => ({ pageIndex, text: '', embeddedText: '', cameFromOCR: false }));
  pages[2].text = source.map(([title, page]) => `${title} /${String(page).padStart(3, '0')}`).join('\n');
  const anchors = new Map([
    [20, '从占有\nI II H\n到体验'], [29, '智能手机'], [59, '人工智能'], [72, '对物的看法'],
    [74, '物中潜伏着的危险'], [78, '物的脊背'], [86, '鬼魂'], [90, '物的魔力'],
    [98, '艺术对物的遗忘'], [106, '海德格尔的手'], [115, '心物'], [119, '安静']
  ]);
  anchors.forEach((text, pageIndex) => { pages[pageIndex].embeddedText = text; });
  assert.deepEqual(
    calibrateManualTOC(entries, pages, [2]).map(entry => entry.pageIndex + 1),
    [4, 21, 30, 48, 60, 73, 75, 79, 87, 91, 99, 107, 116, 120, 134]
  );
});

test('《论摄影》扫描目录用正文开篇锚点校准全部章节', async () => {
  const { calibrateManualTOC, parseManualTOC } = await import('../src/shared/toc.mjs');
  const source = [
    ['柏拉图的洞穴', 13], ['由朦胧的摄影看美国', 39], ['令人抑郁的对象', 65], ['幻象英雄主义', 101],
    ['摄影的福音', 131], ['形象的世界', 169], ['引文简集', 201], ['附录', 231]
  ];
  const entries = parseManualTOC(source.map(([title, page]) => `${title} ${page}`).join('\n'));
  const pages = Array.from({ length: 236 }, (_value, pageIndex) => ({ pageIndex, text: '', cameFromOCR: true }));
  pages[8].text = `目录\n${source.map(([title, page]) => `${title}……${page}`).join('\n')}`;
  source.forEach(([title, physicalPage]) => { pages[physicalPage - 1].text = `${title}\n正文开篇`; });
  assert.deepEqual(calibrateManualTOC(entries, pages, [8]).map(entry => entry.pageIndex + 1), source.map(([, page]) => page));
});

test('《故事》扫描 PDF 的非默认页标签直接校准 19 章', async () => {
  const { calibrateManualTOC, parseManualTOC } = await import('../src/shared/toc.mjs');
  const source = [
    ['CHAPTER 01 故事问题', 3], ['CHAPTER 02 结构图谱', 27], ['CHAPTER 03 结构与背景', 69],
    ['CHAPTER 04 结构与类型', 85], ['CHAPTER 05 结构与人物', 109], ['CHAPTER 06 结构与意义', 123],
    ['CHAPTER 07 故事材质', 151], ['CHAPTER 08 激励事件', 205], ['CHAPTER 09 幕设计', 237],
    ['CHAPTER 10 场景设计', 265], ['CHAPTER 11 场景分析', 289], ['CHAPTER 12 布局谋篇', 335],
    ['CHAPTER 13 危机、高潮、结局', 353], ['CHAPTER 14 对抗的原理', 369], ['CHAPTER 15 解说', 387],
    ['CHAPTER 16 问题和解决方法', 403], ['CHAPTER 17 人物', 435], ['CHAPTER 18 文本', 451],
    ['CHAPTER 19 作家的创造方法', 477]
  ];
  const entries = parseManualTOC(source.map(([title, page]) => `${title} ${String(page).padStart(3, '0')}`).join('\n'));
  assert.equal(entries[0].title, 'CHAPTER 01 故事问题');
  const pages = Array.from({ length: 542 }, (_value, pageIndex) => ({
    pageIndex,
    text: '',
    pageLabel: pageIndex >= 18 ? String(pageIndex - 17) : String.fromCharCode(65 + Math.min(pageIndex, 15))
  }));
  const expected = source.map(([, printedPage]) => printedPage + 18);
  assert.deepEqual(calibrateManualTOC(entries, pages, [16, 17]).map(entry => entry.pageIndex + 1), expected);
});
