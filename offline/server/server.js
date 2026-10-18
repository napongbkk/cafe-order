// Coconut POS Stand alone: the shop's local server.
// Serves the POS app to every device on the same Wi-Fi/LAN and keeps the shop's data on this machine
// (SQLite when the runtime has node:sqlite, otherwise a snapshot + journal file). See ../API.md.
'use strict';
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');

let DatabaseSync = null;
try { ({ DatabaseSync } = require('node:sqlite')); } catch (e) { DatabaseSync = null; }

const VERSION = '1.0.0';
const NAME_RE = /^[A-Za-z0-9_.:-]{1,128}$/;
const FIELD_RE = /^[A-Za-z0-9_]{1,64}(\.[A-Za-z0-9_]{1,64}){0,3}$/;
const ASSET_RE = /^[a-f0-9]{20}\.[a-z0-9]{2,5}$/;
const OPS = { '==': '=', '!=': '!=', '>': '>', '>=': '>=', '<': '<', '<=': '<=' };
const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.webp': 'image/webp', '.gif': 'image/gif', '.ico': 'image/x-icon', '.woff2': 'font/woff2', '.woff': 'font/woff',
  '.mp4': 'video/mp4', '.webm': 'video/webm', '.mov': 'video/quicktime', '.webmanifest': 'application/manifest+json',
};
const EXT = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'image/gif': 'gif', 'video/mp4': 'mp4', 'video/webm': 'webm', 'video/quicktime': 'mov' };

function merge(a, b) { // deep merge, same as the online pos_jsonb_merge
  if (a && b && typeof a === 'object' && typeof b === 'object' && !Array.isArray(a) && !Array.isArray(b)) {
    const out = Object.assign({}, a);
    for (const k of Object.keys(b)) out[k] = k in a ? merge(a[k], b[k]) : b[k];
    return out;
  }
  return b;
}
function getPath(o, f) { return f.split('.').reduce((a, k) => (a == null ? undefined : a[k]), o); }
function test(v, op, x) {
  if (typeof x === 'number') v = v == null ? v : Number(v);
  if (typeof x === 'boolean' && typeof v === 'number') v = !!v;
  switch (op) {
    case '==': return v === x; case '!=': return v !== x; case '>': return v > x; case '>=': return v >= x;
    case '<': return v < x; case '<=': return v <= x; case 'in': return Array.isArray(x) && x.includes(v); default: return true;
  }
}

function lanAddresses() {
  const out = [];
  for (const [name, list] of Object.entries(os.networkInterfaces())) {
    for (const n of list || []) if (n.family === 'IPv4' && !n.internal) out.push({ name, address: n.address });
  }
  return out.sort((a, b) => (/^192\.168\./.test(b.address) - /^192\.168\./.test(a.address)));
}

// SQLite store (Node 22.13+): one row per document.
function sqliteStore(dir) {
  const db = new DatabaseSync(path.join(dir, 'coconut-pos.db'));
  db.exec(`pragma journal_mode = wal; pragma synchronous = normal;
    create table if not exists docs(col text not null, id text not null, data text not null, seq integer not null, primary key(col, id));
    create table if not exists meta(k text primary key, v text);`);
  const qGet = db.prepare('select data from docs where col = ? and id = ?');
  const qPut = db.prepare('insert into docs(col, id, data, seq) values(?, ?, ?, ?) on conflict(col, id) do update set data = excluded.data, seq = excluded.seq');
  const qDel = db.prepare('delete from docs where col = ? and id = ?');
  const qMeta = db.prepare('select v from meta where k = ?');
  const qSetMeta = db.prepare('insert into meta(k, v) values(?, ?) on conflict(k) do update set v = excluded.v');
  return {
    kind: 'sqlite',
    meta: (k) => { const r = qMeta.get(k); return r ? r.v : null; },
    setMeta: (k, v) => { qSetMeta.run(k, String(v)); },
    get: (col, id) => { const r = qGet.get(col, id); return r ? JSON.parse(r.data) : null; },
    put: (col, id, data, seq) => { qPut.run(col, id, JSON.stringify(data), seq); },
    del: (col, id) => { qDel.run(col, id); },
    query(col, where, order, limit) {
      let sql = 'select id, data from docs where col = ?'; const args = [col];
      for (const [f, op, v] of where) {
        const ex = `json_extract(data, '$.${f}')`;
        if (op === 'in') { sql += ` and ${ex} in (${v.map(() => '?').join(',')})`; args.push(...v.map((x) => (typeof x === 'boolean' ? +x : x))); }
        else { sql += ` and ${ex} ${OPS[op]} ?`; args.push(typeof v === 'boolean' ? +v : v); }
      }
      if (order) sql += ` order by json_extract(data, '$.${order[0]}') ${order[1] === 'desc' ? 'desc' : 'asc'}`;
      sql += ' limit ?'; args.push(limit);
      return db.prepare(sql).all(...args).map((r) => ({ id: r.id, data: JSON.parse(r.data) }));
    },
    all: () => db.prepare('select col, id, data from docs').all().map((r) => ({ col: r.col, id: r.id, data: JSON.parse(r.data) })),
    backup: (file) => { db.exec(`vacuum into '${file.replace(/'/g, "''")}'`); },
    close: () => { db.close(); },
  };
}

