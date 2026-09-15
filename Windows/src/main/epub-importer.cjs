'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const AdmZip = require('adm-zip');

const MAX_IMAGE_BYTES = 25 * 1024 * 1024;
const MAX_TOTAL_UNCOMPRESSED_BYTES = 1024 * 1024 * 1024;

function sha256(value) {
  return crypto.createHash('sha256').update(String(value), 'utf8').digest('hex');
}

function localName(tagName) {
  const idx = tagName.indexOf(':');
  return (idx >= 0 ? tagName.slice(idx + 1) : tagName).toLowerCase();
}

function decodeXMLAttributes(tagText) {
  const attrs = {};
  const re = /([a-zA-Z_:][\w:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/g;
  let m;
  while ((m = re.exec(tagText)) !== null) {
    attrs[m[1].toLowerCase()] = m[2] !== undefined ? m[2] : m[3];
  }
  return attrs;
}

function canonicalPath(value) {
  const noFragment = String(value).split(/[?#]/)[0];
  try {
    return decodeURIComponent(noFragment);
  } catch {
    return noFragment;
  }
}

function resolveZipPath(baseDir, relativePath) {
  const cleanHref = canonicalPath(relativePath);
  if (!cleanHref) return '';
  const combined = baseDir ? `${baseDir}/${cleanHref}` : cleanHref;
  const parts = [];
  for (const part of combined.split('/')) {
    if (part === '' || part === '.') continue;
    if (part === '..') { parts.pop(); continue; }
    parts.push(part);
  }
  return parts.join('/');
}

function resolveRelative(href, documentPath) {
  const baseDir = documentPath.includes('/')
    ? documentPath.split('/').slice(0, -1).join('/')
    : '';
  return resolveZipPath(baseDir, href);
}

function decodeEntryText(buffer) {
  let data = buffer;
  if (data.length >= 3 && data[0] === 0xef && data[1] === 0xbb && data[2] === 0xbf) {
    data = data.subarray(3);
  }
  if (data.length >= 2 &&
      ((data[0] === 0xff && data[1] === 0xfe) || (data[0] === 0xfe && data[1] === 0xff))) {
    return data.toString('utf16le');
  }
  return data.toString('utf8');
}

function stripXMLComments(xml) {
  return xml.replace(/<!--[\s\S]*?-->/g, '');
}

// --- XML parsers (regex-based, mirroring the Swift XMLParserDelegate flow) ---

function parseContainer(xml) {
  const m = /<rootfile\b[^>]*>/i.exec(stripXMLComments(xml));
  if (!m) return null;
  return decodeXMLAttributes(m[0])['full-path'] || null;
}

function parseOPF(xml) {
  const pkg = {
    title: '',
    manifest: new Map(),
    spine: [],
    tocID: null,
    coverID: null,
  };
  const cleaned = stripXMLComments(xml);

  const metadataMatch = /<metadata\b[^>]*>([\s\S]*?)<\/metadata\s*>/i.exec(cleaned);
  if (metadataMatch) {
    const block = metadataMatch[1];
    const titleRe = /<(?:[a-zA-Z][\w:.-]*:)?title\b[^>]*>([\s\S]*?)<\/(?:[a-zA-Z][\w:.-]*:)?title\s*>/gi;
    let tm;
    while ((tm = titleRe.exec(block)) !== null) {
      pkg.title += tm[1];
    }
    const metaRe = /<meta\b[^>]*>/gi;
    let mm;
    while ((mm = metaRe.exec(block)) !== null) {
      const attrs = decodeXMLAttributes(mm[0]);
      if ((attrs['name'] || '').toLowerCase() === 'cover') {
        pkg.coverID = attrs['content'] || null;
      }
    }
  }

  const manifestMatch = /<manifest\b[^>]*>([\s\S]*?)<\/manifest\s*>/i.exec(cleaned);
  if (manifestMatch) {
    const itemRe = /<item\b[^>]*>/gi;
    let im;
    while ((im = itemRe.exec(manifestMatch[1])) !== null) {
      const attrs = decodeXMLAttributes(im[0]);
      const id = attrs['id'];
      const href = attrs['href'];
      if (!id || !href) continue;
      pkg.manifest.set(id, {
        href,
        mediaType: attrs['media-type'] || '',
        properties: attrs['properties'] || '',
      });
    }
  }

  const spineOpenMatch = /<spine\b[^>]*>/i.exec(cleaned);
  if (spineOpenMatch) {
    pkg.tocID = decodeXMLAttributes(spineOpenMatch[0])['toc'] || null;
  }
  const spineMatch = /<spine\b[^>]*>([\s\S]*?)<\/spine\s*>/i.exec(cleaned);
  if (spineMatch) {
    const itemrefRe = /<itemref\b[^>]*>/gi;
    let ir;
    while ((ir = itemrefRe.exec(spineMatch[1])) !== null) {
      const attrs = decodeXMLAttributes(ir[0]);
      const idref = attrs['idref'];
      if (!idref) continue;
      if ((attrs['linear'] || '').toLowerCase() === 'no') continue;
      pkg.spine.push(idref);
    }
  }

  return pkg;
}

function parseNav(xml) {
  const cleaned = stripXMLComments(xml);
  const items = [];
  let insideTOC = false;
  let navDepth = 0;
  let listDepth = 0;
  let activeHref = null;
  let activeTitle = '';

  const tokenRe = /<(\/?)([a-zA-Z][\w:-]*)([^>]*)>|([^<]+)/g;
  let tok;
  while ((tok = tokenRe.exec(cleaned)) !== null) {
    if (tok[4] !== undefined) {
      if (activeHref !== null) activeTitle += tok[4];
      continue;
    }
    const closing = tok[1] === '/';
    const name = localName(tok[2]);
    const attrs = closing ? {} : decodeXMLAttributes(tok[3]);

    if (name === 'nav') {
      if (!closing) {
        const type = (attrs['epub:type'] || attrs['type'] || '').toLowerCase();
        if (!insideTOC && type.includes('toc')) {
          insideTOC = true;
          navDepth = 1;
        } else if (insideTOC) {
          navDepth += 1;
        }
      } else if (insideTOC) {
        navDepth -= 1;
        if (navDepth <= 0) {
          insideTOC = false;
          listDepth = 0;
        }
      }
      continue;
    }
    if (!insideTOC) continue;
    if (name === 'ol' || name === 'ul') {
      if (!closing) listDepth += 1;
      else listDepth = Math.max(listDepth - 1, 0);
      continue;
    }
    if (name === 'a') {
      if (!closing) {
        if (attrs['href'] !== undefined) {
          activeHref = attrs['href'];
          activeTitle = '';
        }
      } else if (activeHref !== null) {
        items.push({
          title: activeTitle.trim(),
          relativePath: activeHref,
          level: Math.max(listDepth - 1, 0),
        });
        activeHref = null;
        activeTitle = '';
      }
    }
  }
  return items;
}

function parseNCX(xml) {
  const cleaned = stripXMLComments(xml);
  const items = [];
  const frames = [];
  let capturesLabel = false;

  const tokenRe = /<(\/?)([a-zA-Z][\w:-]*)([^>]*)>|([^<]+)/g;
  let tok;
  while ((tok = tokenRe.exec(cleaned)) !== null) {
    if (tok[4] !== undefined) {
      if (capturesLabel && frames.length) {
        frames[frames.length - 1].title += tok[4];
      }
      continue;
    }
    const closing = tok[1] === '/';
    const name = localName(tok[2]);
    const attrs = closing ? {} : decodeXMLAttributes(tok[3]);

    if (name === 'navpoint') {
      if (!closing) {
        const level = frames.length;
        const outputIndex = items.length;
        items.push({ title: '', relativePath: '', level });
        frames.push({ level, outputIndex, title: '', href: null });
      } else {
        const frame = frames.pop();
        if (!frame) continue;
        if (frame.href) {
          items[frame.outputIndex] = {
            title: frame.title.trim(),
            relativePath: frame.href,
            level: frame.level,
          };
        } else {
          items.splice(frame.outputIndex, 1);
          for (const f of frames) {
            if (f.outputIndex > frame.outputIndex) f.outputIndex -= 1;
          }
        }
      }
      continue;
    }
    if (name === 'text') {
      capturesLabel = !closing && frames.length > 0;
      continue;
    }
    if (name === 'content' && !closing && frames.length) {
      const src = attrs['src'];
      if (src) frames[frames.length - 1].href = src;
    }
  }
  return items;
}

// --- HTML sanitization (ports ReflowBookBuilder) ---

function bodyHTML(source) {
  const m = /<body\b[^>]*>([\s\S]*?)<\/body\s*>/i.exec(source);
  return m ? m[1] : source;
}

function mimeTypeFor(ext) {
  switch (ext.toLowerCase()) {
    case 'jpg':
    case 'jpeg': return 'image/jpeg';
    case 'gif': return 'image/gif';
    case 'webp': return 'image/webp';
    case 'svg': return 'image/svg+xml';
    default: return 'image/png';
  }
}

function embedImages(source, sectionZipPath, resolveEntryBuffer) {
  const sectionDir = sectionZipPath.includes('/')
    ? sectionZipPath.split('/').slice(0, -1).join('/')
    : '';
  const re = /\b(src|(?:xlink:)?href)\s*=\s*(["'])([^"']+)\2/gi;
  const matches = [];
  let m;
  while ((m = re.exec(source)) !== null) matches.push(m);
  let html = source;
  for (let i = matches.length - 1; i >= 0; i--) {
    const match = matches[i];
    const attributeName = match[1];
    if (attributeName.toLowerCase() !== 'src') {
      const tagStart = source.lastIndexOf('<', match.index);
      const tagPrefix = tagStart >= 0 ? source.slice(tagStart, match.index) : '';
      if (!/^<\s*image\b/i.test(tagPrefix)) continue;
    }
    const rawPath = match[3];
    if (/^data:/i.test(rawPath) || rawPath.includes('://')) continue;
    const cleaned = canonicalPath(rawPath);
    if (!cleaned) continue;
    const zipPath = resolveZipPath(sectionDir, cleaned);
    if (!zipPath) continue;
    const data = resolveEntryBuffer(zipPath);
    if (!data || data.length === 0 || data.length > MAX_IMAGE_BYTES) continue;
    const ext = path.extname(cleaned).slice(1);
    const replacement = `${attributeName}="data:${mimeTypeFor(ext)};base64,${data.toString('base64')}"`;
    html = html.slice(0, match.index) + replacement + html.slice(match.index + match[0].length);
  }
  return html;
}

function sanitizeHTML(source, sectionZipPath, resolveEntryBuffer) {
  let html = source;
  // Strip script/style/iframe/object/embed blocks (open + close)
  html = html.replace(/<(script|style|iframe|object|embed)\b[^>]*>[\s\S]*?<\/\1\s*>/gi, '');
  // Strip self-closing variants
  html = html.replace(/<(script|style|iframe|object|embed)\b[^>]*\/\s*>/gi, '');
  // Remove style and on* event handler attributes
  html = html.replace(/\s(?:style|on[a-z]+)\s*=\s*(?:"[^"]*"|'[^']*')/gi, '');
  // Embed local images as base64 data URIs
  html = embedImages(html, sectionZipPath, resolveEntryBuffer);
  // Remove network src/href (javascript:, https:, http:, file:)
  html = html.replace(/\s(?:src|href)\s*=\s*(["'])\s*(?:javascript:|https?:\/\/|file:)[^"']*\1/gi, '');
  return html;
}

function approximatePageCount(html) {
  const plain = String(html || '')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&(?:nbsp|#160);/gi, ' ')
    .replace(/&[^;]{1,12};/g, 'x')
    .replace(/\s+/g, ' ')
    .trim();
  // Stable logical locations are deliberately independent of the live reader
  // width/font. About 700 CJK characters matches the A5 reference pagination
  // used by the macOS importer's hidden searchable document.
  return Math.max(1, Math.ceil([...plain].length / 700));
}

function plainHeadingText(value) {
  return String(value || '')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&#(\d+);/g, (_, code) => String.fromCodePoint(Number(code)))
    .replace(/&#x([0-9a-f]+);/gi, (_, code) => String.fromCodePoint(parseInt(code, 16)))
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/&apos;/gi, "'")
    .replace(/\s+/g, ' ')
    .trim();
}

function inferNavigationFromHeadings(sections) {
  const navigation = [];
  for (const section of sections) {
    const headingRE = /<h([1-6])\b[^>]*>([\s\S]*?)<\/h\1\s*>/gi;
    let match;
    while ((match = headingRE.exec(section.html || '')) !== null) {
      const title = plainHeadingText(match[2]);
      if (!title) continue;
      navigation.push({
        title,
        relativePath: section.resourcePath,
        level: Math.max(0, Number(match[1]) - 1),
        location: section.startPageIndex,
      });
    }
  }
  return navigation;
}

// --- EPUB archive reader ---

function readPublication(sourcePath, progress) {
  if (typeof progress === 'function') progress(0.12, '正在解包并读取电子书…');

  let zip;
  try {
    zip = new AdmZip(sourcePath);
  } catch (error) {
    throw new Error(`无法解包 EPUB：${error.message || error}`);
  }

  const entries = zip.getEntries();
  const entriesByLowerPath = new Map(entries.map(entry => [
    entry.entryName.replace(/\\/g, '/').toLowerCase(), entry
  ]));
  let totalUncompressed = 0;
  for (const entry of entries) {
    totalUncompressed += entry.header.size;
    if (totalUncompressed > MAX_TOTAL_UNCOMPRESSED_BYTES) {
      throw new Error('解包后的 EPUB 超过 1 GB，已停止导入');
    }
  }

  const resolveEntryBuffer = (zipPath) => {
    if (!zipPath) return null;
    const entry = zip.getEntry(zipPath) || entriesByLowerPath.get(zipPath.replace(/\\/g, '/').toLowerCase());
    if (!entry) return null;
    return entry.getData();
  };

  const containerEntry = zip.getEntry('META-INF/container.xml');
  if (!containerEntry) {
    throw new Error('这份 EPUB 的容器信息不完整或已经损坏。');
  }
  const containerXML = decodeEntryText(containerEntry.getData());
  const rootPath = parseContainer(containerXML);
  if (!rootPath) {
    throw new Error('这份 EPUB 的容器信息不完整或已经损坏。');
  }
  const opfEntry = zip.getEntry(rootPath);
  if (!opfEntry) {
    throw new Error('这份 EPUB 缺少书籍清单（OPF）。');
  }
  const opfXML = decodeEntryText(opfEntry.getData());
  const pkg = parseOPF(opfXML);
  const opfDir = rootPath.includes('/') ? rootPath.split('/').slice(0, -1).join('/') : '';

  // Build sections from spine HTML items
  const sections = [];
  for (const idref of pkg.spine) {
    const item = pkg.manifest.get(idref);
    if (!item) continue;
    if (!item.mediaType.includes('html')) continue;
    const zipPath = resolveZipPath(opfDir, item.href);
    if (!zipPath) continue;
    const entry = zip.getEntry(zipPath);
    if (!entry) continue;
    sections.push({
      relativePath: canonicalPath(item.href),
      zipPath,
      entry,
    });
  }
  if (sections.length === 0) {
    throw new Error('这份 EPUB 中没有可阅读的正文。');
  }

  // Navigation: EPUB 3 nav.xhtml first, then EPUB 2 NCX
  let navigation = [];
  let navItem = null;
  for (const item of pkg.manifest.values()) {
    if ((item.properties || '').split(/\s+/).includes('nav')) { navItem = item; break; }
  }
  if (navItem) {
    const navZipPath = resolveZipPath(opfDir, navItem.href);
    const navEntry = navZipPath ? zip.getEntry(navZipPath) : null;
    if (navEntry) {
      const navXML = decodeEntryText(navEntry.getData());
      navigation = parseNav(navXML).map(it => ({
        title: it.title,
        relativePath: resolveRelative(it.relativePath, navItem.href),
        level: it.level,
      }));
    }
  }
  if (navigation.length === 0 && pkg.tocID) {
    const ncxItem = pkg.manifest.get(pkg.tocID);
    if (ncxItem) {
      const ncxZipPath = resolveZipPath(opfDir, ncxItem.href);
      const ncxEntry = ncxZipPath ? zip.getEntry(ncxZipPath) : null;
      if (ncxEntry) {
        const ncxXML = decodeEntryText(ncxEntry.getData());
        navigation = parseNCX(ncxXML).map(it => ({
          title: it.title,
          relativePath: resolveRelative(it.relativePath, ncxItem.href),
          level: it.level,
        }));
      }
    }
  }

  // Cover image: cover-image property > meta cover > manifest item with "cover" in id/href
  let coverItem = null;
  for (const item of pkg.manifest.values()) {
    if ((item.properties || '').split(/\s+/).includes('cover-image')) {
      coverItem = item;
      break;
    }
  }
  if (!coverItem && pkg.coverID) {
    coverItem = pkg.manifest.get(pkg.coverID) || null;
  }
  if (!coverItem) {
    for (const [id, item] of pkg.manifest) {
      if (!item.mediaType.startsWith('image/')) continue;
      if (id.toLowerCase().includes('cover') || item.href.toLowerCase().includes('cover')) {
        coverItem = item;
        break;
      }
    }
  }
  let coverImageData = null;
  if (coverItem) {
    const coverZipPath = resolveZipPath(opfDir, coverItem.href);
    const coverEntry = coverZipPath ? zip.getEntry(coverZipPath) : null;
    if (coverEntry) coverImageData = coverEntry.getData();
  }

  const fallbackTitle = path.basename(sourcePath, path.extname(sourcePath));
  const title = (pkg.title || '').trim() || fallbackTitle;

  if (typeof progress === 'function') progress(0.36, '目录与正文已读取，正在生成阅读排版…');

  return { title, sections, navigation, coverImageData, resolveEntryBuffer };
}

// --- EPUBImporter public API ---

const EPUBImporter = {
  importBook(sourcePath, options = {}) {
    const progress = options && typeof options.progress === 'function' ? options.progress : null;
    const publication = readPublication(sourcePath, progress);

    const navigationTitles = new Map();
    for (const nav of publication.navigation) {
      const key = canonicalPath(nav.relativePath);
      if (!navigationTitles.has(key) && nav.title.trim()) {
        navigationTitles.set(key, nav.title.trim());
      }
    }

    const sections = [];
    const sectionLocations = new Map();
    let nextLocation = 0;
    const total = publication.sections.length;
    for (let index = 0; index < total; index++) {
      const section = publication.sections[index];
      const data = section.entry.getData();
      if (!data || data.length === 0) continue;
      const source = decodeEntryText(data);
      if (!source) continue;
      const canonical = canonicalPath(section.relativePath);
      const body = bodyHTML(source);
      const cleaned = sanitizeHTML(body, section.zipPath, publication.resolveEntryBuffer);
      if (!cleaned.trim()) continue;
      const pageCount = approximatePageCount(cleaned);
      sections.push({
        id: `rc-section-${sha256(canonical).slice(0, 12)}`,
        resourcePath: canonical,
        title: navigationTitles.get(canonical) || null,
        html: cleaned,
        startPageIndex: nextLocation,
        pageCount,
      });
      sectionLocations.set(canonical.toLowerCase(), nextLocation);
      nextLocation += pageCount;
      if (progress) {
        const fraction = 0.4 + 0.42 * (index + 1) / Math.max(total, 1);
        progress(fraction, `正在排版正文 · ${index + 1} / ${total}`);
      }
    }

    if (progress) progress(0.98, '电子书导入完成，正在建立全文索引…');

    let navigation = publication.navigation
      .map(item => ({
        ...item,
        location: sectionLocations.get(canonicalPath(item.relativePath).toLowerCase())
      }))
      .filter(item => Number.isInteger(item.location));
    if (navigation.length === 0) navigation = inferNavigationFromHeadings(sections);

    return {
      title: publication.title,
      sections,
      navigation,
      coverImageData: publication.coverImageData,
      sourceFingerprint: EPUBImporter.sourceFingerprint(sourcePath),
    };
  },

  sourceFingerprint(sourcePath) {
    try {
      const stat = fs.statSync(sourcePath);
      return `${stat.size}|${Math.floor(stat.mtimeMs)}`;
    } catch {
      return '-1|0';
    }
  },
};

module.exports = { EPUBImporter, sha256 };
