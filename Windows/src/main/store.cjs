const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

class ReadingStore {
  constructor(appDataPath, safeStorage) {
    this.root = path.join(appDataPath, 'ReadingCompanion', 'Documents');
    this.safeStorage = safeStorage;
    fs.mkdirSync(this.root, { recursive: true });
  }

  identifier(sourcePath) {
    return crypto.createHash('sha256').update(path.resolve(sourcePath), 'utf8').digest('hex');
  }

  projectPath(sourcePath) {
    return path.join(this.root, `${this.identifier(sourcePath)}.json`);
  }

  derivedPath(sourcePath) {
    return path.join(this.root, `${this.identifier(sourcePath)}.derived.json`);
  }

  reflowCachePath(sourcePath) {
    return path.join(this.root, `${this.identifier(sourcePath)}.reflow.json`);
  }

  coverAssetPath(sourcePath) {
    return path.join(this.root, `${this.identifier(sourcePath)}.cover.png`);
  }

  bookshelfFoldersPath() {
    return path.join(this.root, 'bookshelf-folders.json');
  }

  projectsPath() {
    return path.join(this.root, 'projects.json');
  }

  bookshelfMetaPath() {
    return path.join(this.root, 'bookshelf-meta.json');
  }

  readJSON(target, fallback) {
    try { return JSON.parse(fs.readFileSync(target, 'utf8')); }
    catch { return fallback; }
  }

  writeJSON(target, value) {
    const temporary = `${target}.${process.pid}.tmp`;
    fs.writeFileSync(temporary, JSON.stringify(value), 'utf8');
    fs.renameSync(temporary, target);
  }

  migrateBookshelfPolicy() {
    const currentVersion = 1;
    const meta = this.readJSON(this.bookshelfMetaPath(), {});
    if ((Number(meta.categoryPolicyVersion) || 0) >= currentVersion) return;
    const projects = this.readJSON(this.projectsPath(), []);
    for (const project of projects) {
      project.category = null;
      const state = this.readJSON(this.projectPath(project.sourcePath), null);
      if (state) {
        state.bookCategory = null;
        this.writeJSON(this.projectPath(project.sourcePath), state);
      }
    }
    this.writeJSON(this.projectsPath(), projects);
    this.writeJSON(this.bookshelfMetaPath(), { categoryPolicyVersion: currentVersion });
  }

  listProjects() {
    this.migrateBookshelfPolicy();
    return this.readJSON(this.projectsPath(), [])
      .map(project => ({
        ...project,
        available: fs.existsSync(project.sourcePath),
        category: project.category === 'fiction' || project.category === 'nonfiction' ? project.category : null,
        folderID: project.folderID ?? null,
        folderIDs: [...new Set([
          ...(Array.isArray(project.folderIDs) ? project.folderIDs : []),
          ...(project.folderID ? [project.folderID] : [])
        ])],
        coverPath: project.coverPath ?? null,
        coverVersion: project.coverVersion ?? 0
      }))
      .sort((left, right) => new Date(right.lastOpenedAt) - new Date(left.lastOpenedAt));
  }

  registerProject(sourcePath, title, options = {}) {
    const normalized = path.resolve(sourcePath);
    const existing = this.listProjects().find(project => path.resolve(project.sourcePath) === normalized);
    const projects = this.listProjects().filter(project => path.resolve(project.sourcePath) !== normalized);
    const record = {
      sourcePath: normalized,
      title,
      lastOpenedAt: new Date().toISOString(),
      category: options.category ?? existing?.category ?? null,
      folderID: null,
      folderIDs: options.folderIDs ?? existing?.folderIDs ?? (existing?.folderID ? [existing.folderID] : []),
      coverPath: options.coverPath ?? existing?.coverPath ?? null,
      coverVersion: existing?.coverVersion ?? 0
    };
    projects.unshift(record);
    this.writeJSON(this.projectsPath(), projects.slice(0, 500).map(({ available, ...project }) => project));
  }

  updateProjectCover(sourcePath, coverPath) {
    const normalized = path.resolve(sourcePath);
    const projects = this.readJSON(this.projectsPath(), []);
    const target = projects.find(project => path.resolve(project.sourcePath) === normalized);
    if (!target) return;
    target.coverPath = coverPath;
    target.coverVersion = (target.coverVersion ?? 0) + 1;
    this.writeJSON(this.projectsPath(), projects);
  }

  setProjectsCategory(sourcePaths, category) {
    if (category !== 'fiction' && category !== 'nonfiction') return false;
    const normalized = sourcePaths.map(value => path.resolve(value));
    const projects = this.readJSON(this.projectsPath(), []);
    for (const project of projects) {
      if (!normalized.includes(path.resolve(project.sourcePath))) continue;
      project.category = category;
      const state = this.readJSON(this.projectPath(project.sourcePath), {});
      state.bookCategory = category;
      this.writeJSON(this.projectPath(project.sourcePath), state);
    }
    this.writeJSON(this.projectsPath(), projects);
    return true;
  }

  moveProject(sourcePath, folderID) {
    return this.setProjectsFolderMembership([sourcePath], folderID, true);
  }

