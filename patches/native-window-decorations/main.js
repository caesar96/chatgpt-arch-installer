'use strict';

// The verified Python patch remains responsible for the stable native-window
// behavior. This hook is intentionally passive: it gives future builds a
// place for a supported Electron-level implementation without risking startup.
module.exports = {
  id: 'native-window-decorations',
  onLoad() {},
};
