/**
 * Normal PDF text selections must stay authoritative. Only broken character
 * maps (replacement glyphs, empty squares or private-use glyphs) justify the
 * slower OCR fallback.
 */
export function needsOCRCorrection(value = '') {
  return /�|□|\p{Co}/u.test(String(value));
}
