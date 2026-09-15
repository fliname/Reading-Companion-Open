/**
 * BookCoverRenderer — renderer-process port of the macOS BookCoverRenderer.swift.
 *
 * Produces a 360×520 PNG cover. When image data (an EPUB cover, a PDF page
 * thumbnail, etc.) is supplied it is drawn with a "cover" fit (scaled to fill,
 * centered, cropping overflow). When the image cannot be decoded or is absent,
 * a deterministic fallback cover is generated from a hue derived from the title.
 *
 * Image decoding in the browser is asynchronous (Image.onload / createImageBitmap),
 * so `render` and `toDataURL` return Promises — the resolved value of `toDataURL`
 * is the data URL string, matching the macOS `pngData` return shape.
 */

const SIZE = { width: 360, height: 520 };

/**
 * Deterministic 31×hash over the title's unicode scalars, mirroring the Swift
 * `title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }`.
 * Iterating with for..of walks code points (surrogate pairs included).
 */
function hashTitle(title) {
  const text = String(title || '');
  let hash = 0;
  for (const ch of text) {
    hash = (Math.imul(hash, 31) + ch.codePointAt(0)) | 0;
  }
  return Math.abs(hash);
}

function hueForTitle(title) {
  return hashTitle(title) % 360;
}

/** Greedy per-character wrap that also tolerates CJK text without spaces. */
function wrapTitle(ctx, text, maxWidth) {
  const lines = [];
  let line = '';
  for (const ch of text) {
    const candidate = line + ch;
    if (ctx.measureText(candidate).width > maxWidth && line) {
      lines.push(line);
      line = ch === ' ' ? '' : ch;
    } else {
      line = candidate;
    }
  }
  if (line) lines.push(line);
  return lines.length ? lines : [text];
}

/** Letter-spaced text drawn manually so it works without ctx.letterSpacing. */
function drawSpacedText(ctx, text, x, y, spacing, align) {
  const chars = [...text];
  const widths = chars.map(ch => ctx.measureText(ch).width);
  const total = widths.reduce((sum, w) => sum + w, 0) + spacing * Math.max(0, chars.length - 1);
  let startX;
  if (align === 'center') startX = x - total / 2;
  else if (align === 'right') startX = x - total;
  else startX = x;
  const previousAlign = ctx.textAlign;
  ctx.textAlign = 'left';
  let cursor = startX;
  for (let i = 0; i < chars.length; i++) {
    ctx.fillText(chars[i], cursor, y);
    cursor += widths[i] + spacing;
  }
  ctx.textAlign = previousAlign;
}

function loadFromURL(url, revoke) {
  return new Promise(resolve => {
    const img = new Image();
    img.onload = () => {
      if (revoke) URL.revokeObjectURL(url);
      resolve(img.width > 0 && img.height > 0 ? img : null);
    };
    img.onerror = () => {
      if (revoke) URL.revokeObjectURL(url);
      resolve(null);
    };
    img.src = url;
  });
}

/**
 * Accepts a base64 data URI string, a raw base64 string, an ArrayBuffer, or a
 * typed array. Resolves to a decodable image (Image or ImageBitmap) or null.
 */
function loadImage(source) {
  if (!source) return Promise.resolve(null);
  if (typeof source === 'string') {
    const src = source.startsWith('data:') ? source : `data:image/png;base64,${source}`;
    return loadFromURL(src, false);
  }
  if (source instanceof ArrayBuffer || ArrayBuffer.isView(source)) {
    const data = source instanceof ArrayBuffer ? source : source.buffer;
    if (typeof createImageBitmap === 'function') {
      return createImageBitmap(data)
        .then(bitmap => (bitmap && bitmap.width > 0 ? bitmap : null))
        .catch(() => null);
    }
    const url = URL.createObjectURL(new Blob([data]));
    return loadFromURL(url, true);
  }
  return Promise.resolve(null);
}

function drawImageCover(ctx, img) {
  // White backdrop, identical to NSColor.white.setFill() in the Swift port.
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, SIZE.width, SIZE.height);
  // Cover fit: scale to fill, center, crop overflow.
  const scale = Math.max(SIZE.width / img.width, SIZE.height / img.height);
  const drawWidth = img.width * scale;
  const drawHeight = img.height * scale;
  const dx = (SIZE.width - drawWidth) / 2;
  const dy = (SIZE.height - drawHeight) / 2;
  ctx.drawImage(img, dx, dy, drawWidth, drawHeight);
}

function drawGeneratedCover(ctx, title) {
  const hue = hueForTitle(title);

  // Background: hsl(hue, 65%, 32%)
  ctx.fillStyle = `hsl(${hue}, 65%, 32%)`;
  ctx.fillRect(0, 0, SIZE.width, SIZE.height);

  const cleanTitle = String(title || '').trim() || '未命名书籍';

  // Title: white, centered, wrapped, 20px
  ctx.fillStyle = '#ffffff';
  ctx.font = '600 20px -apple-system, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  const maxWidth = SIZE.width - 80;
  const lines = wrapTitle(ctx, cleanTitle, maxWidth);
  const lineHeight = 30;
  const totalHeight = lines.length * lineHeight;
  const blockTop = SIZE.height / 2 - totalHeight / 2;
  lines.forEach((line, i) => {
    ctx.fillText(line, SIZE.width / 2, blockTop + i * lineHeight + lineHeight / 2);
  });

  // A subtle decorative line just above the title block.
  ctx.fillStyle = 'rgba(255,255,255,0.5)';
  ctx.fillRect(SIZE.width / 2 - 22, blockTop - 36, 44, 2);

  // "READING COMPANION" mark at the bottom — smaller, semi-transparent white.
  ctx.fillStyle = 'rgba(255,255,255,0.72)';
  ctx.font = '500 9px -apple-system, "Segoe UI", sans-serif';
  drawSpacedText(ctx, 'READING COMPANION', SIZE.width / 2, SIZE.height - 44, 1.8, 'center');
}

export const BookCoverRenderer = {
  /** Bumped whenever the generated cover layout changes, for cache invalidation. */
  version: 2,

  /**
   * Render a cover onto the given canvas element.
   * @param {HTMLCanvasElement} canvas
   * @param {{ imageData?: string|ArrayBuffer, title?: string }} options
   * @returns {Promise<HTMLCanvasElement>}
   */
  async render(canvas, { imageData, title } = {}) {
    if (!canvas) throw new Error('BookCoverRenderer.render requires a canvas element.');
    if (canvas.width !== SIZE.width) canvas.width = SIZE.width;
    if (canvas.height !== SIZE.height) canvas.height = SIZE.height;
    const ctx = canvas.getContext('2d');
    if (!ctx) throw new Error('BookCoverRenderer.render: 2D context unavailable.');

    let drawn = false;
    if (imageData) {
      try {
        const img = await loadImage(imageData);
        if (img && img.width > 0 && img.height > 0) {
          drawImageCover(ctx, img);
          drawn = true;
        }
      } catch {
        drawn = false;
      }
    }
    if (!drawn) drawGeneratedCover(ctx, title);
    return canvas;
  },

  /**
   * Render a cover and return its PNG data URL string.
   * @param {{ imageData?: string|ArrayBuffer, title?: string }} options
   * @returns {Promise<string>}
   */
  async toDataURL(options = {}) {
    const canvas = document.createElement('canvas');
    await this.render(canvas, options);
    return canvas.toDataURL('image/png');
  },
};

export default BookCoverRenderer;