  setProjectsFolderMembership(sourcePaths, folderID, included) {
    const normalized = new Set(sourcePaths.map(value => path.resolve(value)));
    const projects = this.readJSON(this.projectsPath(), []);
    let changed = false;
    for (const project of projects) {
      if (!normalized.has(path.resolve(project.sourcePath))) continue;
      const memberships = new Set(Array.isArray(project.folderIDs) ? project.folderIDs : []);
      if (project.folderID) memberships.add(project.folderID);
      if (included) memberships.add(folderID);
      else memberships.delete(folderID);
      project.folderID = null;
      project.folderIDs = [...memberships];
      changed = true;
    }
    if (changed) this.writeJSON(this.projectsPath(), projects);
    return changed;
  }

  saveCover(sourcePath, pngBuffer) {
    const target = this.coverAssetPath(sourcePath);
    fs.writeFileSync(target, pngBuffer);
    this.updateProjectCover(sourcePath, target);
    return target;
  }

  loadCover(sourcePath) {
    const target = this.coverAssetPath(sourcePath);
    return fs.existsSync(target) ? target : null;
  }

  listBookshelfFolders() {
    return this.readJSON(this.bookshelfFoldersPath(), []);
  }

  createBookshelfFolder(name, parentID = null) {
    name = String(name || '').trim();
    if (!name) return null;
    const folders = this.listBookshelfFolders();
    const existing = folders.find(folder => String(folder.name).localeCompare(name, undefined, { sensitivity: 'accent' }) === 0);
    if (existing) return existing;
    const folder = { id: crypto.randomUUID(), name, parentID };
    folders.push(folder);
    this.writeJSON(this.bookshelfFoldersPath(), folders);
    return folder;
  }

  renameBookshelfFolder(id, name) {
    const folders = this.listBookshelfFolders();
    const target = folders.find(folder => folder.id === id);
    if (target) {
      target.name = name;
      this.writeJSON(this.bookshelfFoldersPath(), folders);
    }
    return target;
  }

  deleteBookshelfFolder(id) {
    const folders = this.listBookshelfFolders().filter(folder => folder.id !== id);
    this.writeJSON(this.bookshelfFoldersPath(), folders);
    const projects = this.readJSON(this.projectsPath(), []);
    let changed = false;
    for (const project of projects) {
      const memberships = new Set(Array.isArray(project.folderIDs) ? project.folderIDs : []);
      if (project.folderID) memberships.add(project.folderID);
      if (memberships.delete(id)) changed = true;
      project.folderID = null;
      project.folderIDs = [...memberships];
    }
    if (changed) this.writeJSON(this.projectsPath(), projects);
  }

  loadProject(sourcePath) {
    return this.readJSON(this.projectPath(sourcePath), null);
  }

  saveProject(sourcePath, state) {
    this.writeJSON(this.projectPath(sourcePath), state);
  }

  loadDerived(sourcePath) {
    return this.readJSON(this.derivedPath(sourcePath), null);
  }

  saveDerived(sourcePath, value) {
    this.writeJSON(this.derivedPath(sourcePath), value);
  }

  loadReflowCache(sourcePath, fingerprint, version) {
    const cached = this.readJSON(this.reflowCachePath(sourcePath), null);
    if (!cached || cached.version !== version || cached.fingerprint !== fingerprint || !cached.book) return null;
    const book = { ...cached.book };
    if (book.coverImageBase64) {
      book.coverImageData = Buffer.from(book.coverImageBase64, 'base64');
      delete book.coverImageBase64;
    }
    return book;
  }

  saveReflowCache(sourcePath, fingerprint, version, book) {
    const serializable = { ...book };
    if (serializable.coverImageData) {
      serializable.coverImageBase64 = Buffer.from(serializable.coverImageData).toString('base64');
      delete serializable.coverImageData;
    }
    this.writeJSON(this.reflowCachePath(sourcePath), { version, fingerprint, book: serializable });
  }

  deleteProject(sourcePath) {
    const normalized = path.resolve(sourcePath);
    for (const target of [this.projectPath(normalized), this.derivedPath(normalized), this.reflowCachePath(normalized), this.coverAssetPath(normalized)]) {
      try { fs.rmSync(target, { force: true }); } catch {}
    }
    const projects = this.listProjects().filter(project => path.resolve(project.sourcePath) !== normalized);
    this.writeJSON(this.projectsPath(), projects.map(({ available, ...project }) => project));
  }

  loadSettings() {
    const raw = this.readJSON(path.join(this.root, 'settings.json'), {});
    if (raw.encryptedAPIKey && this.safeStorage.isEncryptionAvailable()) {
      try {
        raw.apiKey = this.safeStorage.decryptString(Buffer.from(raw.encryptedAPIKey, 'base64'));
      } catch { raw.apiKey = ''; }
    }
    delete raw.encryptedAPIKey;
    return raw;
  }

  saveSettings(settings) {
    const stored = { ...settings };
    if (stored.apiKey && this.safeStorage.isEncryptionAvailable()) {
      stored.encryptedAPIKey = this.safeStorage.encryptString(stored.apiKey).toString('base64');
      delete stored.apiKey;
    }
    this.writeJSON(path.join(this.root, 'settings.json'), stored);
  }
}

module.exports = { ReadingStore };
