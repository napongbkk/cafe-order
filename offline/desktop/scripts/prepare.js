// Copies the built POS web app (../www) and the local server (../server) into ./app for packaging.
const fs = require('fs');
const path = require('path');
const root = path.join(__dirname, '..');
const out = path.join(root, 'app');
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });
fs.cpSync(path.join(root, '..', 'www'), path.join(out, 'www'), { recursive: true });
fs.cpSync(path.join(root, '..', 'server'), path.join(out, 'server'), { recursive: true });
if (!fs.existsSync(path.join(out, 'www', 'index.html'))) { console.error('offline/www/index.html missing: run python3 tools/build_pos.py first'); process.exit(1); }
console.log('app prepared:', fs.readdirSync(out).join(', '));
