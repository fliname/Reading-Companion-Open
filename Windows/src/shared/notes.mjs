function escapeMarkdown(value = '') {
  return String(value)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/\\/g, '\\\\').replace(/[`*_\[\]]/g, match => `\\${match}`);
}

function yamlQuoted(value = '') {
  return `"${String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\r?\n/g, '\\n')}"`;
}

function blueAnnotation(value = '') {
  return `<span style="color: #3b82f6;">${escapeMarkdown(value).replace(/\n/g, '\n> ')}</span>`;
}

export function safeFileName(value = '') { return value.replace(/[\\/:*?"<>|]/g, '-').trim() || 'Reading Companion'; }

export function skeleton(title, outline = [], sourcePath = null) {
  const lines = ['---', `title: ${yamlQuoted(title)}`, 'type: reading-note'];
  if (sourcePath) {
    lines.push(`source: ${yamlQuoted(sourcePath)}`);
    const extension = String(sourcePath).split(/[\\/]/).at(-1)?.match(/\.([^.]+)$/)?.[1]?.toLowerCase();
    if (extension) lines.push(`format: ${yamlQuoted(extension)}`);
  }
  lines.push('tags:', '  - reading-companion', '---', '', `# ${title}`, '');
  for (const entry of outline) {
    if (entry.title.trim().toLowerCase() === title.trim().toLowerCase()) continue;
    lines.push(`${'#'.repeat(Math.min(6, Math.max(2, Number(entry.level || 0) + 2)))} ${entry.title}`, '');
  }
  lines.push('## 我的笔记', '', '');
  return lines.join('\n');
}

export function ensureOutline(markdown, outline = []) {
  const lines = new Set(markdown.split(/\r?\n/));
  const missing = outline.map(entry => `${'#'.repeat(Math.min(6, Math.max(2, Number(entry.level || 0) + 2)))} ${entry.title}`).filter(line => !lines.has(line));
  if (!missing.length) return markdown;
  const position = markdown.search(/\n## 我的笔记\s*$/m);
  return position >= 0 ? `${markdown.slice(0, position)}\n\n${missing.join('\n\n')}\n${markdown.slice(position)}` : `${markdown}\n\n${missing.join('\n\n')}\n`;
}

export function highlightBlock(mark) {
  const text = escapeMarkdown(mark.text || '').replace(/\n/g, '\n> ');
  if (mark.kind === 'annotation') {
    const note = mark.note ? `\n>\n> ${blueAnnotation(mark.note)}` : '';
    return `> [!success] 批注 · P${mark.pageIndex + 1}\n> *原文：* ${text}${note}`;
  }
  const callout = { yellow: 'warning', red: 'danger', blue: 'info' }[mark.color] || 'warning';
  const note = mark.note ? `\n\n> [!note] 批注\n> ${blueAnnotation(mark.note)}` : '';
  return `> [!${callout}] 划线 · P${mark.pageIndex + 1}\n> ${text}${note}`;
}

export function aiBlock(turns, { collapsed = false, condensed = null } = {}) {
  const pages = [...new Set(turns.flatMap(turn => turn.pageReferences || []))].sort((a, b) => a - b);
  const title = condensed ? 'AI 讨论 · 整理' : 'AI 讨论';
  const body = condensed || turns.map(turn => `**${turn.role === 'user' ? '问题' : '伴读'}：** ${turn.content}`).join('\n\n');
  return `> [!example]${collapsed ? '-' : '+'} ${title}${pages.length ? ` · ${pages.map(page => `P${page + 1}`).join('、')}` : ''}\n> ${body.replace(/\n/g, '\n> ')}`;
}

export function chapterForPage(pageIndex, outline = [], sourceText = '') {
  const eligible = outline.filter(entry => entry.pageIndex <= pageIndex);
  if (!eligible.length) return null;
  const samePage = eligible.filter(entry => entry.pageIndex === pageIndex);
  if (samePage.length > 1 && sourceText) {
    const compact = sourceText.replace(/\s/g, '').toLowerCase();
    const match = [...samePage].reverse().find(entry => compact.includes(entry.title.replace(/\s/g, '').toLowerCase()));
    if (match) return match.title;
  }
  const last = eligible.at(-1);
  if (samePage.length && last.level > 0 && !sourceText) {
    const parent = [...eligible].reverse().find(entry => entry.level < last.level);
    return parent?.title || last.title;
  }
  return last.title;
}

export function insertUnderChapter(markdown, block, chapterTitle) {
  const payload = block.trim();
  if (!payload || markdown.includes(payload)) return markdown;
  if (!chapterTitle) return appendMyNotes(markdown, payload);
  const escaped = chapterTitle.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const heading = new RegExp(`^#{2,6}\\s+${escaped}\\s*$`, 'mi').exec(markdown);
  if (!heading) return appendMyNotes(markdown, payload);
  const start = heading.index + heading[0].length;
  const next = /^#{2,6}\s+/m.exec(markdown.slice(start));
  const insertion = next ? start + next.index : markdown.length;
  return `${markdown.slice(0, insertion).replace(/\s*$/, '')}\n\n${payload}\n\n${markdown.slice(insertion).replace(/^\s*/, '')}`;
}

function appendMyNotes(markdown, payload) {
  const heading = /^## 我的笔记\s*$/m.exec(markdown);
  if (!heading) return `${markdown.trim()}\n\n## 我的笔记\n\n${payload}\n`;
  const insertion = heading.index + heading[0].length;
  return `${markdown.slice(0, insertion)}\n\n${payload}${markdown.slice(insertion)}`;
}
