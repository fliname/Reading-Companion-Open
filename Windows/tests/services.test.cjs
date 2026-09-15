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

test('虚构类伴读不加载学术框架或碰撞问题并限制为短回答', () => {
  const { freeCompanionInstructions, freeModeBudgetInstructions, fictionPageRangeSummaryInstructions } = require('../src/main/ai-service.cjs');
  assert.match(freeCompanionInstructions, /不加载学术伴读框架/);
  assert.match(freeCompanionInstructions, /不追加碰撞问题/);
  assert.match(freeModeBudgetInstructions, /120–300/);
  assert.match(fictionPageRangeSummaryInstructions, /150–250/);
});

test('深读回答达到单次输出上限后自动续写而不抛错', async () => {
  const originalFetch = global.fetch;
  const payloads = [
    { choices: [{ message: { content: '前半段，' }, finish_reason: 'length' }], usage: { prompt_tokens: 10, completion_tokens: 3 } },
    { choices: [{ message: { content: '后半段完整结束。' }, finish_reason: 'stop' }], usage: { prompt_tokens: 14, completion_tokens: 5 } }
  ];
  global.fetch = async () => new Response(JSON.stringify(payloads.shift()), { headers: { 'content-type': 'application/json' } });
  try {
    const { requestAI } = require('../src/main/ai-service.cjs');
    let streamed = '';
    const result = await requestAI({
      id: 'continuation-test', apiKey: 'test', baseURL: 'https://example.com/v1', model: 'test-model',
      system: 'test', messages: [{ role: 'user', content: '回答' }], maxTokens: 8000,
      maxContinuations: 3, reasoningEffort: 'medium'
    }, delta => { streamed += delta; });
    assert.equal(result.text, '前半段，后半段完整结束。');
    assert.equal(streamed, result.text);
    assert.equal(result.continuationCount, 1);
    assert.equal(result.incomplete, false);
    assert.deepEqual(result.usage, { inputTokens: 24, outputTokens: 8, cachedTokens: 0, reasoningTokens: 0 });
  } finally {
    global.fetch = originalFetch;
  }
});

test('多次触顶后用短结论强制收束并保留答案', async () => {
  const originalFetch = global.fetch;
  const payloads = [
    { choices: [{ message: { content: '主体论证。' }, finish_reason: 'length' }] },
    { choices: [{ message: { content: '补充论证。' }, finish_reason: 'length' }] },
    { choices: [{ message: { content: '最终结论。' }, finish_reason: 'stop' }] }
  ];
  global.fetch = async () => new Response(JSON.stringify(payloads.shift()), { headers: { 'content-type': 'application/json' } });
  try {
    const { requestAI } = require('../src/main/ai-service.cjs');
    const result = await requestAI({
      id: 'compact-rescue-test', apiKey: 'test', baseURL: 'https://example.com/v1', model: 'test-model',
      system: 'test', messages: [{ role: 'user', content: '回答' }], maxTokens: 8000,
      maxContinuations: 1, reasoningEffort: 'medium'
    });
    assert.equal(result.text, '主体论证。补充论证。最终结论。');
    assert.equal(result.usedCompactRescue, true);
    assert.equal(result.incomplete, false);
    assert.equal(result.continuationCount, 2);
  } finally {
    global.fetch = originalFetch;
  }
});

test('更新服务只选择版本更高的 Windows 安装包', () => {
  const { compareVersions, selectWindowsUpdate } = require('../src/main/update-service.cjs');
  assert.equal(compareVersions('0.43.23', '0.43.22'), 1);
  const release = { assets: [
    { name: 'Reading-Companion-Open-0.43.12-macOS-arm64.dmg', browser_download_url: 'https://example.com/mac' },
    { name: 'Reading-Companion-Open-0.43.23-Windows-x64-Setup.exe', browser_download_url: 'https://example.com/win', size: 123 }
  ] };
  assert.equal(selectWindowsUpdate(release, '0.43.22').version, '0.43.23');
  assert.equal(selectWindowsUpdate(release, '0.43.23'), null);
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
