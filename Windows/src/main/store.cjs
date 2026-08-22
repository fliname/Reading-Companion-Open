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

  readJSON(target, fallback) {
    try { return JSON.parse(fs.readFileSync(target, 'utf8')); }
    catch { return fallback; }
  }

  writeJSON(target, value) {
    const temporary = `${target}.${process.pid}.tmp`;
    fs.writeFileSync(temporary, JSON.stringify(value), 'utf8');
    fs.renameSync(temporary, target);
  }

  listProjects() {
    return this.readJSON(path.join(this.root, 'projects.json'), [])
      .map(project => ({ ...project, available: fs.existsSync(project.sourcePath) }))
      .sort((left, right) => new Date(right.lastOpenedAt) - new Date(left.lastOpenedAt));
  }

  registerProject(sourcePath, title) {
    const normalized = path.resolve(sourcePath);
    const projects = this.listProjects().filter(project => path.resolve(project.sourcePath) !== normalized);
    projects.unshift({ sourcePath: normalized, title, lastOpenedAt: new Date().toISOString() });
    this.writeJSON(path.join(this.root, 'projects.json'), projects.slice(0, 80).map(({ available, ...project }) => project));
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

  deleteProject(sourcePath) {
    const normalized = path.resolve(sourcePath);
    for (const target of [this.projectPath(normalized), this.derivedPath(normalized)]) {
      try { fs.rmSync(target, { force: true }); } catch {}
    }
    const projects = this.listProjects().filter(project => path.resolve(project.sourcePath) !== normalized);
    this.writeJSON(path.join(this.root, 'projects.json'), projects.map(({ available, ...project }) => project));
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
