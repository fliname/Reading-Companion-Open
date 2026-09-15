const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { Readable } = require('node:stream');
const { pipeline } = require('node:stream/promises');

const LATEST_RELEASE_API = 'https://api.github.com/repos/fliname/Reading-Companion-Open/releases/latest';
const WINDOWS_ASSET = /^Reading-Companion-Open-([0-9]+(?:\.[0-9]+){2,3})-Windows-x64-Setup\.exe$/i;

function versionParts(value = '') {
  return String(value).split('.').map(part => Number(part) || 0);
}

function compareVersions(left, right) {
  const a = versionParts(left);
  const b = versionParts(right);
  for (let index = 0; index < Math.max(a.length, b.length); index += 1) {
    const difference = (a[index] || 0) - (b[index] || 0);
    if (difference) return Math.sign(difference);
  }
  return 0;
}

function selectWindowsUpdate(release, currentVersion) {
  const matches = (release?.assets || []).flatMap(asset => {
    const match = WINDOWS_ASSET.exec(asset.name || '');
    return match ? [{ ...asset, version: match[1] }] : [];
  }).sort((a, b) => compareVersions(b.version, a.version));
  const asset = matches[0];
  if (!asset || compareVersions(asset.version, currentVersion) <= 0) return null;
  return {
    version: asset.version,
    name: asset.name,
    size: Number(asset.size) || 0,
    digest: asset.digest || null,
    downloadURL: asset.browser_download_url,
    releaseName: release.name || release.tag_name || asset.version,
    notes: release.body || ''
  };
}

async function checkForWindowsUpdate(currentVersion, fetchImpl = fetch) {
  const response = await fetchImpl(LATEST_RELEASE_API, {
    headers: {
      accept: 'application/vnd.github+json',
      'user-agent': `Reading-Companion-Open/${currentVersion}`,
      'x-github-api-version': '2022-11-28'
    }
  });
  if (!response.ok) throw new Error(`检查更新失败（${response.status}）`);
  return selectWindowsUpdate(await response.json(), currentVersion);
}

async function sha256File(target) {
  const hash = crypto.createHash('sha256');
  await pipeline(fs.createReadStream(target), hash);
  return hash.digest('hex');
}

async function downloadWindowsUpdate(update, directory, fetchImpl = fetch, onProgress) {
  await fsp.mkdir(directory, { recursive: true });
  const target = path.join(directory, path.basename(update.name));
  const partial = `${target}.part`;
  const response = await fetchImpl(update.downloadURL, {
    headers: { 'user-agent': 'Reading-Companion-Open-Updater' },
    redirect: 'follow'
  });
  if (!response.ok || !response.body) throw new Error(`下载安装包失败（${response.status}）`);
  const expected = Number(response.headers.get('content-length')) || update.size || 0;
  let received = 0;
  const source = Readable.fromWeb(response.body);
  source.on('data', chunk => {
    received += chunk.length;
    onProgress?.({ received, expected, fraction: expected ? received / expected : 0 });
  });
  try {
    await pipeline(source, fs.createWriteStream(partial));
    if (update.digest?.startsWith('sha256:')) {
      const actual = await sha256File(partial);
      if (actual.toLowerCase() !== update.digest.slice(7).toLowerCase()) throw new Error('安装包完整性校验失败，请稍后重试。');
    }
    await fsp.rename(partial, target).catch(async error => {
      if (error.code !== 'EEXIST' && error.code !== 'EPERM') throw error;
      await fsp.unlink(target);
      await fsp.rename(partial, target);
    });
    return target;
  } catch (error) {
    await fsp.unlink(partial).catch(() => {});
    throw error;
  }
}

module.exports = {
  LATEST_RELEASE_API,
  compareVersions,
  selectWindowsUpdate,
  checkForWindowsUpdate,
  downloadWindowsUpdate,
  sha256File
};