// Plain-file store (any Node): a snapshot plus an append-only journal, compacted now and then.
function fileStore(dir) {
  const snapF = path.join(dir, 'coconut-pos.json'), jF = path.join(dir, 'coconut-pos.journal');
  const cols = new Map(); let meta = {}; let jLines = 0;
  const colOf = (c) => { let m = cols.get(c); if (!m) { m = new Map(); cols.set(c, m); } return m; };
  if (fs.existsSync(snapF)) {
    try { const s = JSON.parse(fs.readFileSync(snapF, 'utf8')); meta = s.meta || {}; for (const [c, docs] of Object.entries(s.cols || {})) for (const [id, d] of Object.entries(docs)) colOf(c).set(id, d); }
    catch (e) { console.error('snapshot unreadable', e.message); }
  }
  if (fs.existsSync(jF)) {
    for (const line of fs.readFileSync(jF, 'utf8').split('\n')) {
      if (!line) continue; let x; try { x = JSON.parse(line); } catch (e) { continue; } jLines++;
      if (x.m) meta[x.m] = x.v; else if (x.del) colOf(x.c).delete(x.i); else colOf(x.c).set(x.i, x.d);
    }
  }
  let fd = fs.openSync(jF, 'a');
  function compact() {
    const out = { meta, cols: {} }; for (const [c, m] of cols) out.cols[c] = Object.fromEntries(m);
    fs.writeFileSync(snapF + '.tmp', JSON.stringify(out)); fs.renameSync(snapF + '.tmp', snapF);
    fs.closeSync(fd); fs.writeFileSync(jF, ''); fd = fs.openSync(jF, 'a'); jLines = 0;
  }
  function write(o) { fs.writeSync(fd, JSON.stringify(o) + '\n'); if (++jLines > 5000) compact(); }
  const copy = (d) => JSON.parse(JSON.stringify(d));
  return {
    kind: 'file',
    meta: (k) => (k in meta ? meta[k] : null),
    setMeta: (k, v) => { meta[k] = String(v); write({ m: k, v: String(v) }); },
    get: (col, id) => { const d = colOf(col).get(id); return d === undefined ? null : copy(d); },
    put: (col, id, data) => { colOf(col).set(id, copy(data)); write({ c: col, i: id, d: data }); },
    del: (col, id) => { colOf(col).delete(id); write({ c: col, i: id, del: 1 }); },
    query(col, where, order, limit) {
      const rows = [...colOf(col)].map(([id, data]) => ({ id, data })).filter((r) => where.every(([f, op, v]) => test(getPath(r.data, f), op, v)));
      if (order) rows.sort((a, b) => { const A = getPath(a.data, order[0]), B = getPath(b.data, order[0]); const c = A == null ? -1 : B == null ? 1 : A < B ? -1 : A > B ? 1 : 0; return order[1] === 'desc' ? -c : c; });
      return rows.slice(0, limit).map((r) => ({ id: r.id, data: copy(r.data) }));
    },
    all: () => { const out = []; for (const [c, m] of cols) for (const [id, data] of m) out.push({ col: c, id, data: copy(data) }); return out; },
    backup: (file) => { compact(); fs.copyFileSync(snapF, file.replace(/\.db$/, '.json')); },
    close: () => { try { compact(); fs.closeSync(fd); } catch (e) {} },
  };
}

