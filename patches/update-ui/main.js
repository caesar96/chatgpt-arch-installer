'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const UPDATE_ITEM_ID = 'chatgpt-external-check-for-updates';
const DECORATION_ITEM_ID = 'chatgpt-external-native-decorations';
const STARTUP_CHECK_DELAY_MS = 3500;

function diagnostic(message) {
  const target = process.env.CHATGPT_PATCH_DIAGNOSTIC;
  if (!target) return;
  try {
    fs.appendFileSync(target, `${message}\n`);
  } catch (_) {
    // Diagnostics must never affect application startup.
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

function parseCheckResult(output) {
  const result = {};
  for (const line of output.split(/\r?\n/)) {
    const separator = line.indexOf('=');
    if (separator > 0) {
      result[line.slice(0, separator)] = line.slice(separator + 1);
    }
  }
  return result;
}

function getParentWindow(context) {
  const BrowserWindow = context.electron.BrowserWindow;
  if (typeof BrowserWindow !== 'function') return null;
  const focusedWindow = BrowserWindow.getFocusedWindow?.();
  if (focusedWindow && !focusedWindow.isDestroyed?.()) return focusedWindow;
  const windows = BrowserWindow.getAllWindows?.() || [];
  return windows.find((window) => !window.isDestroyed?.()) || null;
}

function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function getUpdateTheme(context) {
  const dark = context.electron.nativeTheme?.shouldUseDarkColors ?? true;
  return dark
    ? {
      background: '#171717',
      surface: '#232323',
      surfaceRaised: '#2d2d2d',
      border: '#414141',
      text: '#f5f5f5',
      muted: '#b5b5b5',
      accent: '#8ab4f8',
      accentText: '#101010',
    }
    : {
      background: '#f7f7f8',
      surface: '#ffffff',
      surfaceRaised: '#f0f0f2',
      border: '#d7d7dc',
      text: '#202124',
      muted: '#5f6368',
      accent: '#1a73e8',
      accentText: '#ffffff',
    };
}

function centerWindowOnParent(window, parentWindow, fallbackWidth, fallbackHeight) {
  const parentBounds = parentWindow?.getBounds?.();
  if (!parentBounds) {
    window.center?.();
    return;
  }
  const windowBounds = window.getBounds?.() || {};
  const width = windowBounds.width || fallbackWidth;
  const height = windowBounds.height || fallbackHeight;
  const x = Math.round(parentBounds.x + (parentBounds.width - width) / 2);
  const y = Math.round(parentBounds.y + (parentBounds.height - height) / 2);
  window.setPosition?.(x, y, false);
}

function updateDialogHtml(context, options) {
  const theme = getUpdateTheme(context);
  const checking = options.checking === true;
  const downloading = options.downloading === true;
  const updateAvailable = options.updateAvailable === true;
  const message = escapeHtml(options.message);
  const detail = escapeHtml(options.detail).replaceAll('\n', '<br>');
  const icon = checking || downloading
    ? '<div class="spinner" aria-hidden="true"></div>'
    : `<div class="status-mark ${options.type === 'error' ? 'error' : ''}" aria-hidden="true">${options.type === 'error' ? '!' : 'i'}</div>`;
  const buttons = checking || downloading
    ? ''
    : updateAvailable
      ? '<button class="button primary" data-action="update">Update Now</button><button class="button secondary" data-action="later">Later</button>'
      : '<button class="button primary" data-action="later">OK</button>';

  return `<!doctype html>
<html><head><meta charset="utf-8"><style>
  :root {
    --background: ${theme.background};
    --surface: ${theme.surface};
    --surface-raised: ${theme.surfaceRaised};
    --border: ${theme.border};
    --text: ${theme.text};
    --muted: ${theme.muted};
    --accent: ${theme.accent};
    --accent-text: ${theme.accentText};
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; min-height: 100%; }
  body { background: var(--surface); color: var(--text); font: 14px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  .window { background: var(--surface); display: flex; flex-direction: column; min-height: 100vh; overflow: hidden; }
  .content { align-items: center; display: flex; flex: 1; flex-direction: column; justify-content: center; padding: 8px 28px 22px; text-align: center; }
  .status-mark { align-items: center; background: var(--accent); border-radius: 50%; color: var(--accent-text); display: flex; font-size: 15px; font-weight: 700; height: 28px; justify-content: center; margin-bottom: 13px; width: 28px; }
  .status-mark.error { background: #d93025; color: #ffffff; }
  .spinner { animation: spin 1s linear infinite; border: 3px solid var(--border); border-radius: 50%; border-top-color: var(--accent); height: 26px; margin: 0 auto 15px; width: 26px; }
  .progress { background: var(--border); border-radius: 999px; height: 10px; margin: 18px auto 0; max-width: 390px; overflow: hidden; width: 100%; }
  .progress-value { background: var(--accent); height: 100%; transition: width .15s ease; width: ${Math.max(0, Math.min(100, Number(options.progress) || 0))}%; }
  h1 { font-size: 17px; line-height: 1.3; margin: 0 0 10px; }
  p { color: var(--muted); line-height: 1.45; margin: 0; max-width: 410px; }
  .actions { background: var(--surface-raised); border-top: 1px solid var(--border); display: flex; gap: 10px; justify-content: flex-end; padding: 12px 14px; }
  .button { border: 1px solid var(--border); border-radius: 6px; cursor: pointer; font: inherit; font-weight: 600; min-width: 112px; padding: 8px 16px; }
  .button.primary { background: var(--accent); border-color: var(--accent); color: var(--accent-text); }
  .button.secondary { background: transparent; color: var(--text); }
  .button:hover { filter: brightness(1.08); }
  .button:focus { outline: 2px solid var(--accent); outline-offset: 2px; }
  @keyframes spin { to { transform: rotate(360deg); } }
</style></head><body>
  <div class="window">
    <main class="content">${icon}<h1>${message}</h1><p>${detail}</p>${downloading ? '<div class="progress" role="progressbar" aria-valuemin="0" aria-valuemax="100"><div class="progress-value"></div></div>' : ''}</main>
    ${buttons ? `<footer class="actions">${buttons}</footer>` : ''}
  </div>
  <script>
    document.querySelectorAll('[data-action]').forEach((button) => {
      button.addEventListener('click', () => {
        window.location.href = 'chatgpt-update-dialog:' + button.dataset.action;
      });
    });
  </script>
</body></html>`;
}

function createUpdateWindow(context, parentWindow, options) {
  const BrowserWindow = context.electron.BrowserWindow;
  if (typeof BrowserWindow !== 'function') return null;
  const checking = options.checking === true;
  const downloading = options.downloading === true;
  const width = checking ? 380 : 500;
  const height = checking ? 170 : downloading ? 250 : 285;
  const theme = getUpdateTheme(context);
  let updateWindow = null;
  let settled = false;
  let settleResult;
  const result = new Promise((resolve) => {
    settleResult = (response) => {
      if (settled) return;
      settled = true;
      resolve({ response });
    };
  });

  const closeWithResponse = (response) => {
    settleResult(response);
    if (updateWindow && !updateWindow.isDestroyed?.()) updateWindow.close?.();
  };

  try {
    updateWindow = new BrowserWindow({
      width,
      height,
      resizable: false,
      minimizable: false,
      maximizable: false,
      closable: !checking && !downloading,
      frame: true,
      useContentSize: true,
      show: false,
      title: 'ChatGPT Updates',
      backgroundColor: theme.background,
      ...(parentWindow ? { parent: parentWindow, modal: true } : {}),
      webPreferences: {
        contextIsolation: true,
        nodeIntegration: false,
      },
    });
    updateWindow.setMenuBarVisibility?.(false);
    updateWindow.webContents.on('will-navigate', (event, url) => {
      if (!url.startsWith('chatgpt-update-dialog:')) return;
      event.preventDefault();
      closeWithResponse(url.endsWith(':update') ? 0 : 1);
    });
    updateWindow.webContents.setWindowOpenHandler?.(({ url }) => {
      if (url.startsWith('chatgpt-update-dialog:')) {
        closeWithResponse(url.endsWith(':update') ? 0 : 1);
      }
      return { action: 'deny' };
    });
    updateWindow.on('closed', () => settleResult(1));
    const loadResult = updateWindow.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(updateDialogHtml(context, options))}`);
    const showWindow = () => {
      if (updateWindow?.isDestroyed?.()) return;
      centerWindowOnParent(updateWindow, parentWindow, width, height);
      updateWindow.show?.();
      updateWindow.focus?.();
    };
    updateWindow.once?.('ready-to-show', showWindow);
    updateWindow.webContents.once?.('did-finish-load', showWindow);
    loadResult?.catch?.(() => closeWithResponse(1));
    return { window: updateWindow, result };
  } catch (_) {
    settleResult(1);
    return { window: null, result };
  }
}

function showUpdateDialog(context, parentWindow, options) {
  const customWindow = createUpdateWindow(context, parentWindow, {
    ...options,
    updateAvailable: options.buttons?.[0] === 'Update Now',
  });
  if (customWindow?.window) return customWindow.result;
  const dialog = context.electron.dialog;
  if (!dialog?.showMessageBox) return Promise.resolve({ response: 1 });
  if (parentWindow && !parentWindow.isDestroyed?.()) {
    parentWindow.focus?.();
    return dialog.showMessageBox(parentWindow, options);
  }
  return dialog.showMessageBox(options);
}

function openCheckingWindow(context, parentWindow) {
  const customWindow = createUpdateWindow(context, parentWindow, {
    checking: true,
    message: 'Checking for updates...',
    detail: 'The latest ChatGPT package is being checked. This may take a moment.',
    type: 'info',
  });
  return customWindow?.window || null;
}

function openDownloadWindow(context, parentWindow, version) {
  const customWindow = createUpdateWindow(context, parentWindow, {
    downloading: true,
    progress: 0,
    message: `Downloading ChatGPT ${version}...`,
    detail: 'The update will be installed after the download reaches 100%.',
    type: 'info',
  });
  if (!customWindow) return null;
  customWindow.progress = 0;
  customWindow.window?.webContents.once?.('did-finish-load', () => {
    applyDownloadProgress(customWindow, customWindow.progress);
  });
  return customWindow;
}

function updateDownloadWindow(downloadWindow, progress) {
  const safeProgress = Math.max(0, Math.min(100, Number(progress) || 0));
  if (!downloadWindow) return;
  downloadWindow.progress = safeProgress;
  if (!downloadWindow.window || downloadWindow.window.isDestroyed?.()) return;
  if (!downloadWindow.window.webContents.isLoading?.()) {
    applyDownloadProgress(downloadWindow, safeProgress);
  }
}

function applyDownloadProgress(downloadWindow, safeProgress) {
  if (!downloadWindow?.window || downloadWindow.window.isDestroyed?.()) return;
  const scriptResult = downloadWindow.window.webContents.executeJavaScript?.(
    `document.querySelector('.progress-value')?.style.setProperty('width', '${safeProgress}%');` +
    `document.querySelector('.progress')?.setAttribute('aria-valuenow', '${safeProgress}');` +
    `document.querySelector('p').textContent = ${JSON.stringify(`${safeProgress}% downloaded`)};`,
    true,
  );
  scriptResult?.catch?.(() => {});
}

function closeDownloadWindow(downloadWindow) {
  if (!downloadWindow?.window || downloadWindow.window.isDestroyed?.()) return;
  downloadWindow.window.destroy?.();
}

function closeCheckingWindow(checkingWindow) {
  if (!checkingWindow || checkingWindow.isDestroyed()) return;
  checkingWindow.destroy();
}

function checkForUpdates(context, mode = 'manual') {
  if (context.externalActionStarted || context.updateCheckStarted || context.updatePromptStarted || context.updateDownloadStarted) return;
  context.updateCheckStarted = true;

  const cliPath = path.join(context.appRoot, 'installer');
  const parentWindow = getParentWindow(context);
  const checkingWindow = mode === 'manual' ? openCheckingWindow(context, parentWindow) : null;
  const child = spawn(cliPath, ['check-update', mode], {
    stdio: ['ignore', 'pipe', 'pipe'],
    env: process.env,
  });
  let output = '';
  let errorOutput = '';
  let completed = false;

  const finish = (error, exitCode) => {
    if (completed) return;
    completed = true;
    context.updateCheckStarted = false;
    closeCheckingWindow(checkingWindow);

    if (error || exitCode !== 0) {
      const detail = error?.message || errorOutput.trim() || `The update check exited with code ${exitCode}.`;
      if (mode === 'startup') return;
      showUpdateDialog(context, parentWindow, {
        type: 'error',
        title: 'ChatGPT Updates',
        message: 'Could not check for updates.',
        detail,
        buttons: ['OK'],
      }).catch(() => {});
      return;
    }

    const result = parseCheckResult(output);
    if (result.status === 'up-to-date') {
      if (mode === 'startup') return;
      showUpdateDialog(context, parentWindow, {
        type: 'info',
        title: 'ChatGPT Updates',
        message: 'ChatGPT is up to date.',
        detail: `Installed version: ${result['installed-version'] || 'unknown'}\nLatest version: ${result['available-version'] || 'unknown'}`,
        buttons: ['OK'],
      }).catch(() => {});
      return;
    }

    if (result.status !== 'update-available') {
      if (result.status === 'throttled' || mode === 'startup') return;
      showUpdateDialog(context, parentWindow, {
        type: 'error',
        title: 'ChatGPT Updates',
        message: 'The update check returned an invalid result.',
        detail: output.trim() || 'No update status was returned.',
        buttons: ['OK'],
      }).catch(() => {});
      return;
    }

    context.updatePromptStarted = true;
    showUpdateDialog(context, parentWindow, {
      type: 'info',
      title: 'ChatGPT Updates',
      message: `ChatGPT ${result['available-version']} is available.`,
      detail: `Installed version: ${result['installed-version'] || 'unknown'}\nThe update will be downloaded after you choose Update Now.`,
      buttons: ['Update Now', 'Later'],
      cancelId: 1,
      defaultId: 0,
    }).then(({ response }) => {
      context.updatePromptStarted = false;
      if (response === 0) {
        downloadAndInstallUpdate(context, parentWindow, result['available-version'], result.etag);
      }
    }).catch(() => {
      context.updatePromptStarted = false;
    });
  };

  child.stdout.on('data', (chunk) => {
    output += chunk.toString();
  });
  child.stderr.on('data', (chunk) => {
    errorOutput += chunk.toString();
  });
  child.once('error', (error) => finish(error, 1));
  child.once('close', (exitCode) => finish(null, exitCode));
}

function downloadAndInstallUpdate(context, parentWindow, version, etag) {
  if (context.externalActionStarted || context.updateDownloadStarted) return;
  context.updateDownloadStarted = true;
  const downloadWindow = openDownloadWindow(context, parentWindow, version || 'latest');
  if (!downloadWindow) {
    context.updateDownloadStarted = false;
    showUpdateDialog(context, parentWindow, {
      type: 'error',
      title: 'ChatGPT Updates',
      message: 'Could not open the download window.',
      detail: 'The update was not started.',
      buttons: ['OK'],
    }).catch(() => {});
    return;
  }
  const cliPath = path.join(context.appRoot, 'installer');
  const childArguments = ['download-update'];
  if (etag) childArguments.push(etag);
  const child = spawn(cliPath, childArguments, {
    stdio: ['ignore', 'pipe', 'pipe'],
    env: process.env,
  });
  let output = '';
  let errorOutput = '';
  let completed = false;
  const finish = (error, exitCode) => {
    if (completed) return;
    completed = true;
    context.updateDownloadStarted = false;
    if (error || exitCode !== 0) {
      closeDownloadWindow(downloadWindow);
      const detail = error?.message || errorOutput.trim() || `The update download exited with code ${exitCode}.`;
      showUpdateDialog(context, parentWindow, {
        type: 'error',
        title: 'ChatGPT Updates',
        message: 'Could not download the update.',
        detail,
        buttons: ['OK'],
      }).catch(() => {});
      return;
    }
    const result = parseCheckResult(output);
    if (result.status === 'up-to-date') {
      closeDownloadWindow(downloadWindow);
      showUpdateDialog(context, parentWindow, {
        type: 'info',
        title: 'ChatGPT Updates',
        message: 'ChatGPT is already up to date.',
        detail: `Installed version: ${result['installed-version'] || 'unknown'}\nLatest version: ${result['available-version'] || 'unknown'}`,
        buttons: ['OK'],
      }).catch(() => {});
      return;
    }
    if (result.status !== 'ready' || !result['package-path']) {
      closeDownloadWindow(downloadWindow);
      showUpdateDialog(context, parentWindow, {
        type: 'error',
        title: 'ChatGPT Updates',
        message: 'The update download returned an invalid result.',
        detail: output.trim() || 'No downloaded package was returned.',
        buttons: ['OK'],
      }).catch(() => {});
      return;
    }
    updateDownloadWindow(downloadWindow, 100);
    setTimeout(() => {
      closeDownloadWindow(downloadWindow);
      spawnAfterQuit(context, 'update-from-menu.sh', [result['package-path']]);
    }, 450);
  };
  let outputLineBuffer = '';
  child.stdout.on('data', (chunk) => {
    const text = chunk.toString();
    output += text;
    outputLineBuffer += text;
    const lines = outputLineBuffer.split(/\r?\n/);
    outputLineBuffer = lines.pop() || '';
    for (const line of lines) {
      if (line.startsWith('progress=')) updateDownloadWindow(downloadWindow, line.slice(9));
    }
  });
  child.stderr.on('data', (chunk) => {
    errorOutput += chunk.toString();
  });
  child.once('error', (error) => finish(error, 1));
  child.once('close', (exitCode) => finish(null, exitCode));
}

function scheduleStartupCheck(context) {
  if (context.startupCheckScheduled || context.externalActionStarted) return;
  context.startupCheckScheduled = true;
  const schedule = () => {
    setTimeout(() => {
      context.startupCheckScheduled = false;
      checkForUpdates(context, 'startup');
    }, STARTUP_CHECK_DELAY_MS).unref?.();
  };
  if (context.electron.app.isReady?.()) schedule();
  else context.electron.app.once?.('ready', schedule);
}

function spawnAfterQuit(context, helperName, extraArguments = []) {
  if (context.externalActionStarted) return;
  context.externalActionStarted = true;
  const helper = path.join(context.runtimeRoot, helperName);
  const cliPath = path.join(context.appRoot, 'installer');
  const child = spawn('/bin/sh', [helper, context.appRoot, String(process.pid), cliPath, ...extraArguments], {
    detached: true,
    stdio: 'ignore',
  });
  child.once('error', (error) => diagnostic(`update-ui: updater helper failed to start: ${error.message}`));
  child.unref();
  context.electron.app.quit();
  // Some packaged builds prevent quit while a local session is active. The
  // updater helper must still get a reliable process exit after a short grace
  // period; it waits for this PID before replacing application files.
  setTimeout(() => {
    try {
      context.electron.app.exit(0);
    } catch (_) {
      // The app may already have exited cleanly.
    }
  }, 750).unref();
}

function addPatchItems(menu, context, MenuItem) {
  const help = findSubmenu(menu, 'help-menu', new Set(['help']));
  if (help && !help.getMenuItemById?.(UPDATE_ITEM_ID)) {
    help.append(new MenuItem({
      type: 'separator',
    }));
    help.append(new MenuItem({
      id: UPDATE_ITEM_ID,
      label: 'Check for Updates...',
      click: () => checkForUpdates(context, 'manual'),
    }));
    diagnostic('update-ui: added Check for Updates to Help');
  }

  const decorationMenu = help || findSubmenu(menu, 'view-menu', new Set(['view']));
  if (decorationMenu && !decorationMenu.getMenuItemById?.(DECORATION_ITEM_ID)) {
    decorationMenu.append(new MenuItem({ type: 'separator' }));
    decorationMenu.append(new MenuItem({
      id: DECORATION_ITEM_ID,
      label: context.nativeDecorations
        ? 'Disable Native Window Decorations'
        : 'Enable Native Window Decorations',
      click: () => {
        spawnAfterQuit(
          context,
          'toggle-native-decoration.sh',
          [context.nativeDecorations ? 'disable' : 'enable'],
        );
      },
    }));
    diagnostic('update-ui: added native decorations to Help');
  }
}

module.exports = {
  id: 'update-ui',
  onLoad(context) {
    const electron = context.electron;
    const { Menu, MenuItem, app } = electron;
    if (!Menu || !MenuItem || !app) return;
    if (Menu.setApplicationMenu.__chatgptExternalUpdatePatch) return;

    const originalSetApplicationMenu = Menu.setApplicationMenu;
    const setApplicationMenu = function setApplicationMenu(menu) {
      try {
        addPatchItems(menu, context, MenuItem);
      } catch (error) {
        diagnostic(`update-ui: menu patch failed: ${error.message}`);
        process.emitWarning(`ChatGPT update menu was skipped: ${error.message}`);
      }
      return originalSetApplicationMenu.call(this, menu);
    };
    setApplicationMenu.__chatgptExternalUpdatePatch = true;
    Menu.setApplicationMenu = setApplicationMenu;
    scheduleStartupCheck(context);
  },
};
