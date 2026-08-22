const fs = require('node:fs');
const path = require('node:path');

function pathAPI(value = '') {
  return /^[A-Za-z]:[\\/]/.test(String(value)) || String(value).includes('\\') ? path.win32 : path;
}

function normalized(value = '') {
  const api = pathAPI(value);
  const resolved = api.resolve(String(value));
  return api === path.win32 ? resolved.toLowerCase() : resolved;
}

function registeredVaults(registryPath) {
  try {
    const registry = JSON.parse(fs.readFileSync(registryPath, 'utf8'));
    return Object.values(registry.vaults || {})
      .filter(value => value && typeof value.path === 'string' && value.path.trim())
      .sort((left, right) => {
        if (!!left.open !== !!right.open) return left.open ? -1 : 1;
        if (Number(left.ts || 0) !== Number(right.ts || 0)) return Number(right.ts || 0) - Number(left.ts || 0);
        return left.path.localeCompare(right.path);
      })
      .map(value => pathAPI(value.path).resolve(value.path));
  } catch { return []; }
}

function exactVault(candidate, registered) {
  const target = normalized(candidate);
  return registered.find(vault => normalized(vault) === target) || null;
}

function containingVault(item, registered) {
  const target = normalized(item);
  return registered
    .filter(vault => {
      const root = normalized(vault);
      const separator = pathAPI(vault).sep;
      return target === root || target.startsWith(root.endsWith(separator) ? root : root + separator);
    })
    .sort((left, right) => normalized(right).length - normalized(left).length)[0] || null;
}

function openURL(vault, note) {
  const api = pathAPI(vault);
  const root = api.resolve(vault);
  const target = api.resolve(note);
  const relative = api.relative(root, target);
  if (!relative || relative === '..' || relative.startsWith(`..${api.sep}`) || api.isAbsolute(relative)) return null;
  const vaultName = api.basename(root);
  const file = relative.split(api.sep).join('/');
  const encode = value => encodeURIComponent(value).replace(/[!'()*]/g, character => `%${character.charCodeAt(0).toString(16).toUpperCase()}`);
  return `obsidian://open?vault=${encode(vaultName)}&file=${encode(file)}`;
}

module.exports = { registeredVaults, exactVault, containingVault, openURL };
