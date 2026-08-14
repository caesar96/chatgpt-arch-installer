'use strict';

const WINDOW_DECORATION_MARKER = Symbol.for('chatgpt.windowDecorationsPatched');
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

function diagnostic(context, message) {
  context.diagnostic?.(`[window-decoration] ${message}`);
}

function shouldPatch(options) {
  if (!options || typeof options !== 'object') return false;
  if (options.transparent === true || options.modal === true || options.parent) return false;
  if (typeof options.type === 'string' && UTILITY_TYPES.has(options.type)) return false;
  if (options.show === false && (!options.width || !options.height)) return false;
  return true;
}

function systemDecorationOptions(originalOptions) {
  const options = { ...originalOptions, frame: true };
  // ChatGPT asks Electron for a hidden title bar on Linux and paints its own
  // title bar. Removing these options lets the window manager own the frame.
  delete options.titleBarStyle;
  delete options.titleBarOverlay;
  return options;
}

function disableTitleBarOverlay(window, context) {
  if (!window || typeof window.setTitleBarOverlay !== 'function') return;
  const marker = Symbol.for('chatgpt.windowDecorationsOverlayDisabled');
  if (window[marker]) return;
  const original = window.setTitleBarOverlay.bind(window);
  try {
    window.setTitleBarOverlay = function ignoredTitleBarOverlay() {
      diagnostic(context, 'ignored setTitleBarOverlay on Linux');
    };
    Object.defineProperty(window, marker, { value: true });
  } catch (_) {
    // A window that cannot be wrapped still gets the corrected constructor
    // options; do not make startup fail because of this optional hook.
    try {
      window.setTitleBarOverlay = original;
    } catch (_) {
      // Ignore read-only Electron objects.
    }
  }
}

function replaceBrowserWindow(electron, BrowserWindow, context) {
  const PatchedBrowserWindow = new Proxy(BrowserWindow, {
    construct(target, argumentsList, newTarget) {
      const originalOptions = argumentsList[0];
      if (!shouldPatch(originalOptions)) {
        return Reflect.construct(target, argumentsList, newTarget);
      }
      const options = systemDecorationOptions(originalOptions);
      diagnostic(context, 'patched main window: native Linux frame options');
      try {
        const window = Reflect.construct(target, [options, ...argumentsList.slice(1)], newTarget);
        disableTitleBarOverlay(window, context);
        return window;
      } catch (error) {
        diagnostic(context, `WARN: patched BrowserWindow construction failed: ${error.message}; retrying original options`);
        return Reflect.construct(target, argumentsList, newTarget);
      }
    },
  });
  Object.defineProperty(PatchedBrowserWindow, WINDOW_DECORATION_MARKER, { value: true });

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
    // The caller will receive a safe warning instead of a startup failure.
  }
  return null;
}

module.exports = {
  onLoad(context) {
    if (process.platform !== 'linux') return;
    if (!context.settings?.systemWindowDecorations) {
      diagnostic(context, 'disabled');
      return;
    }
    const BrowserWindow = context.electron?.BrowserWindow;
    if (typeof BrowserWindow !== 'function') {
      diagnostic(context, 'WARN: BrowserWindow is unavailable; continuing without the patch');
      return;
    }
    if (BrowserWindow[WINDOW_DECORATION_MARKER]) {
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
