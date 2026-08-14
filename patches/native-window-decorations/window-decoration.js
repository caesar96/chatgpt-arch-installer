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

function preservesNativeWindowMenu(context) {
  const enabledPatches = String(context.settings?.patches || '')
    .split(',')
    .map((patch) => patch.trim())
    .filter(Boolean);
  return !enabledPatches.includes('global-menu');
}

function rememberNativeWindow(window, context) {
  if (!context.nativeDecoratedWindows) context.nativeDecoratedWindows = new Set();
  context.nativeDecoratedWindows.add(window);
  window.once?.('closed', () => context.nativeDecoratedWindows?.delete(window));
}

function attachApplicationMenu(window, context) {
  const menu = context.nativeApplicationMenu;
  if (!menu || typeof window?.setMenu !== 'function') return;
  try {
    window.setMenu(menu);
    const itemCount = window.getMenu?.()?.items?.length ?? 'unknown';
    const visible = window.isMenuBarVisible?.();
    diagnostic(context, `attached Electron application menu to native window (items=${itemCount}, visible=${visible})`);
  } catch (error) {
    diagnostic(context, `WARN: could not attach Electron application menu: ${error.message}`);
  }
}

function systemDecorationOptions(originalOptions, context) {
  const options = { ...originalOptions, frame: true };
  // ChatGPT asks Electron for a hidden title bar on Linux and paints its own
  // title bar. Removing these options lets the window manager own the frame.
  delete options.titleBarStyle;
  delete options.titleBarOverlay;
  if (preservesNativeWindowMenu(context)) {
    // The vendor creates a native Electron menu, then configures normal Linux
    // windows to hide it. Keep it visible when the Global Menu is disabled.
    options.autoHideMenuBar = false;
  }
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

function preserveNativeWindowMenu(window, context) {
  if (!preservesNativeWindowMenu(context)) return;
  if (!window) return;
  try {
    rememberNativeWindow(window, context);
    // ChatGPT configures Linux windows with autoHideMenuBar and later calls
    // removeMenu(). The native-menu mode must keep Electron's application
    // menu visible after both operations, not only at construction time.
    window.setAutoHideMenuBar?.(false);

    const originalSetMenuBarVisibility = typeof window.setMenuBarVisibility === 'function'
      ? window.setMenuBarVisibility.bind(window)
      : null;
    const ignoredMenuBarHide = function ignoredMenuBarHide(visible) {
      if (visible === false) {
        diagnostic(context, 'ignored vendor setMenuBarVisibility(false); keeping native in-window menu');
      }
      if (originalSetMenuBarVisibility) return originalSetMenuBarVisibility(true);
      return undefined;
    };
    try {
      Object.defineProperty(window, 'setMenuBarVisibility', {
        configurable: true,
        enumerable: false,
        writable: true,
        value: ignoredMenuBarHide,
      });
    } catch (_) {
      window.setMenuBarVisibility = ignoredMenuBarHide;
    }
    window.setMenuBarVisibility?.(true);
    attachApplicationMenu(window, context);
    if (typeof window.removeMenu !== 'function') return;
    const ignoredVendorRemoveMenu = function ignoredVendorRemoveMenu() {
      diagnostic(context, 'ignored vendor removeMenu; keeping native in-window menu');
      this.setMenuBarVisibility?.(true);
    };
    try {
      Object.defineProperty(window, 'removeMenu', {
        configurable: true,
        enumerable: false,
        writable: true,
        value: ignoredVendorRemoveMenu,
      });
    } catch (_) {
      window.removeMenu = ignoredVendorRemoveMenu;
    }
  } catch (error) {
    diagnostic(context, `WARN: could not preserve native in-window menu: ${error.message}`);
  }
}

function replaceBrowserWindow(electron, BrowserWindow, context) {
  const PatchedBrowserWindow = new Proxy(BrowserWindow, {
    construct(target, argumentsList, newTarget) {
      const originalOptions = argumentsList[0];
      if (!shouldPatch(originalOptions)) {
        return Reflect.construct(target, argumentsList, newTarget);
      }
      const options = systemDecorationOptions(originalOptions, context);
      diagnostic(context, 'patched main window: native Linux frame options');
      try {
        const window = Reflect.construct(target, [options, ...argumentsList.slice(1)], newTarget);
        disableTitleBarOverlay(window, context);
        preserveNativeWindowMenu(window, context);
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
