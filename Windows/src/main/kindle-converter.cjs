'use strict';

// MOBI/AZW3 bridge for the Windows edition.
// On macOS the Swift KindleBookConverter shells out to a bundled `mobitool`
// binary that produces an EPUB, which then flows through EPUBImporter. Windows
// bundles the same LGPL libmobi `mobitool` executable on Windows. It converts
// every supported, DRM-free Kindle container to EPUB, which then enters the
// shared EPUB pipeline. The small JavaScript decoder remains as a development
// fallback for classic uncompressed/PalmDOC MOBI files.

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const os = require('node:os');
const { execFile } = require('node:child_process');

const MAX_MOBI_BYTES = 1024 * 1024 * 1024; // 1 GB, matching the macOS validator

// Error messages mirror KindleBookConversionError in KindleBookConverter.swift.
const ERR_INVALID = '这份文件不是有效的 AZW3 或 MOBI 电子书。';
const ERR_ENCRYPTED = '这份 Kindle 电子书带有 DRM 加密，无法导入。请使用无 DRM 的 AZW3/MOBI 文件。';
const ERR_MISSING = 'AZW3/MOBI 已完成解析，但没有生成可阅读的书籍内容。';
function errUnsupported(detail) {
  return `AZW3/MOBI 解码失败：${detail}`;
}

function runConverter(executable, args) {
  return new Promise((resolve, reject) => {
    execFile(executable, args, { windowsHide: true, maxBuffer: 8 * 1024 * 1024 }, (error, stdout, stderr) => {
      if (!error) return resolve(`${stdout || ''}\n${stderr || ''}`.trim());
      const detail = `${stdout || ''}\n${stderr || ''}`.trim();
      if (/encrypt|drm/i.test(detail)) return reject(new Error(ERR_ENCRYPTED));
      reject(new Error(errUnsupported(detail.split(/\r?\n/).slice(-4).join(' ') || error.message)));
    });
  });
}

async function convertToEPUB(sourcePath, executable) {
  const validation = validateFile(sourcePath);
  if (!validation.valid) throw new Error(ERR_INVALID);
  if (!executable || !fs.existsSync(executable)) {
    throw new Error('安装包缺少 AZW3/MOBI 解码组件，请重新安装完整版本。');
  }
  const workingDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'ReadingCompanion-Kindle-'));
  try {
    await runConverter(executable, ['-e', '-o', workingDirectory, sourcePath]);
    const epubName = fs.readdirSync(workingDirectory).find(name => path.extname(name).toLowerCase() === '.epub');
    if (!epubName) throw new Error(ERR_MISSING);
    return { epubPath: path.join(workingDirectory, epubName), workingDirectory };
  } catch (error) {
    fs.rmSync(workingDirectory, { recursive: true, force: true });
    throw error;
  }
}

function sha256(value) {
  return crypto.createHash('sha256').update(String(value), 'utf8').digest('hex');
}

// --- PalmDOC LZ77 decompression ---------------------------------------------
// Reference: Calibre format_docs/compression/palmdoc.txt and libmobi.
// 0x00        -> literal 0x00
// 0x01..0x08  -> copy the next N bytes literally
// 0x09..0x7f  -> single literal byte
// 0x80..0xbf  -> 2-byte pair; 14-bit value = 11 distance bits (high) + 3 length
//                bits (low); copy (length+3) bytes from (distance+1) back
// 0xc0..0xff  -> byte pair: space (0x20) + (byte ^ 0x80)
function decompressPalmDoc(data, maxLen) {
  const out = [];
  let i = 0;
  const n = data.length;
  const limit = maxLen > 0 ? maxLen : n;
  while (i < n && out.length < limit) {
    const c = data[i++];
    if (c === 0x00) {
      out.push(0);
    } else if (c <= 0x08) {
      for (let k = 0; k < c && i < n && out.length < limit; k++) out.push(data[i++]);
    } else if (c < 0x80) {
      out.push(c);
    } else if (c < 0xc0) {
      if (i >= n) break;
      const c2 = data[i++];
      const pair = ((c & 0x3f) << 8) | c2;
      const length = (pair & 0x07) + 3;
      const distance = (pair >> 3) + 1;
      const start = out.length - distance;
      if (start < 0) break;
      for (let k = 0; k < length && out.length < limit; k++) out.push(out[start + k]);
    } else {
      out.push(0x20);
      if (out.length < limit) out.push(c ^ 0x80);
    }
  }
  return Buffer.from(out).subarray(0, Math.min(out.length, limit));
}

// --- Text decoding ----------------------------------------------------------

