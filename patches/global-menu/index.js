'use strict';

const { spawn } = require('node:child_process');
const path = require('node:path');

const PATCH_MARKER = Symbol.for('chatgpt.globalMenuPatched');

function diagnostic(context, message) {
  context.diagnostic?.(`[global-menu] ${message}`);
}

function isWaylandRequested() {
  const values = [
    process.env.ELECTRON_OZONE_PLATFORM_HINT,
    ...process.argv,
  ].filter(Boolean).map(String);
  return values.some((value) => /(?:^|=)wayland(?:$|\s)/i.test(value)
    || value === '--ozone-platform=wayland'
    || value === '--ozone-platform-hint=wayland');
}

function nativeWindowId(window) {
  try {
    const handle = window?.getNativeWindowHandle?.();
    if (!Buffer.isBuffer(handle) || handle.length < 4) return null;
    return handle.readUInt32LE(0);
  } catch (_) {
    return null;
  }
}

function normalizeRole(role) {
  return String(role || '').replace(/[^a-z0-9]/gi, '').toLowerCase();
}

function acceleratorParts(accelerator) {
  if (!accelerator) return [];
  const parts = String(accelerator).split('+').map((part) => part.trim()).filter(Boolean);
  const modifiers = [];
  let key = '';
  for (const part of parts) {
    const normalized = part.toLowerCase();
    if (normalized === 'cmdorctrl' || normalized === 'commandorcontrol'
      || normalized === 'ctrl' || normalized === 'control') {
      modifiers.push('Control');
    } else if (normalized === 'cmd' || normalized === 'command' || normalized === 'meta') {
      modifiers.push('Super');
    } else if (normalized === 'alt' || normalized === 'option') {
      modifiers.push('Alt');
    } else if (normalized === 'shift') {
      modifiers.push('Shift');
    } else if (normalized === 'super' || normalized === 'superkey') {
      modifiers.push('Super');
    } else {
      key = part.length === 1 ? part : part.toLowerCase();
    }
  }
  return [...modifiers, key].filter(Boolean);
}

function invokeRole(item, window, electron, context) {
  const role = normalizeRole(item?.role);
  const webContents = window?.webContents;
  switch (role) {
    case 'quit': electron.app?.quit?.(); return true;
    case 'close': window?.close?.(); return true;
    case 'minimize': window?.minimize?.(); return true;
    case 'zoom':
      if (window?.isMaximized?.()) window.unmaximize?.();
      else window?.maximize?.();
      return true;
    case 'front': window?.show?.(); window?.focus?.(); return true;
    case 'reload': webContents?.reload?.(); return true;
    case 'forcereload': webContents?.reloadIgnoringCache?.(); return true;
    case 'toggledevtools': webContents?.toggleDevTools?.(); return true;
    case 'togglefullscreen':
      window?.setFullScreen?.(!window.isFullScreen?.());
      return true;
    case 'undo': webContents?.undo?.(); return true;
    case 'redo': webContents?.redo?.(); return true;
    case 'cut': webContents?.cut?.(); return true;
    case 'copy': webContents?.copy?.(); return true;
    case 'paste': webContents?.paste?.(); return true;
    case 'pasteandmatchstyle': webContents?.pasteAndMatchStyle?.(); return true;
    case 'selectall': webContents?.selectAll?.(); return true;
    case 'delete': webContents?.delete?.(); return true;
    case 'hide': electron.app?.hide?.(); return true;
    case 'unhide': electron.app?.show?.(); return true;
    case 'about': electron.app?.showAboutPanel?.(); return true;
    default:
      diagnostic(context, `role not handled: ${item?.role || 'unknown'}`);
      return false;
  }
}

