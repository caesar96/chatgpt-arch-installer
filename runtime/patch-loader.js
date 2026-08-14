/* External ChatGPT patch loader. Keep this module dependency-free. */
'use strict';

const fs = require('node:fs');
const Module = require('node:module');
const path = require('node:path');

const root = process.env.CHATGPT_PATCH_ROOT || path.resolve(__dirname, '..');
const appRoot = process.env.CHATGPT_APP_ROOT || path.resolve(root, '..');
let settingsModule;
try {
  settingsModule = require(path.join(root, 'runtime', 'settings.js'));
} catch (error) {
  settingsModule = {
    readSettings: () => ({ systemWindowDecorations: false }),
  };
  process.emitWarning(`ChatGPT settings could not be loaded: ${error.message}`);
}
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
const patchAliases = {
  'native-window-decorations': 'window-decorations',
};
const requested = (process.env.CHATGPT_PATCHES || '')
  .split(',')
  .map((name) => patchAliases[name.trim()] || name.trim())
  .filter(Boolean);
const uniqueRequested = [...new Set(requested)];
const settings = settingsModule.readSettings();
if (settings.systemWindowDecorations && !uniqueRequested.includes('window-decorations')) {
  uniqueRequested.push('window-decorations');
}
let electronModuleProxy;

if (globalThis.__chatgptExternalPatchLoader) {
  return;
}
globalThis.__chatgptExternalPatchLoader = true;

function loadPatches(electron) {
for (const name of uniqueRequested) {
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
      settings,
      nativeDecorations: settings.systemWindowDecorations,
      diagnostic: (message) => {
        const target = process.env.CHATGPT_PATCH_DIAGNOSTIC;
        if (!target) return;
        try {
          fs.mkdirSync(path.dirname(target), { recursive: true });
          fs.appendFileSync(target, `${message}\n`);
        } catch (_) {
          // Diagnostics must never affect application startup.
        }
      },
    };
    if (typeof patch === 'function') patch(context);
    else if (patch && typeof patch.onLoad === 'function') patch.onLoad(context);
  } catch (error) {
    // External hooks are optional; never make the application unlaunchable.
    process.emitWarning(`ChatGPT patch ${name} was skipped: ${error.message}`);
  }
}
}

function createElectronModuleProxy(electron) {
  const target = Object.create(null);
  const overrides = new Map();
  for (const property of Reflect.ownKeys(electron)) {
    const descriptor = Reflect.getOwnPropertyDescriptor(electron, property);
    try {
      Object.defineProperty(target, property, {
        configurable: true,
        enumerable: descriptor?.enumerable === true,
        writable: true,
        value: Reflect.get(electron, property),
      });
    } catch (_) {
      // A rare Electron export that cannot be copied remains available through
      // the fallback in the proxy get trap.
    }
  }
  return new Proxy(target, {
    get(_target, property) {
      if (overrides.has(property)) return overrides.get(property);
      return Reflect.get(target, property) ?? Reflect.get(electron, property);
    },
    set(_target, property, value) {
      overrides.set(property, value);
      Object.defineProperty(target, property, {
        configurable: true,
        enumerable: true,
        writable: true,
        value,
      });
      return true;
    },
    defineProperty(_target, property, descriptor) {
      if ('value' in descriptor) {
        overrides.set(property, descriptor.value);
        Object.defineProperty(target, property, {
          configurable: true,
          enumerable: descriptor.enumerable === true,
          writable: descriptor.writable !== false,
          value: descriptor.value,
        });
        return true;
      }
      return false;
    },
    has(_target, property) {
      return overrides.has(property) || Reflect.has(target, property) || Reflect.has(electron, property);
    },
  });
}

// A NODE_OPTIONS preload runs before Electron installs its special module
// resolver. Wait for the application's first real `require('electron')`, then
// load patches before the caller can use the returned Electron API.
const originalLoad = Module._load;
Module._load = function patchedModuleLoad(request, parent, isMain) {
  const electron = originalLoad.apply(this, arguments);
  if (request === 'electron' && !globalThis.__chatgptExternalPatchesLoaded) {
    globalThis.__chatgptExternalPatchesLoaded = true;
    electronModuleProxy = createElectronModuleProxy(electron);
    loadPatches(electronModuleProxy);
  }
  return request === 'electron' ? electronModuleProxy || electron : electron;
};