function codepageToLabel(codepage) {
  switch (codepage) {
    case 1252: return 'windows-1252';
    case 1250: return 'windows-1250';
    case 1251: return 'windows-1251';
    case 1253: return 'windows-1253';
    case 1254: return 'windows-1254';
    case 1255: return 'windows-1255';
    case 1256: return 'windows-1256';
    case 1257: return 'windows-1257';
    case 1258: return 'windows-1258';
    case 932: return 'shift_jis';
    case 936: return 'gbk';
    case 949: return 'euc-kr';
    case 950: return 'big5';
    case 65001: return 'utf-8';
    default: return null;
  }
}

function decodeBuffer(buffer, codepage) {
  const label = codepageToLabel(codepage);
  if (label) {
    try { return new TextDecoder(label, { fatal: false }).decode(buffer); }
    catch { /* fall through */ }
  }
  try { return new TextDecoder('utf-8', { fatal: false }).decode(buffer); }
  catch { return buffer.toString('latin1'); }
}

// --- Image helpers ----------------------------------------------------------

function imageMIME(buf) {
  if (!buf || buf.length < 4) return null;
  if (buf[0] === 0xff && buf[1] === 0xd8) return 'image/jpeg';
  if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) return 'image/png';
  if (buf[0] === 0x47 && buf[1] === 0x49 && buf[2] === 0x46) return 'image/gif';
  if (buf[0] === 0x42 && buf[1] === 0x4d) return 'image/bmp';
  return null;
}

// --- PalmDB container parsing -----------------------------------------------

function parsePDB(buffer) {
  if (buffer.length < 78) throw new Error(ERR_INVALID);
  const name = buffer.subarray(0, 32).toString('latin1').replace(/\0[\s\S]*$/, '').trim();
  const type = buffer.toString('latin1', 60, 64);
  const creator = buffer.toString('latin1', 64, 68);
  const numRecords = buffer.readUInt16BE(76);

  const recordInfos = [];
  let pos = 78;
  for (let i = 0; i < numRecords; i++) {
    if (pos + 8 > buffer.length) break;
    const offset = buffer.readUInt32BE(pos);
    recordInfos.push({ index: i, offset, attributes: buffer[pos + 4] });
    pos += 8;
  }

  const records = [];
  for (let i = 0; i < recordInfos.length; i++) {
    const start = recordInfos[i].offset;
    const end = i + 1 < recordInfos.length ? recordInfos[i + 1].offset : buffer.length;
    const data = start < buffer.length ? buffer.subarray(start, end) : Buffer.alloc(0);
    records.push({ index: recordInfos[i].index, offset: start, attributes: recordInfos[i].attributes, data });
  }
  return { name, type, creator, numRecords, records };
}

// PalmDOC header (record 0, bytes 0..15) + MOBI header (record 0, bytes 16..).
function parseRecord0(rec0) {
  const d = rec0.data;
  if (d.length < 16) throw new Error(ERR_INVALID);
  const compression = d.readUInt16BE(0);
  const textLength = d.readUInt32BE(4);
  const textRecordCount = d.readUInt16BE(8);
  const recordSize = d.readUInt16BE(10);
  const encryption = d.readUInt16BE(12);

  const mobi = { present: false };
  if (d.length >= 24 && d.toString('latin1', 16, 20) === 'MOBI') {
    mobi.present = true;
    mobi.headerLength = d.readUInt32BE(20);
    mobi.type = d.length >= 28 ? d.readUInt32BE(24) : 0;
    mobi.codepage = d.length >= 32 ? d.readUInt32BE(28) : 0;
    mobi.fileVersion = d.length >= 40 ? d.readUInt32BE(36) : 0;
    mobi.firstNonBook = d.length >= 44 ? d.readUInt32BE(40) : 0;
    mobi.fullNameOffset = d.length >= 48 ? d.readUInt32BE(44) : 0;
    mobi.fullNameLength = d.length >= 52 ? d.readUInt32BE(48) : 0;
    mobi.language = d.length >= 56 ? d.readUInt32BE(52) : 0;
    mobi.firstImageIndex = d.length >= 72 ? d.readUInt32BE(68) : 0;
  }
  return { compression, textLength, textRecordCount, recordSize, encryption, mobi };
}

// EXTH header sits right after the MOBI header in record 0.
function parseEXTH(rec0, mobiHeaderLength) {
  if (!mobiHeaderLength) return null;
  const d = rec0.data;
  const exthStart = 16 + mobiHeaderLength;
  if (exthStart + 12 > d.length) return null;
  if (d.toString('latin1', exthStart, exthStart + 4) !== 'EXTH') return null;

  const recCount = d.readUInt32BE(exthStart + 8);
  const records = {};
  let pos = exthStart + 12;
  for (let i = 0; i < recCount && pos + 8 <= d.length; i++) {
    const type = d.readUInt32BE(pos);
    const len = d.readUInt32BE(pos + 4);
    if (len < 8 || pos + len > d.length) break;
    if (records[type] === undefined) records[type] = d.subarray(pos + 8, pos + len);
    pos += len;
  }
  return records;
}