function createMenuBridge(context) {
  const electron = context.electron;
  const { Menu, BrowserWindow, app } = electron;
  const helperPath = path.join(context.runtimeRoot, 'chatgpt-global-menu.py');
  let itemIds = new WeakMap();
  const itemsById = new Map();
  const windowsById = new Map();
  let nextItemId = 1;
  let child = null;
  let helperReady = false;
  let currentMenu = null;
  let syncTimer = null;
  let lineBuffer = '';

  const windowIdMap = () => {
    const windows = BrowserWindow?.getAllWindows?.() || [];
    const result = new Map();
    for (const window of windows) {
      if (!window || window.isDestroyed?.()) continue;
      const windowId = nativeWindowId(window);
      if (windowId == null) continue;
      result.set(windowId, window);
      windowsById.set(windowId, window);
    }
    for (const windowId of windowsById.keys()) {
      if (!result.has(windowId)) windowsById.delete(windowId);
    }
    return result;
  };

  const serializeItem = (item) => {
    if (!item || typeof item !== 'object') return null;
    let id = itemIds.get(item);
    if (!id) {
      id = nextItemId++;
      itemIds.set(item, id);
    }
    itemsById.set(id, item);
    const children = item.submenu?.items?.map(serializeItem).filter(Boolean) || [];
    const type = item.type === 'separator' ? 'separator'
      : item.type === 'checkbox' ? 'checkbox'
        : item.type === 'radio' ? 'radio' : 'normal';
    return {
      id,
      label: String(item.label || ''),
      type,
      role: item.role || null,
      enabled: item.enabled !== false,
      visible: item.visible !== false,
      checked: item.checked === true,
      accelerator: item.accelerator ? acceleratorParts(item.accelerator) : [],
      children,
    };
  };

  const send = (message) => {
    if (!child?.stdin?.writable) return false;
    try {
      child.stdin.write(`${JSON.stringify(message)}\n`);
      return true;
    } catch (error) {
      diagnostic(context, `helper input failed: ${error.message}`);
      return false;
    }
  };

  const hideWindowMenus = () => {
    if (!helperReady) return;
    for (const window of BrowserWindow?.getAllWindows?.() || []) {
      if (!window || window.isDestroyed?.()) continue;
      try {
        window.setMenuBarVisibility?.(false);
      } catch (error) {
        diagnostic(context, `could not hide window menu: ${error.message}`);
      }
    }
  };

  const restoreWindowMenus = () => {
    for (const window of BrowserWindow?.getAllWindows?.() || []) {
      if (!window || window.isDestroyed?.()) continue;
      try {
        window.setMenuBarVisibility?.(true);
      } catch (error) {
        diagnostic(context, `could not restore window menu: ${error.message}`);
      }
    }
  };

  const sync = () => {
    if (!child || !currentMenu) return;
    const windows = windowIdMap();
    itemIds = new WeakMap();
    itemsById.clear();
    const itemTree = currentMenu.items?.map(serializeItem).filter(Boolean) || [];
    send({ type: 'set-menu', menu: itemTree, windows: [...windows.keys()] });
    hideWindowMenus();
  };

  const scheduleSync = () => {
    if (syncTimer) return;
    syncTimer = setTimeout(() => {
      syncTimer = null;
      sync();
    }, 50);
    syncTimer.unref?.();
  };

  const activate = (windowId, itemId) => {
    const item = itemsById.get(Number(itemId));
    if (!item) {
      diagnostic(context, `activation references unknown item ${itemId}`);
      return;
    }
    const window = windowsById.get(Number(windowId))
      || BrowserWindow?.getFocusedWindow?.()
      || null;
    try {
      if (typeof item.click === 'function') item.click(item, window, {});
      else invokeRole(item, window, electron, context);
      scheduleSync();
    } catch (error) {
      diagnostic(context, `menu item activation failed: ${error.message}`);
      process.emitWarning(`ChatGPT global menu item was skipped: ${error.message}`);
    }
  };

  const handleOutput = (chunk) => {
    lineBuffer += String(chunk);
    const lines = lineBuffer.split(/\r?\n/);
    lineBuffer = lines.pop() || '';
    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        const message = JSON.parse(line);
        if (message.event === 'ready') {
          helperReady = true;
          diagnostic(context, 'GLib DBusMenu helper is ready');
          hideWindowMenus();
          sync();
        } else if (message.event === 'activate') {
          activate(message.window_id, message.item_id);
        } else if (message.event === 'error') {
          diagnostic(context, `helper error: ${message.message}`);
        }
      } catch (error) {
        diagnostic(context, `invalid helper message: ${error.message}`);
      }
    }
  };

  const start = () => {
    if (child) return;
    try {
      child = spawn('python3', [helperPath], { stdio: ['pipe', 'pipe', 'pipe'] });
      child.stdout.on('data', handleOutput);
      child.stderr.on('data', (data) => diagnostic(context, `helper: ${String(data).trim()}`));
      child.once('error', (error) => {
        diagnostic(context, `could not start GLib DBusMenu helper: ${error.message}`);
        restoreWindowMenus();
        child = null;
      });
      child.once('exit', (code, signal) => {
        if (code !== 0 || signal) diagnostic(context, `GLib DBusMenu helper exited (${code ?? signal})`);
        restoreWindowMenus();
        child = null;
        helperReady = false;
      });
      diagnostic(context, 'started GLib DBusMenu helper');
    } catch (error) {
      diagnostic(context, `could not start GLib DBusMenu helper: ${error.message}`);
      child = null;
    }
  };

  const trackWindow = (window) => {
    window?.once?.('closed', () => {
      const windowId = nativeWindowId(window);
      if (windowId != null) {
        windowsById.delete(windowId);
        send({ type: 'remove-window', window_id: windowId });
      }
    });
    scheduleSync();
  };

  app?.on?.('browser-window-created', (_event, window) => trackWindow(window));
  app?.once?.('before-quit', () => {
    if (syncTimer) clearTimeout(syncTimer);
    try {
      child?.stdin?.write('{"type":"shutdown"}\n');
      child?.stdin?.end();
    } catch (_) {
      // Best effort only; the helper exits when the pipe closes.
    }
  });

  return {
    setMenu(menu) {
      currentMenu = menu || null;
      if (!currentMenu) {
        if (child) send({ type: 'set-menu', menu: [], windows: [] });
        return;
      }
      start();
      scheduleSync();
    },
  };
}

