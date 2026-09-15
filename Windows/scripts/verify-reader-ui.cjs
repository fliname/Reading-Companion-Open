const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const assert = require('node:assert/strict');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || '/Users/flamme/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');

const root = path.resolve(__dirname, '../src');
const outputDirectory = path.resolve(__dirname, '../tmp');
fs.mkdirSync(outputDirectory, { recursive: true });
const book = {
  title: '元数据书名',
  sections: [0, 1].map(sectionIndex => ({
    id: `s${sectionIndex}`,
    resourcePath: `${sectionIndex}.html`,
    startPageIndex: sectionIndex * 20,
    html: `<h1>第${sectionIndex + 1}章</h1>` + Array.from({ length: 80 }, (_, paragraphIndex) =>
      `<p>第${paragraphIndex + 1}段文字。${'用于验证电子书翻页、划线和浮窗定位。'.repeat(12)}</p>`).join('')
  })),
  navigation: []
};

const server = http.createServer((request, response) => {
  const target = path.join(root, decodeURIComponent(request.url.split('?')[0]));
  try {
    let data = fs.readFileSync(target);
    if (target.endsWith('app.mjs')) data = Buffer.concat([data, Buffer.from(
      '\nwindow.testApp={state,persist,openDocument,showBookshelf,handleReflowSelection,syncReflowMarks,systemPrompt};'
    )]);
    response.setHeader('Content-Type', /\.(mjs|js)$/.test(target) ? 'text/javascript' : target.endsWith('.css') ? 'text/css' : target.endsWith('.html') ? 'text/html' : 'application/octet-stream');
    response.end(data);
  } catch {
    response.statusCode = 404;
    response.end();
  }
});