function readTextRecords(pdb, header) {
  const parts = [];
  const recordSize = header.recordSize || 4096;
  for (let i = 0; i < header.textRecordCount; i++) {
    const idx = 1 + i;
    if (idx >= pdb.records.length) break;
    const rec = pdb.records[idx];
    if (!rec || !rec.data || rec.data.length === 0) continue;
    let block;
    if (header.compression === 1) {
      block = rec.data;
    } else if (header.compression === 2) {
      block = decompressPalmDoc(rec.data, recordSize);
    } else {
      throw new Error(errUnsupported('不支持的压缩类型 ' + header.compression + '。'));
    }
    parts.push(block);
  }
  let textBuf = parts.length ? Buffer.concat(parts) : Buffer.alloc(0);
  if (header.textLength && textBuf.length > header.textLength) {
    textBuf = textBuf.subarray(0, header.textLength);
  }
  return textBuf;
}

function makeImageResolver(pdb, firstImageIndex) {
  return (recindex) => {
    const idx = firstImageIndex + (recindex - 1);
    if (idx < 0 || idx >= pdb.records.length) return null;
    const rec = pdb.records[idx];
    return rec && rec.data ? rec.data : null;
  };
}

function extractCover(pdb, header, exth) {
  const firstImage = (header.mobi.present ? header.mobi.firstImageIndex : 0) || 0;
  let coverOffset = null;
  if (exth) {
    if (exth[201]) coverOffset = exth[201].readUInt32BE(0);
    else if (exth[203]) coverOffset = exth[203].readUInt32BE(0);
  }
  if (coverOffset !== null && Number.isFinite(coverOffset)) {
    const idx = firstImage + coverOffset;
    if (idx >= 0 && idx < pdb.records.length) {
      const data = pdb.records[idx].data;
      if (imageMIME(data)) return data;
    }
  }
  for (let i = firstImage; i < pdb.records.length; i++) {
    const data = pdb.records[i] && pdb.records[i].data;
    if (data && imageMIME(data)) return data;
  }
  return null;
}

function extractTitle(pdb, header, exth, sourcePath) {
  const codepage = header.mobi.present ? header.mobi.codepage : 65001;
  let title = '';
  if (exth && exth[101]) title = decodeBuffer(exth[101], codepage).trim();
  if (!title && header.mobi.present) {
    const fno = header.mobi.fullNameOffset;
    const fnl = header.mobi.fullNameLength;
    const rec0 = pdb.records[0] && pdb.records[0].data;
    if (fno && fnl && rec0 && fno + fnl <= rec0.length) {
      title = decodeBuffer(rec0.subarray(fno, fno + fnl), codepage).trim();
    }
  }
  if (!title) title = pdb.name;
  return title || path.basename(sourcePath, path.extname(sourcePath));
}

// --- HTML conversion --------------------------------------------------------