module.exports = {
  id: 'global-menu',
  onLoad(context) {
    if (process.platform !== 'linux') return;
    if (process.env.ELECTRON_FORCE_WINDOW_MENU_BAR) {
      diagnostic(context, 'skipped because ELECTRON_FORCE_WINDOW_MENU_BAR is set');
      return;
    }
    if (isWaylandRequested()) {
      diagnostic(context, 'skipped for a Wayland launch; use --ozone-platform=x11 for this implementation');
      return;
    }

    const { Menu } = context.electron;
    if (!Menu || typeof Menu.setApplicationMenu !== 'function') {
      diagnostic(context, 'Menu.setApplicationMenu is unavailable');
      return;
    }
    if (Menu.setApplicationMenu[PATCH_MARKER]) return;

    const bridge = createMenuBridge(context);
    const originalSetApplicationMenu = Menu.setApplicationMenu;
    const setApplicationMenu = function setApplicationMenu(menu) {
      const result = originalSetApplicationMenu.call(this, menu);
      try {
        bridge.setMenu(menu);
      } catch (error) {
        diagnostic(context, `menu synchronization failed: ${error.message}`);
        process.emitWarning(`ChatGPT global menu was skipped: ${error.message}`);
      }
      return result;
    };
    setApplicationMenu[PATCH_MARKER] = true;
    Menu.setApplicationMenu = setApplicationMenu;
    diagnostic(context, 'enabled for X11/XWayland through GLib DBusMenu');
  },
};
