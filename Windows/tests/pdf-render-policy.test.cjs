const test = require('node:test');
const assert = require('node:assert/strict');

test('普通 OCR 页面保持请求倍率', async () => {
  const { boundedRasterScale } = await import('../src/shared/pdf-render-policy.mjs');
  assert.equal(boundedRasterScale(600, 800, 1.8), 1.8);
});

test('超大扫描页按像素和单边尺寸预算降采样', async () => {
  const { boundedRasterScale } = await import('../src/shared/pdf-render-policy.mjs');
  const scale = boundedRasterScale(5000, 7000, 2);
  assert.ok(scale < 1);
  assert.ok(5000 * scale * 7000 * scale <= 12 * 1024 * 1024 + 1);
  assert.ok(7000 * scale <= 6144 + 1);
});
