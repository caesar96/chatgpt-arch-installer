'use strict';

const fs = require('node:fs');
const path = require('node:path');

function configPath() {
  return process.env.CHATGPT_CONFIG_FILE
    || path.join(process.env.XDG_CONFIG_HOME || path.join(process.env.HOME || '.', '.config'), 'chatgpt', 'settings.conf');
}

function parseBoolean(value) {
  return ['1', 'true', 'yes', 'on'].includes(String(value || '').trim().toLowerCase());
}

function readSettings(filePath = configPath()) {
  const values = {};
  try {
    const text = fs.readFileSync(filePath, 'utf8');
    for (const line of text.split(/\r?\n/)) {
      const separator = line.indexOf('=');
      if (separator <= 0) continue;
      values[line.slice(0, separator).trim()] = line.slice(separator + 1).trim();
    }
  } catch (_) {
    // Missing or unreadable settings must never prevent the app from opening.
  }
  const legacyValue = values.native_decorations;
  const configuredValue = values.use_system_window_decorations;
  return {
    ...values,
    configPath: filePath,
    systemWindowDecorations: configuredValue !== undefined
      ? parseBoolean(configuredValue)
      : parseBoolean(legacyValue),
  };
}

function writeValues(values, filePath = configPath()) {
  const directory = path.dirname(filePath);
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  let original = '';
  try {
    original = fs.readFileSync(filePath, 'utf8');
  } catch (_) {
    // The file may not exist on a first launch.
  }
  const keys = new Set(Object.keys(values));
  const lines = original ? original.split(/\r?\n/) : [];
  const written = new Set();
  const output = lines.map((line) => {
    const separator = line.indexOf('=');
    if (separator <= 0) return line;
    const key = line.slice(0, separator).trim();
    if (!keys.has(key)) return line;
    written.add(key);
    return `${key}=${values[key]}`;
  });
  for (const key of keys) {
    if (!written.has(key)) output.push(`${key}=${values[key]}`);
  }
  while (output.length && output[output.length - 1] === '') output.pop();
  output.push('');
  const temporary = path.join(directory, `.${path.basename(filePath)}.${process.pid}.tmp`);
  fs.writeFileSync(temporary, output.join('\n'), { mode: 0o600 });
  try {
    fs.chmodSync(temporary, 0o600);
  } catch (_) {
    // Best effort on filesystems without Unix permissions.
  }
  fs.renameSync(temporary, filePath);
}

function setSystemWindowDecorations(enabled, filePath = configPath()) {
  writeValues({
    use_system_window_decorations: enabled ? 'true' : 'false',
    native_decorations: enabled ? '1' : '0',
  }, filePath);
  return readSettings(filePath);
}

module.exports = {
  configPath,
  readSettings,
  setSystemWindowDecorations,
};
