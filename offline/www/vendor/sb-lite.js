/* Coconut POS Stand alone: a very small Supabase client (sign-in, RPC, simple table reads/updates).
   Used only while the internet is available: online sign-in, the licence check-in, and staff management. */
(function () {
  'use strict';
  function SbLite(url, key, storeKey) {
    var KEY = storeKey || 'cp_sb_session';
    var self = this;
    function load() { try { return JSON.parse(localStorage.getItem(KEY) || 'null'); } catch (e) { return null; } }
    function save(s) { try { if (s) localStorage.setItem(KEY, JSON.stringify(s)); else localStorage.removeItem(KEY); } catch (e) {} }
    var session = load();
    function err(r, j) { return { message: (j && (j.msg || j.message || j.error_description || j.error)) || ('HTTP ' + r.status), code: j && (j.code || j.error_code), status: r.status }; }
    function req(path, opts) {
      opts = opts || {};
      var h = Object.assign({ apikey: key, 'Content-Type': 'application/json' }, opts.headers || {});
      var ctl = typeof AbortController !== 'undefined' ? new AbortController() : null; var tm = ctl ? setTimeout(function () { ctl.abort(); }, opts.timeout || 12000) : 0;
      return fetch(url + path, { method: opts.method || 'GET', headers: h, body: opts.body == null ? undefined : JSON.stringify(opts.body), signal: ctl ? ctl.signal : undefined })
        .then(function (r) { clearTimeout(tm); return r; }, function (e) { clearTimeout(tm); throw e; })
        .then(function (r) { return r.text().then(function (t) { var j = null; try { j = t ? JSON.parse(t) : null; } catch (e) {} return r.ok ? { data: j, error: null } : { data: null, error: err(r, j) }; }); })
        .catch(function (e) { return { data: null, error: { message: String(e && e.message || e), network: true } }; });
    }
    function setSession(d) { session = d ? { access_token: d.access_token, refresh_token: d.refresh_token, expires_at: Math.floor(Date.now() / 1000) + (d.expires_in || 3600), user: d.user } : null; save(session); return session; }
    function fresh() {
      if (!session) return Promise.resolve(null);
      if (session.expires_at - 60 > Date.now() / 1000) return Promise.resolve(session);
      return req('/auth/v1/token?grant_type=refresh_token', { method: 'POST', body: { refresh_token: session.refresh_token } }).then(function (r) {
        if (r.error) { if (!r.error.network) setSession(null); return r.error.network ? session : null; }
        return setSession(r.data);
      });
    }
    function authed(path, opts) { return fresh().then(function (s) { opts = opts || {}; opts.headers = Object.assign({ Authorization: 'Bearer ' + (s ? s.access_token : key) }, opts.headers || {}); return req(path, opts); }); }
    this.auth = {
      signInWithPassword: function (c) {
        return req('/auth/v1/token?grant_type=password', { method: 'POST', body: { email: c.email, password: c.password } }).then(function (r) {
          if (r.error) return { data: { session: null }, error: r.error };
          return { data: { session: setSession(r.data), user: r.data.user }, error: null };
        });
      },
      getSession: function () { return fresh().then(function (s) { return { data: { session: s } }; }); },
      signOut: function () { var s = session; setSession(null); if (s) req('/auth/v1/logout', { method: 'POST', headers: { Authorization: 'Bearer ' + s.access_token } }); return Promise.resolve({ error: null }); },
      onAuthStateChange: function () { return { data: { subscription: { unsubscribe: function () {} } } }; },
    };
    this.rpc = function (fn, args) { return authed('/rest/v1/rpc/' + fn, { method: 'POST', body: args || {} }); };
    this.from = function (table) {
      var q = [], method = 'GET', body = null, single = false, sel = '*';
      var b = {
        select: function (c) { sel = c || '*'; return b; },
        eq: function (k, v) { q.push(encodeURIComponent(k) + '=eq.' + encodeURIComponent(v)); return b; },
        order: function (k, o) { q.push('order=' + encodeURIComponent(k) + (o && o.ascending === false ? '.desc' : '.asc')); return b; },
        limit: function (n) { q.push('limit=' + (+n)); return b; },
        maybeSingle: function () { single = true; return b; },
        update: function (d) { method = 'PATCH'; body = d; return b; },
        then: function (ok, bad) {
          var path = '/rest/v1/' + table + '?' + (method === 'GET' ? 'select=' + encodeURIComponent(sel) + '&' : '') + q.join('&');
          return authed(path, { method: method, body: body, headers: method === 'GET' ? {} : { Prefer: 'return=minimal' } })
            .then(function (r) { if (single && !r.error) r.data = (r.data && r.data[0]) || null; return r; }).then(ok, bad);
        },
      };
      return b;
    };
    this.session = function () { return session; };
  }
  window.SbLite = SbLite;
})();