function escapeHTML(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function sanitizeMOBIHTML(html, imageResolver) {
  let out = html;
  const body = /<body\b[^>]*>([\s\S]*?)<\/body\s*>/i.exec(out);
  if (body) out = body[1];
  out = out.replace(/<(script|style|iframe|object|embed)\b[^>]*>[\s\S]*?<\/\1\s*>/gi, '');
  out = out.replace(/<(script|style|iframe|object|embed)\b[^>]*\/\s*>/gi, '');
  out = out.replace(/\s(?:style|on[a-z]+)\s*=\s*(?:"[^"]*"|'[^']*')/gi, '');

  out = out.replace(/<img\b[^>]*>/gi, (tag) => {
    const ri = /\brecindex\s*=\s*["'](\d+)["']/i.exec(tag);
    const src = /\bsrc\s*=\s*["']([^"']+)["']/i.exec(tag);
    if (ri) {
      const data = imageResolver ? imageResolver(parseInt(ri[1], 10)) : null;
      const mime = imageMIME(data);
      if (mime) return `<img alt="" src="data:${mime};base64,${data.toString('base64')}" />`;
      return '';
    }
    if (src) {
      const v = src[1];
      if (/^data:/i.test(v)) return tag;
      if (/^(?:javascript:|https?:\/\/|file:)/i.test(v)) return '';
      return tag;
    }
    return '';
  });

  out = out.replace(/\shref\s*=\s*(["'])\s*(?:javascript:|https?:\/\/|file:)[^"']*\1/gi, '');
  return out;
}

function textToHTML(text, imageResolver) {
  if (/<\s*(html|body|p|div|br|h[1-6]|img|table|span|b|ul|ol|li)\b/i.test(text)) {
    return sanitizeMOBIHTML(text, imageResolver);
  }
  const blocks = text.split(/\n\s*\n+/);
  const paras = blocks
    .map((b) => {
      const content = escapeHTML(b.replace(/^\s+|\s+$/g, '')).replace(/\n/g, '<br/>');
      return content ? `<p>${content}</p>` : '';
    })
    .filter(Boolean);
  return paras.length ? paras.join('\n') : `<p>${escapeHTML(text.trim())}</p>`;
}

// --- KindleConverter public API ---------------------------------------------

function validateFile(sourcePath) {
  let stat;
  try { stat = fs.statSync(sourcePath); }
  catch { return { valid: false, type: 'unknown', fileSize: 0 }; }
  const fileSize = stat.size;
  if (!stat.isFile() || fileSize <= 78 || fileSize > MAX_MOBI_BYTES) {
    return { valid: false, type: 'unknown', fileSize };
  }
  let fd;
  try { fd = fs.openSync(sourcePath, 'r'); }
  catch { return { valid: false, type: 'unknown', fileSize }; }
  try {
    const sig = Buffer.alloc(8);
    fs.readSync(fd, sig, 0, 8, 60);
    const s = sig.toString('latin1');
    if (s === 'BOOKMOBI') return { valid: true, type: 'MOBI', fileSize };
    if (s === 'TEXtREAd') return { valid: true, type: 'PALMDOC', fileSize };
    return { valid: false, type: 'unknown', fileSize };
  } catch {
    return { valid: false, type: 'unknown', fileSize };
  } finally {
    try { fs.closeSync(fd); } catch { /* ignore */ }
  }
}

function convertClassic(sourcePath, options = {}) {
  const progress = options && typeof options.progress === 'function' ? options.progress : null;
  const validation = validateFile(sourcePath);
  if (!validation.valid) throw new Error(ERR_INVALID);
  if (progress) progress(0.12, '正在离线解码 AZW3/MOBI…');

  let buffer;
  try { buffer = fs.readFileSync(sourcePath); }
  catch { throw new Error(ERR_INVALID); }
  if (buffer.length > MAX_MOBI_BYTES) throw new Error(ERR_INVALID);

  const pdb = parsePDB(buffer);
  if (!pdb.records.length) throw new Error(ERR_INVALID);
  const header = parseRecord0(pdb.records[0]);

  if (header.encryption !== 0) throw new Error(ERR_ENCRYPTED);
  if (header.compression !== 1 && header.compression !== 2) {
    throw new Error(errUnsupported(
      '该文件使用 HUFF/CDIC 高压缩或为 KF8/AZW3 格式，暂不支持。请使用未压缩或 PalmDOC 压缩的无 DRM MOBI 文件。'
    ));
  }

  const exth = header.mobi.present ? parseEXTH(pdb.records[0], header.mobi.headerLength) : null;

  // KF8-only AZW3 containers carry an EXTH 121 "KF8 boundary" record and no
  // readable MOBI6 text. Combined MOBI7+KF8 files keep the MOBI6 HTML stream,
  // which we can still extract below.
  const hasKF8 = !!(exth && exth[121]);
  if (hasKF8 && (header.textRecordCount === 0 || header.textLength === 0)) {
    throw new Error(errUnsupported(
      '该文件为 KF8/AZW3 格式，当前仅支持未加密的 MOBI6（PalmDOC）文本，请使用未加密的 MOBI 文件。'
    ));
  }

  if (progress) progress(0.30, '解码完成，正在读取目录与正文…');

  const codepage = header.mobi.present ? header.mobi.codepage : 65001;
  const textBuf = readTextRecords(pdb, header);
  if (!textBuf.length) throw new Error(ERR_MISSING);
  const text = decodeBuffer(textBuf, codepage);
  if (!text || !text.trim()) throw new Error(ERR_MISSING);

  const firstImage = (header.mobi.present ? header.mobi.firstImageIndex : 0) || 0;
  const imageResolver = makeImageResolver(pdb, firstImage);
  const html = textToHTML(text, imageResolver);
  if (!html || !html.trim()) throw new Error(ERR_MISSING);

  const title = extractTitle(pdb, header, exth, sourcePath);
  const coverImageData = extractCover(pdb, header, exth);

  const resourcePath = 'kindle-section-1.html';
  const sections = [{
    id: 'rc-section-' + sha256(resourcePath).slice(0, 12),
    resourcePath,
    title: null,
    html,
    startPageIndex: 0,
  }];
  const navigation = [{ title, relativePath: resourcePath, level: 0 }];

  if (progress) progress(0.98, '电子书导入完成，正在建立全文索引…');
  return { title, sections, navigation, coverImageData };
}

function sourceFingerprint(sourcePath) {
  try {
    const stat = fs.statSync(sourcePath);
    return `${stat.size}|${Math.floor(stat.mtimeMs)}`;
  } catch {
    return '-1|0';
  }
}

const KindleConverter = { convert: convertClassic, convertClassic, convertToEPUB, validateFile, sourceFingerprint };

module.exports = { KindleConverter, sha256 };
