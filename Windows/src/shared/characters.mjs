/**
 * Character management data model — shared port of the character-related types
 * from macOS Models.swift (BookCharacter / CharacterTint) and ReaderModel.swift
 * (the CharacterManager API surface).
 *
 * The 8-color preset palette below replaces the macOS NSColor-based CharacterTint
 * enum. Characters store a `colorHex`; `cssColor` exposes a translucent rgba
 * suitable for highlight overlays (alpha 0.34 by default, 0.58 for the first
 * in-page occurrence of a given character, via cssColorFor).
 */

const TINT_HEXES = [
  '#e85c4a', '#e8913a', '#d4b942', '#5a9e5e',
  '#4ac2a8', '#4a9ed4', '#7d6ed4', '#d466a0',
];

/** Array of { hex, css } presets; css uses the standard 0.34 alpha. */
export const CharacterTint = TINT_HEXES.map(hex => ({ hex, css: hexToCss(hex, 0.34) }));

/**
 * Eight preset colors cycle through every character when unique colors are
 * assigned. The constant keeps the exported length explicit for callers.
 */
CharacterTint.count = TINT_HEXES.length;

/** RGBA string for a hex color with the requested alpha. */
export function tintCSS(hex, { first = false } = {}) {
  return hexToCss(hex, first ? 0.58 : 0.34);
}

function hexToCss(hex, alpha) {
  const rgb = hexToRgb(hex);
  if (!rgb) return `rgba(0,0,0,${alpha})`;
  return `rgba(${rgb.r},${rgb.g},${rgb.b},${alpha})`;
}

function hexToRgb(hex) {
  const value = String(hex || '').replace(/[^a-fA-F0-9]/g, '');
  if (value.length !== 6) return null;
  const num = parseInt(value, 16);
  return { r: (num >> 16) & 0xff, g: (num >> 8) & 0xff, b: num & 0xff };
}

function normalizeHex(hex) {
  const value = String(hex || '').replace(/[^a-fA-F0-9]/g, '');
  if (value.length !== 6) return null;
  return `#${value.toLowerCase()}`;
}

function generateId() {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }
  return `id-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

/**
 * HSB → RGB, mirroring NSColor(calibratedHue:saturation:brightness:) used by
 * the macOS `nextCharacterColorHex` generator once the 8 presets are exhausted.
 */
function hsbToRgb(h, s, b) {
  const i = Math.floor(h * 6);
  const f = h * 6 - i;
  const p = b * (1 - s);
  const q = b * (1 - f * s);
  const t = b * (1 - (1 - f) * s);
  let r = 0, g = 0, bl = 0;
  switch (i % 6) {
    case 0: r = b; g = t; bl = p; break;
    case 1: r = q; g = b; bl = p; break;
    case 2: r = p; g = b; bl = t; break;
    case 3: r = p; g = q; bl = b; break;
    case 4: r = t; g = p; bl = b; break;
    case 5: r = b; g = p; bl = q; break;
  }
  return { r: Math.round(r * 255), g: Math.round(g * 255), b: Math.round(bl * 255) };
}

function rgbToHex(r, g, b) {
  const clamp = v => Math.max(0, Math.min(255, v)).toString(16).padStart(2, '0');
  return `#${clamp(r)}${clamp(g)}${clamp(b)}`;
}

/**
 * BookCharacter — port of the Swift BookCharacter struct.
 *
 * `names` is the source of truth (primary name first). `name` and `aliases`
 * are read-only projections; `allNames` cleans, de-dupes (case-insensitive) and
 * sorts longest-first so multi-name matches prefer the most specific entry.
 */
export class BookCharacter {
  constructor({ id, name, names, aliases, identity, relationship, colorHex, tint } = {}) {
    this.id = id || generateId();
    const seed = Array.isArray(names) && names.length
      ? names.map(n => String(n || '').trim()).filter(Boolean)
      : [name, ...(Array.isArray(aliases) ? aliases : [])].map(n => String(n || '').trim()).filter(Boolean);
    this.names = seed.length ? seed : [''];
    this.identity = String(identity || '');
    this.relationship = String(relationship || '');
    this.colorHex = colorHex ? normalizeHex(colorHex) : null;
    this.tint = tint || CharacterTint[0].hex;
  }

  get name() { return this.names[0] || ''; }

  get aliases() { return this.names.slice(1); }

  /** Combined identity + relationship joined with a Chinese comma, empties dropped. */
  get information() {
    return [this.identity, this.relationship]
      .map(s => String(s || '').trim())
      .filter(Boolean)
      .join('，');
  }

  /** De-duplicated names, longest first, for matching. */
  get allNames() {
    const seen = new Set();
    const list = [];
    for (const candidate of [this.name, ...this.aliases]) {
      const value = String(candidate || '').trim();
      if (!value) continue;
      const key = value.toLowerCase();
      if (seen.has(key)) continue;
      seen.add(key);
      list.push(value);
    }
    return list.sort((a, b) => b.length - a.length);
  }

  /** Translucent rgba (0.34) for non-first overlays. */
  get cssColor() {
    return hexToCss(this.colorHex || this.tint || CharacterTint[0].hex, 0.34);
  }