(async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
  const page = await browser.newPage({ viewport: { width: 1500, height: 940 } });
  page.setDefaultTimeout(12000);
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => {
    if (message.type() === 'error' && !message.text().includes('Failed to load resource')) errors.push(message.text());
  });
  try {
    await page.addInitScript(({ book }) => {
      const saved = {};
      window.saved = saved;
      window.deleted = false;
      window.readingCompanion = new Proxy({
        edition: 'public',
        loadSettings: async () => ({ apiKey: 'test', model: 'test', models: ['test'] }),
        listObsidianVaults: async () => [], documentsPath: async () => '/tmp', joinPath: async (...parts) => parts.join('/'),
        getInitialProject: async () => 'C:\\Books\\文件名.epub',
        loadProject: async sourcePath => saved[sourcePath] || { bookCategory: 'nonfiction', lastPageIndex: 2 },
        saveProject: async (sourcePath, state) => { saved[sourcePath] = structuredClone(state); },
        importBook: async () => book, fileStat: async () => ({ size: 1234, modifiedAt: 0 }),
        listProjects: async () => Object.entries(saved).map(([sourcePath, state]) => ({ sourcePath, title: state.documentTitle, category: state.bookCategory, folderIDs: ['f1'], available: true })),
        listBookshelfFolders: async () => window.deleted ? [] : [{ id: 'f1', name: '待读', parentID: null }],
        deleteBookshelfFolder: async () => { window.deleted = true; },
        openProject: async () => null, onOpenProjectInPlace: () => null
      }, { get: (target, key) => target[key] ?? (async () => null) });
    }, { book });
    await page.goto(`http://127.0.0.1:${server.address().port}/renderer/index.html`);
    await page.waitForFunction(() => window.testApp?.state.documentReady);
    assert.equal(await page.textContent('#bookFileTitle'), '文件名');
    assert.equal(await page.isChecked('#ljgReadSkill'), true);
    assert.match(await page.evaluate(() => testApp.systemPrompt({ outputLimit: 1000 }, false, false, true)), /ljg-read/);
    await page.click('#ljgReadSkill');
    assert.equal(await page.evaluate(() => testApp.state.ljgReadSkillEnabled), false);
    assert.doesNotMatch(await page.evaluate(() => testApp.systemPrompt({ outputLimit: 1000 }, false, false, false)), /ljg-read/);
    await page.click('#ljgReadSkill');

    await page.evaluate(() => testApp.state.reflowReader.goToPage(2));
    await page.waitForTimeout(220);
    await page.click('#zoomIn');
    const pageBeforeArrow = Number(await page.inputValue('#pageField'));
    await page.keyboard.press('ArrowRight');
    await page.waitForTimeout(220);
    assert.ok(Number(await page.inputValue('#pageField')) > pageBeforeArrow);

    await page.evaluate(() => {
      const bounds = document.querySelector('#reflowContainer').getBoundingClientRect();
      testApp.handleReflowSelection({
        text: '页面下方选区', sectionID: 's0', start: 0, end: 6,
        anchors: [{ sectionID: 's0', start: 0, end: 6 }], location: 0,
        x: bounds.width / 2, y: bounds.height - 90, width: 100, height: 16
      });
    });
    const popupGeometry = await page.evaluate(() => {
      const toolbar = document.querySelector('#selectionToolbar');
      const container = document.querySelector('#reflowContainer').getBoundingClientRect();
      const rect = toolbar.getBoundingClientRect();
      return { top: rect.top, bottom: rect.bottom, anchorY: container.top + container.height - 74, viewportHeight: innerHeight };
    });
    assert.ok(popupGeometry.bottom <= popupGeometry.viewportHeight - 7);
    assert.ok(popupGeometry.top > popupGeometry.anchorY);
    await page.evaluate(() => document.querySelector('#selectionToolbar').classList.add('hidden'));

    await page.evaluate(() => {
      testApp.state.reflowReader.goToPage(0);
      testApp.state.highlights = [{
        id: 'saved-mark', text: '第1段', pageIndex: 0, color: 'yellow', kind: 'highlight', note: '',
        reflowAnchor: { sectionID: 's0', start: 3, end: 8 }, reflowAnchors: [{ sectionID: 's0', start: 3, end: 8 }]
      }];
      testApp.syncReflowMarks();
    });
    await page.waitForTimeout(250);
    const frame = page.frames().find(candidate => candidate.url() === 'about:srcdoc');
    const savedMarkBox = await frame.locator('.mark-yellow').first().boundingBox();
    assert.ok(savedMarkBox);
    await page.mouse.click(savedMarkBox.x + savedMarkBox.width / 2, savedMarkBox.y + savedMarkBox.height / 2);
    await page.waitForTimeout(120);
    assert.equal(await page.evaluate(() => testApp.state.selectedMarkID), 'saved-mark');
    assert.equal(await page.locator('#selectionToolbar').evaluate(node => node.classList.contains('hidden')), false);
    await page.click('[data-selection-highlight="blue"]');
    await page.waitForTimeout(120);
    assert.equal(await page.evaluate(() => testApp.state.highlights[0].color), 'blue');

    await page.evaluate(() => testApp.showBookshelf());
    await page.waitForTimeout(100);
    assert.equal(await page.locator('.folder-delete').count(), 0);
    await page.click('[data-action="toggle-select"]');
    assert.equal(await page.locator('.folder-delete').count(), 1);
    page.once('dialog', async dialog => {
      assert.match(dialog.message(), /只删除文件夹/);
      assert.match(dialog.message(), /书仍保留/);
      await dialog.accept();
    });
    await page.click('.folder-delete');
    await page.waitForTimeout(150);
    assert.equal(await page.locator('.folder-delete').count(), 0);
    assert.equal(await page.evaluate(() => window.deleted), true);
    assert.ok((await page.evaluate(() => Object.keys(saved).length)) > 0);

    assert.deepEqual(errors, []);
    await page.screenshot({ path: path.join(outputDirectory, 'windows-0.44.3-ui-smoke.png') });
    console.log('PASS: Skill switch, arrows, lower-page popup, saved highlight editing, batch-only folder deletion');
  } finally {
    await browser.close();
    server.close();
  }
})().catch(error => { console.error(error); server.close(); process.exitCode = 1; });
