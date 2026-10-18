// Hidden print window: the receipt page calls window.print() when it has loaded; send it to the printer with no dialog.
'use strict';
const { ipcRenderer } = require('electron');
window.print = function () { ipcRenderer.send('coconut:do-print'); };
