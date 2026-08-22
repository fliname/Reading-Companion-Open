const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

test('OCR 文本修正去除中日韩伪空格并保留普通英文词间距', () => {
  const { normalizeOCRText, DEFAULT_LANGUAGES } = require('../src/main/ocr-service.cjs');
  assert.equal(normalizeOCRText('电 影 是 一 种 艺 术'), '电影是一种艺术');
  assert.equal(normalizeOCRText('film studies'), 'film studies');
  assert.deepEqual(DEFAULT_LANGUAGES, ['chi_sim', 'eng']);
});

test('API Base URL 兼容官方与独立中转站', () => {
  const { normalizeBaseURL, providerKind } = require('../src/main/ai-service.cjs');
  assert.equal(normalizeBaseURL('https://juziqishui.net'), 'https://juziqishui.net/v1');
  assert.equal(normalizeBaseURL('https://api.openai.com/v1/'), 'https://api.openai.com/v1');
  assert.equal(providerKind('https://api.anthropic.com'), 'anthropic');
});

test('双栏 OCR 目录按列读取而不交错页码', () => {
  const { legacyTOCOrder } = require('../src/main/ocr-service.cjs');
  const line = (text, x, y) => ({ text, confidence: 90, bbox: { x0: x, x1: x + 160, y0: y, y1: y + 18 } });
  const lines = [line('左一……1', 20, 10), line('右一……50', 340, 10), line('左二……2', 20, 40), line('右二……60', 340, 40), line('左三……3', 20, 70), line('右三……70', 340, 70)];
  assert.deepEqual(legacyTOCOrder(lines).map(item => item.text), ['左一……1', '左二……2', '左三……3', '右一……50', '右二……60', '右三……70']);
});

test('OCR blocks 缺失时从 TSV 恢复可划线的行坐标', () => {
  const { linesFromTSV } = require('../src/main/ocr-service.cjs');
  const tsv = [
    'level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext',
    '5\t1\t1\t1\t1\t1\t10\t20\t30\t12\t92\t扫描',
    '5\t1\t1\t1\t1\t2\t44\t20\t30\t12\t90\t文字',
    '5\t1\t1\t1\t2\t1\t10\t40\t64\t12\t88\t可以划线'
  ].join('\n');
  assert.deepEqual(linesFromTSV(tsv).map(line => ({ text: line.text, bbox: line.bbox })), [
    { text: '扫描文字', bbox: { x0: 10, y0: 20, x1: 74, y1: 32 } },
    { text: '可以划线', bbox: { x0: 10, y0: 40, x1: 74, y1: 52 } }
  ]);
  assert.deepEqual(linesFromTSV(tsv)[0].words.map(word => ({ text: word.text, bbox: word.bbox })), [
    { text: '扫描', bbox: { x0: 10, y0: 20, x1: 40, y1: 32 } },
    { text: '文字', bbox: { x0: 44, y0: 20, x1: 74, y1: 32 } }
  ]);
});

test('Obsidian 使用已注册 Vault 名称和相对文件打开 Windows 笔记', () => {
  const { registeredVaults, exactVault, containingVault, openURL } = require('../src/main/obsidian-service.cjs');
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'rc-obsidian-'));
  const registry = path.join(folder, 'obsidian.json');
  fs.writeFileSync(registry, JSON.stringify({ vaults: {
    first: { path: 'C:\\Users\\HUAWEI\\Documents\\研究 + 笔记', ts: 20, open: true },
    second: { path: 'D:\\Archive', ts: 10, open: false }
  } }));
  const vaults = registeredVaults(registry);
  const vault = exactVault('c:\\users\\huawei\\documents\\研究 + 笔记', vaults);
  const note = 'C:\\Users\\HUAWEI\\Documents\\研究 + 笔记\\Reading Companion\\测试书.md';
  assert.equal(containingVault(note, vaults), vault);
  assert.equal(openURL(vault, note), 'obsidian://open?vault=%E7%A0%94%E7%A9%B6%20%2B%20%E7%AC%94%E8%AE%B0&file=Reading%20Companion%2F%E6%B5%8B%E8%AF%95%E4%B9%A6.md');
});