function createServer(opts) {
  const dataDir = opts.dataDir;
  const wwwDir = path.resolve(opts.wwwDir);
  const port = +opts.port || 8080;
  fs.mkdirSync(path.join(dataDir, 'assets'), { recursive: true });
  fs.mkdirSync(path.join(dataDir, 'backups'), { recursive: true });

  const store = (DatabaseSync && opts.storage !== 'file') ? sqliteStore(dataDir) : fileStore(dataDir);
  let deviceId = store.meta('deviceId');
  if (!deviceId) { deviceId = 'srv' + crypto.randomBytes(9).toString('hex'); store.setMeta('deviceId', deviceId); }
  let seq = +(store.meta('seq') || 0);
  const started = Date.now();
  const changes = []; // recent [seq, col]
  let waiters = [];

  function bump(col) {
    seq += 1; store.setMeta('seq', seq);
    changes.push([seq, col]); if (changes.length > 2000) changes.splice(0, changes.length - 2000);
    const w = waiters; waiters = [];
    for (const x of w) x();
    return seq;
  }
  function since(n) { // changed collections after n, or null when the client must reload everything
    if (n > seq || (changes.length && n < changes[0][0] - 1) || (!changes.length && n < seq)) return null;
    return [...new Set(changes.filter((c) => c[0] > n).map((c) => c[1]))];
  }
  const getDoc = (col, id) => store.get(col, id);
  const putDoc = (col, id, data) => { store.put(col, id, data, seq + 1); return bump(col); };
  function query(col, where, order, limit) {
    const w = [];
    for (const x of Array.isArray(where) ? where : []) {
      if (!Array.isArray(x)) continue;
      const [f, op, v] = x;
      if (!FIELD_RE.test(String(f))) throw Object.assign(new Error('bad_field'), { status: 400 });
      if (op === 'in' && Array.isArray(v) && v.length && v.length <= 200) w.push([f, op, v]);
      else if (OPS[op] && (typeof v === 'number' || typeof v === 'string' || typeof v === 'boolean')) w.push([f, op, v]);
    }
    const o = Array.isArray(order) && FIELD_RE.test(String(order[0])) ? order : null;
    return store.query(col, w, o, Math.min(Math.max(+limit || 50000, 1), 50000));
  }

  // Daily copy of the data, 14 kept.
  function backup() {
    try {
      const d = new Date(); const stamp = `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}${String(d.getDate()).padStart(2, '0')}`;
      const file = path.join(dataDir, 'backups', `coconut-pos-${stamp}.db`);
      if (!fs.existsSync(file) && !fs.existsSync(file.replace(/\.db$/, '.json'))) store.backup(file);
      const all = fs.readdirSync(path.join(dataDir, 'backups')).filter((f) => /^coconut-pos-\d{8}\.(db|json)$/.test(f)).sort();
      while (all.length > 14) fs.rmSync(path.join(dataDir, 'backups', all.shift()), { force: true });
    } catch (e) { console.error('backup failed', e.message); }
  }
  const backupTimer = setInterval(backup, 3600 * 1000); backup();

  function info() {
    return { app: 'coconut-pos-offline', version: opts.version || VERSION, deviceId, name: opts.deviceName || os.hostname(), platform: opts.platform || process.platform,
      port, lan: lanAddresses().map((a) => a.address), seq, started, storage: store.kind };
  }

  const send = (res, code, obj, headers) => { const b = Buffer.from(JSON.stringify(obj)); res.writeHead(code, Object.assign({ 'Content-Type': 'application/json', 'Content-Length': b.length, 'Cache-Control': 'no-store' }, headers || {})); res.end(b); };
  function body(req, max) {
    return new Promise((resolve, reject) => {
      const parts = []; let n = 0;
      req.on('data', (c) => { n += c.length; if (n > max) { reject(Object.assign(new Error('too_large'), { status: 413 })); req.destroy(); } else parts.push(c); });
      req.on('end', () => resolve(Buffer.concat(parts))); req.on('error', reject);
    });
  }
  const json = async (req, max) => { const b = await body(req, max || 20 * 1024 * 1024); try { return b.length ? JSON.parse(b.toString('utf8')) : {}; } catch (e) { throw Object.assign(new Error('bad_json'), { status: 400 }); } };
  function serveFile(res, file, cache) {
    fs.stat(file, (err, st) => {
      if (err || !st.isFile()) { res.writeHead(404, { 'Content-Type': 'text/plain' }); res.end('Not found'); return; }
      res.writeHead(200, { 'Content-Type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream', 'Content-Length': st.size, 'Cache-Control': cache || 'no-cache' });
      fs.createReadStream(file).pipe(res);
    });
  }

  async function handle(req, res) {
    const u = new URL(req.url, 'http://x');
    let p; try { p = decodeURIComponent(u.pathname); } catch (e) { return send(res, 400, { error: 'bad_path' }); }
    const seg = p.split('/').filter(Boolean);
    const m = req.method;
    if (seg[0] === 'api') {
      if (seg[1] === 'info' && m === 'GET') return send(res, 200, info());
      if (seg[1] === 'col' && seg.length === 3 && m === 'GET') {
        if (!NAME_RE.test(seg[2])) return send(res, 400, { error: 'bad_name' });
        let w = null, o = null;
        try { w = u.searchParams.get('w') ? JSON.parse(u.searchParams.get('w')) : null; o = u.searchParams.get('o') ? JSON.parse(u.searchParams.get('o')) : null; }
        catch (e) { return send(res, 400, { error: 'bad_query' }); }
        return send(res, 200, { seq, docs: query(seg[2], w, o, u.searchParams.get('l')) });
      }
      if (seg[1] === 'doc' && seg.length === 4) {
        const col = seg[2], id = seg[3];
        if (!NAME_RE.test(col) || !NAME_RE.test(id)) return send(res, 400, { error: 'bad_name' });
        if (m === 'GET') return send(res, 200, { data: getDoc(col, id) });
        if (m === 'PUT') { const b = await json(req); if (!b || typeof b.data !== 'object' || b.data === null || Array.isArray(b.data)) return send(res, 400, { error: 'bad_data' }); return send(res, 200, { ok: true, seq: putDoc(col, id, b.data) }); }
        if (m === 'PATCH') { const b = await json(req); const cur = getDoc(col, id); if (cur == null) return send(res, 404, { error: 'not_found' }); const next = merge(cur, b.patch || {}); return send(res, 200, { ok: true, data: next, seq: putDoc(col, id, next) }); }
        if (m === 'DELETE') { store.del(col, id); return send(res, 200, { ok: true, seq: bump(col) }); }
      }
      if (seg[1] === 'lease' && seg.length === 4 && m === 'POST') {
        const col = seg[2], id = seg[3]; const b = await json(req);
        if (!NAME_RE.test(col) || !NAME_RE.test(id) || !b.holder) return send(res, 400, { error: 'bad_lease' });
        const ttl = Math.max(1000, Math.min(+b.ttlMs || 30000, 600000)); const cur = getDoc(col, id); const now = Date.now();
        if (cur && cur.holder !== b.holder && +cur.untilMs > now) return send(res, 200, { acquired: false, expiresAt: new Date(+cur.untilMs).toISOString() });
        const exp = now + ttl; store.put(col, id, { holder: String(b.holder), untilMs: exp, until: new Date(exp).toISOString() }, seq); // no change event: leases renew often
        return send(res, 200, { acquired: true, expiresAt: new Date(exp).toISOString() });
      }
      if (seg[1] === 'changes' && m === 'GET') {
        const n = +(u.searchParams.get('since') || 0);
        const reply = () => send(res, 200, { seq, cols: since(n) });
        if (n !== seq) return reply();
        let done = false;
        const fin = () => { if (done) return; done = true; clearTimeout(t); reply(); };
        const t = setTimeout(() => { waiters = waiters.filter((x) => x !== fin); fin(); }, Math.min(+(u.searchParams.get('wait') || 25), 55) * 1000);
        waiters.push(fin);
        req.on('close', () => { if (!done) { done = true; clearTimeout(t); waiters = waiters.filter((x) => x !== fin); } });
        return;
      }
      if (seg[1] === 'asset' && seg.length === 2 && m === 'POST') {
        const ty = String(req.headers['content-type'] || '').split(';')[0].trim();
        const ext = EXT[ty]; if (!ext) return send(res, 415, { error: 'bad_type' });
        const b = await body(req, 60 * 1024 * 1024); const id = crypto.randomBytes(10).toString('hex') + '.' + ext;
        fs.writeFileSync(path.join(dataDir, 'assets', id), b);
        return send(res, 200, { id, sizeBytes: b.length, contentType: ty });
      }
      if (seg[1] === 'asset' && seg.length === 3 && m === 'DELETE') { if (ASSET_RE.test(seg[2])) fs.rmSync(path.join(dataDir, 'assets', seg[2]), { force: true }); return send(res, 200, { ok: true }); }
      if (seg[1] === 'export' && m === 'GET') {
        const out = {};
        for (const r of store.all()) if (r.col !== '_sys' && r.col !== 'bridge') (out[r.col] = out[r.col] || []).push(Object.assign({ id: r.id }, r.data));
        return send(res, 200, { app: 'coconut-pos-offline', exportedAt: new Date().toISOString(), collections: out }, { 'Content-Disposition': 'attachment; filename="coconut-pos-backup.json"' });
      }
      return send(res, 404, { error: 'not_found' });
    }
    if (seg[0] === 'assets' && seg.length === 2 && ASSET_RE.test(seg[1])) return serveFile(res, path.join(dataDir, 'assets', seg[1]), 'public, max-age=31536000, immutable');
    let rel = p === '/' ? '/index.html' : p;
    if (rel.endsWith('/')) rel += 'index.html';
    const file = path.normalize(path.join(wwwDir, rel));
    if (!file.startsWith(wwwDir + path.sep) && file !== wwwDir) { res.writeHead(403); res.end(); return; }
    if (!path.extname(file) && !fs.existsSync(file)) return serveFile(res, path.join(wwwDir, 'index.html'));
    return serveFile(res, file);
  }

  const server = http.createServer((req, res) => {
    handle(req, res).catch((e) => { if (!res.headersSent) send(res, e.status || 500, { error: e.message || 'server_error' }); else res.end(); });
  });
  server.keepAliveTimeout = 65000;

  return {
    info,
    store,
    start: () => new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '0.0.0.0', () => resolve(info())); }),
    stop: () => new Promise((resolve) => { clearInterval(backupTimer); for (const w of waiters) w(); server.close(() => { try { store.close(); } catch (e) {} resolve(); }); if (server.closeAllConnections) server.closeAllConnections(); setTimeout(resolve, 3000); }),
    backupNow: backup,
  };
}

module.exports = { createServer, lanAddresses, VERSION };

if (require.main === module) {
  const arg = (k, d) => { const i = process.argv.indexOf('--' + k); return i > 0 ? process.argv[i + 1] : d; };
  const srv = createServer({ dataDir: path.resolve(arg('data', path.join(os.homedir(), 'CoconutPOS'))), wwwDir: path.resolve(arg('www', path.join(__dirname, '..', 'www'))),
    port: +arg('port', 8080), platform: arg('platform', undefined), storage: arg('storage', undefined) });
  srv.start().then((i) => {
    console.log(`Coconut POS Stand alone ${i.version} (${i.storage}) on port ${i.port}`);
    for (const a of i.lan) console.log(`  http://${a}:${i.port}`);
    console.log(`  http://localhost:${i.port}`);
  }).catch((e) => { console.error(e.code === 'EADDRINUSE' ? `Port ${arg('port', 8080)} is in use` : e.message); process.exit(1); });
  const bye = () => srv.stop().then(() => process.exit(0));
  process.on('SIGINT', bye); process.on('SIGTERM', bye);
}
