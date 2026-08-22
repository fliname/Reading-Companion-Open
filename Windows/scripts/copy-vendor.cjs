const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const vendor = path.join(root, 'src', 'renderer', 'vendor');
fs.mkdirSync(vendor, { recursive: true });

const copies = [
  ['pdfjs-dist/build/pdf.mjs', 'pdf.mjs'],
  ['pdfjs-dist/build/pdf.worker.mjs', 'pdf.worker.mjs'],
  ['pdfjs-dist/web/pdf_viewer.mjs', 'pdf_viewer.mjs'],
  ['pdfjs-dist/web/pdf_viewer.css', 'pdf_viewer.css'],
  ['marked', 'marked.esm.js']
];

for (const [modulePath, target] of copies) {
  fs.copyFileSync(require.resolve(modulePath), path.join(vendor, target));
}

const pdfRoot = path.dirname(require.resolve('pdfjs-dist/package.json'));
for (const directory of ['cmaps', 'standard_fonts', 'wasm']) {
  fs.cpSync(path.join(pdfRoot, directory), path.join(vendor, directory), { recursive: true });
}
