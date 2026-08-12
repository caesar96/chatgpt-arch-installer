/* External ChatGPT patch loader. Keep this module dependency-free. */
'use strict';

const fs = require('node:fs');
const Module = require('node:module');
const path = require('node:path');

const root = process.env.CHATGPT_PATCH_ROOT || path.resolve(__dirname, '..');
const appRoot = process.env.CHATGPT_APP_ROOT || path.resolve(root, '..');
function readInstalledVersion() {
  try {
    return fs.readFileSync(path.join(appRoot, 'usr/lib/chatgpt/version'), 'ascii').trim() || 'unknown';
  } catch (_) {
    return 'unknown';
  }
}

const installedVersion = readInstalledVersion();
const appVersion = process.env.CHATGPT_APP_VERSION || installedVersion;
// This bundled build exposes a Chromium-like value as process.versions.electron.
// The installed runtime version file is the verified compatibility identifier.
const electronVersion = process.env.CHATGPT_ELECTRON_VERSION || installedVersion;
const cliPath = process.env.CHATGPT_CLI_PATH || '';
const requested = (process.env.CHATGPT_PATCHES || '')
  .split(',')
  .map((name) => name.trim())
  .filter(Boolean);

if (globalThis.__chatgptExternalPatchLoader) {
  return;
}
globalThis.__chatgptExternalPatchLoader = true;

function loadPatches(electron) {
for (const name of requested) {
  try {
    if (!/^[a-z0-9-]+$/.test(name)) {
      throw new Error(`invalid ChatGPT patch name: ${name}`);
    }
    const patchRoot = path.join(root, 'patches', name);
    const manifest = require(path.join(patchRoot, 'manifest.json'));
    if (manifest.id !== name || manifest.entry !== 'main.js' || manifest.apiVersion !== 1) {
      throw new Error('invalid patch manifest');
    }
    if (manifest.applicationVersions && !manifest.applicationVersions.includes(appVersion)) {
      throw new Error(`unsupported ChatGPT version ${appVersion}`);
    }
    if (manifest.electronVersions && !manifest.electronVersions.includes(electronVersion)) {
      throw new Error(`unsupported Electron version ${electronVersion}`);
    }
    const patch = require(path.join(patchRoot, manifest.entry));
    const context = {
      appRoot,
      runtimeRoot: path.join(root, 'runtime'),
      appVersion,
      electronVersion,
      cliPath,
      electron,
      nativeDecorations: process.env.CHATGPT_NATIVE_DECORATIONS === '1',
    };
    if (typeof patch === 'function') patch(context);
    else if (patch && typeof patch.onLoad === 'function') patch.onLoad(context);
  } catch (error) {
    // External hooks are optional; never make the application unlaunchable.
    process.emitWarning(`ChatGPT patch ${name} was skipped: ${error.message}`);
  }
}
}

// A NODE_OPTIONS preload runs before Electron installs its special module
// resolver. Wait for the application's first real `require('electron')`, then
// load patches before the caller can use the returned Electron API.
const originalLoad = Module._load;
Module._load = function patchedModuleLoad(request, parent, isMain) {
  const electron = originalLoad.apply(this, arguments);
  if (request === 'electron' && !globalThis.__chatgptExternalPatchesLoaded) {
    globalThis.__chatgptExternalPatchesLoaded = true;
    loadPatches(electron);
  }
  return electron;
};