  /** First in-page occurrence uses a stronger alpha (0.58). */
  cssColorFor(first = false) {
    return hexToCss(this.colorHex || this.tint || CharacterTint[0].hex, first ? 0.58 : 0.34);
  }
}

/**
 * CharacterManager — manages the character roster for one book.
 *
 * Ported from the CharacterManager portion of ReaderModel.swift. Persistence
 * (toJSON / fromJSON) mirrors the DocumentState characters slice so a project
 * file written on macOS round-trips on Windows.
 */
export class CharacterManager {
  constructor() {
    this.characters = [];
    this.highlightsEnabled = true;
  }

  /**
   * Add or update a character by primary name. Names beyond the first become
   * aliases; an existing character with a case-insensitive name match is updated.
   */
  addOrUpdate(name, { color, information, aliases, names } = {}) {
    const nameList = Array.isArray(names) && names.length
      ? names.map(n => String(n || '').trim()).filter(Boolean)
      : [String(name || '').trim(), ...(Array.isArray(aliases) ? aliases : []).map(a => String(a || '').trim())]
          .filter(Boolean);

    const primary = nameList[0];
    if (!primary) return null;

    const aliasList = nameList.slice(1).filter(a => a.toLowerCase() !== primary.toLowerCase());
    const lower = primary.toLowerCase();
    const existing = this.characters.find(c => (c.name || '').toLowerCase() === lower);

    if (existing) {
      existing.names = [primary, ...aliasList];
      existing.identity = String(information || '');
      existing.relationship = '';
      existing.colorHex = existing.colorHex || (color ? normalizeHex(color) : null) || this.nextColorHex();
      return existing;
    }

    const character = new BookCharacter({
      name: primary,
      names: [primary, ...aliasList],
      identity: information,
      colorHex: color || this.nextColorHex(),
    });
    this.characters.push(character);
    return character;
  }

  /**
   * Parse and add characters from batch text. Each line follows the format
   * `人物：身份，关系等信息`. The legacy `名字 别名 #信息` form and the
   * editable `主名|别名1、别名2|信息` form are also accepted.
   * Returns the number of lines recognized.
   */
  addFromBatch(batchText) {
    let recognized = 0;
    for (const rawLine of String(batchText || '').split(/\r?\n/)) {
      if (!rawLine.trim()) continue;
      const parsed = this.parseBatchLine(rawLine);
      if (!parsed || !parsed.names.length) continue;
      this.addOrUpdate(parsed.names[0], { names: parsed.names, information: parsed.information });
      recognized += 1;
    }
    return recognized;
  }

  /**
   * Parse a single batch line. Returns { names, information } or null.
   * Format: "名字1 名字2 #信息" — everything after `#` is information.
   */
  parseBatchLine(line) {
    const text = String(line || '').trim();
    if (!text) return null;

    if (text.includes('|')) {
      const fields = text.split('|').map(value => value.trim());
      if (!fields[0]) return null;
      const aliases = String(fields[1] || '').split(/[、,，/；;]+/).map(value => value.trim()).filter(Boolean);
      return { names: [fields[0], ...aliases], information: fields.slice(2).filter(Boolean).join('，') };
    }

    const colon = text.search(/[：:]/);
    if (colon >= 0) {
      const parts = text.slice(0, colon).split(/[/／]/).map(value => value.trim());
      if (!parts[0]) return null;
      const seen = new Set();
      const names = parts.filter(value => value && !seen.has(value.toLowerCase()) && seen.add(value.toLowerCase()));
      return { names, information: text.slice(colon + 1).trim() };
    }

    let information = '';
    let namesPart = text;
    const hashIndex = text.indexOf('#');
    if (hashIndex >= 0) {
      information = text.slice(hashIndex + 1).trim();
      namesPart = text.slice(0, hashIndex).trim();
    }

    const names = namesPart.split(/\s+/).map(n => n.trim()).filter(Boolean);
    if (!names.length) return null;
    return { names, information };
  }

  /** Replace the entire roster. Existing colors are kept; missing ones filled. */
  replace(characters) {
    const source = Array.isArray(characters) ? characters : [];
    const cleaned = [];
    const seenNames = new Set();

    for (const entry of source) {
      const name = String(entry.name || '').trim();
      if (!name) continue;
      const key = name.toLowerCase();
      if (seenNames.has(key)) continue;
      seenNames.add(key);

      const names = Array.isArray(entry.names) && entry.names.length
        ? entry.names.map(n => String(n || '').trim()).filter(Boolean)
        : [name, ...(entry.aliases || []).map(a => String(a || '').trim()).filter(Boolean)
            .filter(a => a.toLowerCase() !== key)];
      const character = entry instanceof BookCharacter
        ? entry
        : new BookCharacter({
            id: entry.id,
            name,
            names,
            identity: entry.identity,
            relationship: entry.relationship,
            colorHex: entry.colorHex,
            tint: entry.tint,
          });
      character.names = names.length ? names : [name];
      character.identity = String(entry.identity || '');
      character.relationship = String(entry.relationship || '');
      if (!character.colorHex) character.colorHex = this.nextColorHex();
      cleaned.push(character);
    }

    this.characters = cleaned;
    return this;
  }

