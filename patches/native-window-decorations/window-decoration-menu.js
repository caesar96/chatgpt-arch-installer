'use strict';

const { spawn } = require('node:child_process');

const DECORATION_ITEM_ID = 'chatgpt-native-window-decorations';

function diagnostic(context, message) {
  context.diagnostic?.(`[window-decoration-menu] ${message}`);
}

function preservesNativeWindowMenu(context) {
  const enabledPatches = String(context.settings?.patches || '')
    .split(',')
    .map((patch) => patch.trim())
    .filter(Boolean);
  return !enabledPatches.includes('global-menu');
}

function attachMenuToNativeWindows(menu, context) {
  if (!preservesNativeWindowMenu(context)) return;
  context.nativeApplicationMenu = menu || null;
  for (const window of context.nativeDecoratedWindows || []) {
    if (!window || window.isDestroyed?.()) continue;
    try {
      window.setAutoHideMenuBar?.(false);
      window.setMenu?.(menu || null);
      window.setMenuBarVisibility?.(true);
      const itemCount = window.getMenu?.()?.items?.length ?? 'unknown';
      const visible = window.isMenuBarVisible?.();
      diagnostic(context, `attached Electron application menu to native window (items=${itemCount}, visible=${visible})`);
    } catch (error) {
      diagnostic(context, `WARN: could not attach Electron application menu: ${error.message}`);
    }
  }
}

function findSubmenu(menu, id, labels) {
  if (!menu || !Array.isArray(menu.items)) return null;
  const identified = id && menu.getMenuItemById?.(id);
  if (identified?.submenu) return identified.submenu;
  for (const item of menu.items) {
    if (labels.has(String(item.label).toLowerCase()) && item.submenu) return item.submenu;
    const nested = findSubmenu(item.submenu, id, labels);
    if (nested) return nested;
  }
  return null;
}

function spawnAfterQuit(context, extraArguments = []) {
  if (context.externalActionStarted) return;
  context.externalActionStarted = true;
  const helper = `${context.runtimeRoot}/chatgpt-toggle-window-decorations.sh`;
  const cliPath = `${context.appRoot}/bin/chatgpt`;
  const child = spawn('/bin/sh', [helper, context.appRoot, String(process.pid), cliPath, ...extraArguments], {
    detached: true,
    stdio: 'ignore',
  });
  child.once('error', (error) => diagnostic(context, `helper failed to start: ${error.message}`));
  child.unref();
  diagnostic(context, 'launched native-decoration helper');
  context.electron.app.quit();
}

function addDecorationMenuItem(menu, context, MenuItem) {
  const help = findSubmenu(menu, 'help-menu', new Set(['help']))
    || findSubmenu(menu, 'view-menu', new Set(['view']));
  if (!help || help.getMenuItemById?.(DECORATION_ITEM_ID)) return;
  help.append(new MenuItem({ type: 'separator' }));
  help.append(new MenuItem({
    id: DECORATION_ITEM_ID,
    label: context.nativeDecorations
      ? 'Disable Native Window Decorations'
      : 'Enable Native Window Decorations',
    click: () => spawnAfterQuit(context, [context.nativeDecorations ? 'disable' : 'enable']),
  }));
  diagnostic(context, 'added native decorations to Help');
}

module.exports = {
  onLoad(context) {
    if (process.platform !== 'linux') return;
    const { Menu, MenuItem, app } = context.electron;
    if (!Menu || !MenuItem || !app || typeof Menu.setApplicationMenu !== 'function') return;
    if (Menu.setApplicationMenu.__chatgptExternalDecorationMenuPatch) return;

    const originalSetApplicationMenu = Menu.setApplicationMenu;
    const setApplicationMenu = function setApplicationMenu(menu) {
      try {
        addDecorationMenuItem(menu, context, MenuItem);
      } catch (error) {
        diagnostic(context, `menu patch failed: ${error.message}`);
        process.emitWarning(`ChatGPT native decoration menu was skipped: ${error.message}`);
      }
      const result = originalSetApplicationMenu.call(this, menu);
      attachMenuToNativeWindows(menu, context);
      return result;
    };
    setApplicationMenu.__chatgptExternalDecorationMenuPatch = true;
    Menu.setApplicationMenu = setApplicationMenu;
  },
};
