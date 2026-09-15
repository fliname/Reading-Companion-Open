import { normalizeText } from './retrieval.mjs';

export function normalizeSelectionPart(value = '') {
  return normalizeText(value).replace(/\s*\n\s*/g, ' ').replace(/\s+/g, ' ').trim();
}

export function formatSelectionParts(parts = []) {
  const normalized = parts.map(normalizeSelectionPart).filter(Boolean);
  return normalized.join('');
}

export function normalizeGroupedSelectionText(value = '') {
  const source = String(value || '');
  const lines = source.split(/\r?\n/).map(line => line.trim()).filter(Boolean);
  if (lines.length > 1 && lines.every(line => line.startsWith('•'))) {
    return formatSelectionParts(lines.map(line => line.replace(/^•\s*/, '')));
  }
  return lines.length > 1 ? formatSelectionParts(lines) : normalizeSelectionPart(source);
}
