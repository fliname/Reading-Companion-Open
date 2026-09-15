const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const AdmZip = require('adm-zip');

function temporaryDirectory(t, prefix) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  return directory;
}

test('EPUB 导入生成递增稳定位置并把导航映射到对应章节', t => {
  const directory = temporaryDirectory(t, 'rc-epub-044-');
  const target = path.join(directory, 'sample.epub');
  const zip = new AdmZip();
  zip.addFile('mimetype', Buffer.from('application/epub+zip'));
  zip.addFile('META-INF/container.xml', Buffer.from(`<?xml version="1.0"?><container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>`));
  zip.addFile('OEBPS/content.opf', Buffer.from(`<?xml version="1.0"?><package><metadata><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">测试书</dc:title></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>`));
  zip.addFile('OEBPS/nav.xhtml', Buffer.from(`<html><body><nav epub:type="toc"><ol><li><a href="one.xhtml">第一章</a></li><li><a href="two.xhtml">第二章</a></li></ol></nav></body></html>`));
  zip.addFile('OEBPS/one.xhtml', Buffer.from(`<html><body><h1>第一章</h1><p>${'甲'.repeat(850)}</p></body></html>`));
  zip.addFile('OEBPS/two.xhtml', Buffer.from(`<html><body><h1>第二章</h1><p>${'乙'.repeat(80)}</p></body></html>`));
  zip.writeZip(target);

  const { EPUBImporter } = require('../src/main/epub-importer.cjs');
  const book = EPUBImporter.importBook(target);
  assert.equal(book.title, '测试书');
  assert.deepEqual(book.sections.map(section => section.startPageIndex), [0, 2]);
  assert.deepEqual(book.sections.map(section => section.pageCount), [2, 1]);
  assert.deepEqual(book.navigation.map(entry => [entry.title, entry.location]), [['第一章', 0], ['第二章', 2]]);
  assert.match(book.sourceFingerprint, /^\d+\|\d+$/);
});

test('没有 NAV/NCX 的 EPUB 会从正文标题生成可用目录', t => {
  const directory = temporaryDirectory(t, 'rc-epub-headings-044-');
  const target = path.join(directory, 'headings.epub');
  const zip = new AdmZip();
  zip.addFile('mimetype', Buffer.from('application/epub+zip'));
  zip.addFile('META-INF/container.xml', Buffer.from('<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>'));
  zip.addFile('OPS/book.opf', Buffer.from('<package><metadata><title>无导航书</title></metadata><manifest><item id="body" href="body.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="body"/></spine></package>'));
  zip.addFile('OPS/body.xhtml', Buffer.from('<html><body><h1>第一&amp;章</h1><p>正文</p><h2>第一节</h2></body></html>'));
  zip.writeZip(target);

  const { EPUBImporter } = require('../src/main/epub-importer.cjs');
  const book = EPUBImporter.importBook(target);
  assert.deepEqual(book.navigation.map(entry => [entry.title, entry.level, entry.location]), [
    ['第一&章', 0, 0],
    ['第一节', 1, 0],
  ]);
});

test('EPUB 正文图片支持父目录、URL 编码、大小写差异和 SVG 引用', t => {
  const directory = temporaryDirectory(t, 'rc-epub-images-044-');
  const target = path.join(directory, 'images.epub');
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=', 'base64');
  const zip = new AdmZip();
  zip.addFile('mimetype', Buffer.from('application/epub+zip'));
  zip.addFile('META-INF/container.xml', Buffer.from('<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>'));
  zip.addFile('OEBPS/content.opf', Buffer.from('<package><metadata><title>图片书</title></metadata><manifest><item id="body" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/><item id="picture" href="Images/Plate One.png" media-type="image/png"/></manifest><spine><itemref idref="body"/></spine></package>'));
  zip.addFile('OEBPS/Text/chapter.xhtml', Buffer.from('<html><body><p>正文</p><img src="../images/Plate%20One.PNG?edition=1#figure"/><svg><image xlink:href="../Images/Plate%20One.png"/></svg></body></html>'));
  zip.addFile('OEBPS/Images/Plate One.png', png);
  zip.writeZip(target);

  const { EPUBImporter } = require('../src/main/epub-importer.cjs');
  const html = EPUBImporter.importBook(target).sections[0].html;
  assert.equal((html.match(/data:image\/png;base64,/g) || []).length, 2);
  assert.doesNotMatch(html, /\.\.\/Images|\.\.\/images/i);
});

