'use strict';

const MAC_LAYOUT_MARKER = Symbol.for('chatgpt.macLayoutPatched');
const UTILITY_TYPES = new Set([
  'background',
  'dialog',
  'notification',
  'panel',
  'popup',
  'splash',
  'toolbar',
  'tooltip',
]);

// Run in the page's main world before the vendor renderer starts. The Linux
// OS marker is intentionally untouched; only the renderer chrome mode changes.
const FORCE_NATIVE_CHROME_SCRIPT = String.raw`(() => {
  if (window.__chatgptMacLayoutHookInstalled) return;
  window.__chatgptMacLayoutHookInstalled = true;

  const forceNativeChrome = () => {
    const root = document.documentElement;
    if (!root) return;
    if (root.getAttribute('data-codex-window-chrome') !== 'native') {
      root.setAttribute('data-codex-window-chrome', 'native');
    }
  };

  forceNativeChrome();

  // The renderer assigns the attribute during bootstrap. Re-apply the value
  // immediately when that assignment is observed, before React settles on the
  // application-menu layout.
  const observer = new MutationObserver((records) => {
    if (records.some((record) => record.attributeName === 'data-codex-window-chrome')) {
      forceNativeChrome();
    }
  });
  observer.observe(document, {
    subtree: true,
    attributes: true,
    attributeFilter: ['data-codex-window-chrome'],
  });

  window.addEventListener('DOMContentLoaded', forceNativeChrome);
})();`;

function diagnostic(context, message) {
  context.diagnostic?.(`[mac-layout] ${message}`);
}

function shouldPatch(options) {
  if (!options || typeof options !== 'object') return false;
  if (options.transparent === true || options.modal === true || options.parent) return false;
  if (typeof options.type === 'string' && UTILITY_TYPES.has(options.type)) return false;
  if (options.show === false && (!options.width || !options.height)) return false;
  return true;
}

function installRendererHook(window, context) {
  const webContents = window?.webContents;
  if (!webContents) {
    diagnostic(context, 'WARN: BrowserWindow webContents is unavailable');
    return;
  }

  if (typeof webContents.addScriptToEvaluateOnNewDocument === 'function') {
    try {
      Promise.resolve(webContents.addScriptToEvaluateOnNewDocument(FORCE_NATIVE_CHROME_SCRIPT))
        .then(() => diagnostic(context, 'registered native renderer chrome hook'))
        .catch((error) => diagnostic(context, `WARN: renderer chrome hook failed: ${error.message}`));
      return;
    } catch (error) {
      diagnostic(context, `WARN: renderer chrome hook registration failed: ${error.message}`);
    }
  }

  // Older bundled Electron runtimes may not expose the DevTools protocol
  // registration method. Execute the same hook at the earliest loading events
  // available in those runtimes, with the page-side marker making retries safe.
  if (typeof webContents.executeJavaScript !== 'function' || typeof webContents.on !== 'function') {
    diagnostic(context, 'WARN: webContents has neither document-start injection nor executeJavaScript');
    return;
  }

  let injected = false;
  const inject = () => {
    if (injected) return;
    try {
      Promise.resolve(webContents.executeJavaScript(FORCE_NATIVE_CHROME_SCRIPT, true))
        .then(() => {
          injected = true;
          diagnostic(context, 'registered native renderer chrome hook through executeJavaScript');
        })
        .catch((error) => diagnostic(context, `WARN: executeJavaScript renderer hook failed: ${error.message}`));
    } catch (error) {
      diagnostic(context, `WARN: executeJavaScript renderer hook failed: ${error.message}`);
    }
  };
  webContents.on('did-start-loading', inject);
  webContents.on('dom-ready', inject);
  diagnostic(context, 'using executeJavaScript renderer hook fallback');
}

function replaceBrowserWindow(electron, BrowserWindow, context) {
  const PatchedBrowserWindow = new Proxy(BrowserWindow, {
    construct(target, argumentsList, newTarget) {
      const originalOptions = argumentsList[0];
      const window = Reflect.construct(target, argumentsList, newTarget);
      if (shouldPatch(originalOptions)) {
        installRendererHook(window, context);
        diagnostic(context, 'patched renderer window chrome to native layout');
      }
      return window;
    },
  });
  Object.defineProperty(PatchedBrowserWindow, MAC_LAYOUT_MARKER, { value: true });

  const descriptor = Object.getOwnPropertyDescriptor(electron, 'BrowserWindow');
  try {
    if (!descriptor || descriptor.writable || descriptor.configurable) {
      electron.BrowserWindow = PatchedBrowserWindow;
      if (electron.BrowserWindow === PatchedBrowserWindow) return PatchedBrowserWindow;
    }
  } catch (_) {
    // Try defineProperty below; some Electron builds expose a configurable getter.
  }
  try {
    Object.defineProperty(electron, 'BrowserWindow', {
      configurable: true,
      enumerable: descriptor?.enumerable ?? true,
      value: PatchedBrowserWindow,
      writable: true,
    });
    if (electron.BrowserWindow === PatchedBrowserWindow) return PatchedBrowserWindow;
  } catch (_) {
    // The caller will receive a diagnostic instead of a startup failure.
  }
  return null;
}

module.exports = {
  onLoad(context) {
    if (process.platform !== 'linux') return;

    const BrowserWindow = context.electron?.BrowserWindow;
    if (typeof BrowserWindow !== 'function') {
      diagnostic(context, 'WARN: BrowserWindow is unavailable; continuing without the patch');
      return;
    }
    if (BrowserWindow[MAC_LAYOUT_MARKER]) {
      diagnostic(context, 'BrowserWindow interception already installed');
      return;
    }

    const patched = replaceBrowserWindow(context.electron, BrowserWindow, context);
    if (!patched) {
      diagnostic(context, 'WARN: BrowserWindow interception could not be installed; continuing without the patch');
      return;
    }
    diagnostic(context, 'enabled');
    diagnostic(context, 'BrowserWindow interception installed');
  },
};