  /** Delete characters by id (single id or array of ids). */
  delete(ids) {
    const set = new Set(Array.isArray(ids) ? ids : [ids]);
    this.characters = this.characters.filter(c => !set.has(c.id));
    return this;
  }

  /** Reorder: move `id` to appear before `beforeId`; null `beforeId` appends. */
  move(id, beforeId) {
    const from = this.characters.findIndex(c => c.id === id);
    if (from < 0) return this;
    const [item] = this.characters.splice(from, 1);
    if (beforeId == null) {
      this.characters.push(item);
      return this;
    }
    const target = this.characters.findIndex(c => c.id === beforeId);
    if (target < 0) {
      this.characters.push(item);
      return this;
    }
    this.characters.splice(target, 0, item);
    return this;
  }

  setHighlightsEnabled(enabled) {
    this.highlightsEnabled = !!enabled;
    return this;
  }

  /**
   * Find all occurrences of a character's names within `text`. Results are
   * sorted by start offset; at the same start the longer name wins and shorter
   * overlaps are dropped. Each hit: { start, end, name }.
   */
  occurrences(text, characterId) {
    const character = this.characters.find(c => c.id === characterId);
    if (!character) return [];
    const source = String(text || '');
    const records = [];

    for (const name of character.allNames) {
      if (!name) continue;
      let from = 0;
      while (from <= source.length) {
        const at = source.indexOf(name, from);
        if (at < 0) break;
        records.push({ start: at, end: at + name.length, name });
        from = at + name.length;
      }
    }

    const seen = new Set();
    return records
      .sort((a, b) => a.start - b.start || b.name.length - a.name.length)
      .filter(hit => {
        const key = `${hit.start}`;
        if (seen.has(key)) return false;
        seen.add(key);
        return true;
      });
  }

  /**
   * Extract a window of text around the occurrence at `index`. `windowSize`
   * is the number of context characters included on each side of the match.
   */
  occurrenceWindow(text, characterId, index, windowSize = 80) {
    const hits = this.occurrences(text, characterId);
    if (index < 0 || index >= hits.length) return '';
    const source = String(text || '');
    const hit = hits[index];
    const half = Math.max(0, Math.floor(windowSize / 2));
    const start = Math.max(0, hit.start - half);
    const end = Math.min(source.length, hit.end + half);
    return source.slice(start, end);
  }

  /** Assign a unique color to every character, preserving explicit ones. */
  assignUniqueColors() {
    const used = new Set();
    for (const character of this.characters) {
      const existing = (character.colorHex || '').toUpperCase().replace(/[^A-F0-9]/g, '');
      if (existing && !used.has(existing)) {
        character.colorHex = `#${existing}`;
        used.add(existing);
      } else {
        const hex = this.nextColorHex(used);
        character.colorHex = hex;
        used.add(hex.toUpperCase());
      }
    }
    return this;
  }

  /** Next color not yet in use: presets first, then golden-angle HSB hues. */
  nextColorHex(usedSet) {
    const used = usedSet instanceof Set
      ? usedSet
      : new Set(this.characters.map(c => (c.colorHex || '').toUpperCase().replace(/[^A-F0-9]/g, '')));

    for (const preset of CharacterTint) {
      const hex = preset.hex.toUpperCase();
      if (!used.has(hex)) return preset.hex;
    }

    for (let ordinal = 0; ordinal < 10000; ordinal++) {
      const hue = (0.035 + ordinal * 0.61803398875) % 1;
      const saturation = 0.48 + (ordinal % 3) * 0.055;
      const brightness = 0.82 + (Math.floor(ordinal / 3) % 2) * 0.08;
      const rgb = hsbToRgb(hue, saturation, brightness);
      const hex = rgbToHex(rgb.r, rgb.g, rgb.b).toUpperCase();
      if (!used.has(hex)) return hex;
    }

    return `#${Math.random().toString(16).slice(2, 8)}`;
  }

  /** Serialize to the DocumentState characters slice. */
  toJSON() {
    return {
      characters: this.characters.map(c => ({
        id: c.id,
        name: c.name,
        names: c.names,
        aliases: c.aliases,
        identity: c.identity,
        relationship: c.relationship,
        colorHex: c.colorHex,
        tint: c.tint,
      })),
      characterHighlightsEnabled: this.highlightsEnabled,
    };
  }

  /** Restore from a DocumentState characters slice. */
  fromJSON(data) {
    const payload = data || {};
    this.characters = (payload.characters || []).map(entry => new BookCharacter({
      id: entry.id,
      name: entry.name,
      names: entry.names,
      aliases: entry.aliases,
      identity: entry.identity,
      relationship: entry.relationship,
      colorHex: entry.colorHex,
      tint: entry.tint,
    }));
    this.highlightsEnabled = payload.characterHighlightsEnabled ?? true;
    return this;
  }
}

export default { BookCharacter, CharacterTint, CharacterManager };