test('0.44 书架迁移强制旧书重新分类，并支持多文件夹与电子书缓存', t => {
  const directory = temporaryDirectory(t, 'rc-store-044-');
  const source = path.join(directory, 'book.epub');
  fs.writeFileSync(source, 'book');
  const safeStorage = {
    isEncryptionAvailable: () => false,
    encryptString: value => Buffer.from(value),
    decryptString: value => value.toString('utf8')
  };
  const { ReadingStore } = require('../src/main/store.cjs');
  const store = new ReadingStore(directory, safeStorage);
  store.writeJSON(store.projectsPath(), [{ sourcePath: source, title: '旧书', category: 'fiction', folderID: null }]);
  store.writeJSON(store.projectPath(source), { documentTitle: '旧书', bookCategory: 'fiction' });

  assert.equal(store.listProjects()[0].category, null);
  assert.equal(store.loadProject(source).bookCategory, null);
  assert.equal(store.setProjectsCategory([source], 'fiction'), true);
  assert.equal(store.loadProject(source).bookCategory, 'fiction');

  const first = store.createBookshelfFolder('研究');
  const second = store.createBookshelfFolder('待读');
  store.setProjectsFolderMembership([source], first.id, true);
  store.setProjectsFolderMembership([source], second.id, true);
  assert.deepEqual(new Set(store.listProjects()[0].folderIDs), new Set([first.id, second.id]));
  store.setProjectsFolderMembership([source], first.id, false);
  assert.deepEqual(store.listProjects()[0].folderIDs, [second.id]);

  store.saveReflowCache(source, '4|1', 4, { title: '旧书', sections: [], coverImageData: Buffer.from([1, 2, 3]) });
  const cached = store.loadReflowCache(source, '4|1', 4);
  assert.deepEqual([...cached.coverImageData], [1, 2, 3]);
  assert.equal(store.loadReflowCache(source, 'changed', 4), null);
});

test('人物批量格式、别名匹配与自动配色符合虚构类人物系统', async () => {
  const { CharacterManager } = await import('../src/shared/characters.mjs');
  const manager = new CharacterManager();
  assert.equal(manager.addFromBatch('阿辽沙：幼子\n伊万|万尼亚、Ivan|兄长'), 2);
  manager.assignUniqueColors();
  assert.deepEqual(manager.characters.map(character => character.name), ['阿辽沙', '伊万']);
  assert.deepEqual(manager.characters[1].aliases, ['万尼亚', 'Ivan']);
  assert.equal(new Set(manager.characters.map(character => character.colorHex)).size, 2);
  assert.deepEqual(manager.occurrences('伊万遇见Ivan，万尼亚离开。', manager.characters[1].id).map(hit => hit.name), ['伊万', 'Ivan', '万尼亚']);
});

test('Windows 0.44.3 基于 0.44.1 并将独立 libmobi 转换器作为额外资源', () => {
  const root = path.join(__dirname, '..');
  const packageJSON = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
  assert.equal(packageJSON.version, '0.44.3');
  assert.ok(packageJSON.build.extraResources.some(resource => resource.to === 'BookConverter' && resource.filter.includes('mobitool.exe')));
  assert.ok(fs.existsSync(path.join(root, 'vendor', 'libmobi-0.12', 'COPYING')));
  assert.ok(fs.existsSync(path.join(root, 'resources', 'BookConverter', 'COPYING.LGPL-3.0')));
  const files = packageJSON.build.files;
  assert.ok(files.includes('!**/EnhancedTOC/**'));
  assert.ok(files.includes('!node_modules/@napi-rs/**'));
  assert.deepEqual(packageJSON.build.electronLanguages, ['en-US', 'zh-CN']);
  assert.ok(files.includes('node_modules/tesseract.js-core/**/*-lstm.wasm'));
});

test('轻量自动目录引擎优先使用原生目录且不依赖 OCR', async () => {
  const { recognizeAutomaticOutline } = await import('../src/shared/auto-toc.mjs');
  let refreshCount = 0;
  const native = [{ id: 'native', title: '第一章', pageIndex: 3, level: 0 }];
  const result = await recognizeAutomaticOutline({
    pages: [{ pageIndex: 0, text: '' }],
    readNativeOutline: async () => native,
    refreshPage: async () => { refreshCount += 1; },
  });
  assert.equal(result.outline, native);
  assert.equal(refreshCount, 0);
});
