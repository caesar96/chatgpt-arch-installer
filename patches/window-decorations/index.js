'use strict';

const windowDecoration = require('./window-decoration.js');
const windowDecorationMenu = require('./window-decoration-menu.js');

module.exports = {
  id: 'window-decorations',
  onLoad(context) {
    windowDecoration.onLoad(context);
    windowDecorationMenu.onLoad(context);
  },
};
