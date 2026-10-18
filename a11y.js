/* Coconut POS accessibility helper (WCAG 2.2 A + AAA fixes shared by every page).
   - Skip link to the main content, a main landmark and an H1 when a page has none
   - Dialogs: aria-modal, focus moves in, Tab stays inside, Escape closes, focus returns to the opener
   - Toast / message areas are live regions so screen readers announce them
   - Decorative SVG icons are hidden from screen readers
   - Page title follows the current screen (nav item marked aria-current)
   - Visible 3:1 focus ring, 44px touch targets, reduced motion
   Loaded as /a11y.js on static pages and inlined into the POS builds. Safe to load twice. */
(function () {
  'use strict';
  if (window.__coconutA11y) return;
  window.__coconutA11y = 1;
  var D = document;
  var EN = function () { return /^en/i.test(D.documentElement.lang || ''); };
  var FOC = 'a[href],area[href],button:not([disabled]),input:not([disabled]):not([type=hidden]),select:not([disabled]),textarea:not([disabled]),iframe,audio[controls],video[controls],[contenteditable=""],[contenteditable=true],[tabindex]:not([tabindex="-1"])';
  function vis(e) {
    if (!e || !e.isConnected) return false;
    if (!(e.offsetWidth || e.offsetHeight || e.getClientRects().length)) return false;
    var s = getComputedStyle(e);
    return s.visibility !== 'hidden' && s.display !== 'none';
  }
  function focusables(root) { return [].filter.call(root.querySelectorAll(FOC), vis); }
  function txt(e) { return ((e && (e.getAttribute('aria-label') || e.textContent)) || '').replace(/\s+/g, ' ').trim(); }

  /* ---------- styles ---------- */
  var css = [
    '.a11y-skip{position:fixed;left:8px;top:-80px;z-index:2147483000;background:#111;color:#fff;padding:12px 18px;border-radius:10px;font:600 16px/1.2 system-ui,sans-serif;text-decoration:none;box-shadow:0 0 0 3px #fff}',
    '.a11y-skip:focus{top:8px;outline:3px solid #fff;outline-offset:2px}',
    '.a11y-sr{position:absolute!important;width:1px!important;height:1px!important;padding:0!important;margin:-1px!important;overflow:hidden!important;clip:rect(0 0 0 0)!important;white-space:nowrap!important;border:0!important}',
    /* 2.4.7 / 2.4.13: a two-colour ring that shows on light and dark backgrounds */
    ':focus-visible{outline:3px solid #111!important;outline-offset:2px!important;box-shadow:0 0 0 6px #fff!important}',
    'input:focus-visible,select:focus-visible,textarea:focus-visible{outline-offset:0!important}',
    /* search bars draw one ring around the whole bar; the input inside must not add a second one */
    '.gsearch input:focus,.gsearch input:focus-visible,.search input:focus,.search input:focus-visible{outline:none!important;box-shadow:none!important}',
    '.gsearch:focus-within{box-shadow:0 0 0 3px var(--accent)!important}',
    '.search:focus-within{outline:3px solid var(--accent)!important;outline-offset:2px!important}',
    '[data-theme=dark] :focus-visible,.a11y-dark :focus-visible{outline-color:#fff!important;box-shadow:0 0 0 6px #111!important}',
    /* 2.5.5: 44 x 44 px targets (inline text links are exempt) */
    'button,[role=button],select,input[type=button],input[type=submit],input[type=reset],a.btn,.btn,.chip,label.chip{min-height:44px!important}',
    'button,[role=button],input[type=button],input[type=submit]{min-width:44px!important}',
    /* links that are not inline text (nav, menus, lists): min-height has no effect on inline links in a sentence */
    'a[href]{min-height:44px}',
    'a[href]:not(.btn){box-sizing:border-box}',
    'header a[href]:not(.btn):not(.logo),nav a[href]:not(.btn):not(.logo){display:inline-flex;align-items:center}',
    'input[type=checkbox],input[type=radio]{min-width:24px;min-height:24px}',
    'input:not([type=checkbox]):not([type=radio]):not([type=range]):not([type=color]):not([type=file]),textarea{min-height:44px}',
    /* customer display: pause control for ads (2.2.2) */
    '.adpause{position:absolute;top:12px;right:12px;z-index:30;width:52px;height:52px;border-radius:50%;border:2px solid #fff;background:rgba(0,0,0,.72);color:#fff;display:grid;place-items:center;cursor:pointer;padding:0}',
    '.adpause:hover{background:#000}',
    /* error box shown inside a dialog (3.3.1) */
    '.a11y-err{margin:0 0 12px;padding:10px 12px;border-radius:8px;border:2px solid #8A1C14;background:#FDECEA;color:#5C0F0A;font-weight:600}',
    '.a11y-err::before{content:"\\26A0\\FE0F  "}',
    /* 2.3.3: no motion when the device asks for less */
    '@media (prefers-reduced-motion:reduce){*,*::before,*::after{animation-duration:.01ms!important;animation-iteration-count:1!important;transition-duration:.01ms!important;scroll-behavior:auto!important}}'
  ].join('\n');
  function addCss() {
    if (D.getElementById('a11y-css')) return;
    var st = D.createElement('style');
    st.id = 'a11y-css';
    st.textContent = css;
    (D.head || D.documentElement).appendChild(st);
  }

  /* ---------- skip link, main landmark, H1 (2.4.1, 1.3.1, 2.4.10) ---------- */
  function mainEl() {
    return D.querySelector('main,[role=main]') || D.querySelector('#app,#view,.main,.wrap,body > div');
  }
  function skip() {
    var own = [].find.call(D.querySelectorAll('a[href^="#"]'), function (x) { return x.id !== 'a11y-skip' && /skip|ข้าม/i.test((x.className || '') + ' ' + x.textContent); });
    if (own) { var old = D.getElementById('a11y-skip'); if (old) old.remove(); return; }
    var a = D.getElementById('a11y-skip');
    if (!a) {
      a = D.createElement('a');
      a.id = 'a11y-skip';
      a.className = 'a11y-skip';
      a.href = '#';
      a.addEventListener('click', function (e) {
        e.preventDefault();
        var m = mainEl();
        if (!m) return;
        var h1 = m.querySelector('h1');
        var t = (h1 && vis(h1)) ? h1 : m;
        if (!t.hasAttribute('tabindex')) t.setAttribute('tabindex', '-1');
        t.focus();
        if (t.scrollIntoView) t.scrollIntoView({ block: 'start' });
      });
      D.body.insertBefore(a, D.body.firstChild);
    }
    var label = EN() ? 'Skip to main content' : 'ข้ามไปเนื้อหาหลัก';
    if (a.textContent !== label) a.textContent = label;
  }
  function landmarks() {
    if (!D.querySelector('main,[role=main]')) {
      var m = mainEl();
      if (m && m !== D.body) m.setAttribute('role', 'main');
    }
    var h1s = [].filter.call(D.querySelectorAll('h1'), function (h) { return h.isConnected && !h.closest('[hidden],[aria-hidden=true]'); });
    var auto = D.getElementById('a11y-h1');
    if (!h1s.filter(function (h) { return h !== auto; }).length) {
      var m2 = D.querySelector('main,[role=main]');
      if (m2) {
        if (!auto) {
          auto = D.createElement('h1');
          auto.id = 'a11y-h1';
          auto.className = 'a11y-sr';
        }
        if (auto.parentNode !== m2) m2.insertBefore(auto, m2.firstChild);
        var t = (D.title || '').trim();
        if (auto.textContent !== t) auto.textContent = t;
      }
    } else if (auto && h1s.length > 1) {
      auto.remove();
    }
  }

  /* ---------- page title follows the screen (2.4.2) ---------- */
  var baseTitle = null;
  function titles() {
    if (baseTitle === null) baseTitle = (D.title || '').replace(/^.* · (?=Coconut POS)/, '');
    [].forEach.call(D.querySelectorAll('.rail button'), function (b) {
      if (b.classList.contains('on')) b.setAttribute('aria-current', 'page'); else if (b.getAttribute('aria-current') === 'page') b.removeAttribute('aria-current');
    });
    var cur = [].find.call(D.querySelectorAll('[aria-current=page]'), vis);
    var view = cur ? txt(cur).replace(/\s*\d+$/, '') : '';
    var want = view && baseTitle.indexOf(view) < 0 ? view + ' · ' + baseTitle : baseTitle;
    if (want && D.title !== want) D.title = want;
  }

  /* ---------- live regions (4.1.3, 3.3.1) ---------- */
  function live() {
    ['toast', 'msg', 'err', 'notice'].forEach(function (id) {
      var t = D.getElementById(id);
      if (!t) return;
      if (!t.getAttribute('role')) t.setAttribute('role', 'status');
      if (!t.getAttribute('aria-live')) t.setAttribute('aria-live', 'polite');
    });
  }

  /* ---------- decorative SVG icons (1.1.1) ---------- */
  function icons() {
    [].forEach.call(D.querySelectorAll('svg:not([aria-hidden]):not([role]):not([aria-label]):not([aria-labelledby])'), function (s) {
      if (s.querySelector('title')) return;
      s.setAttribute('aria-hidden', 'true');
      s.setAttribute('focusable', 'false');
    });
  }

  /* ---------- dialogs (2.4.3, 2.1.2, 4.1.2) ---------- */
  var stack = []; // {el, host, name, opener, idx}
  function hostOf(d) {
    for (var e = d.parentElement; e && e !== D.body; e = e.parentElement) if (e.id) return e;
    return d;
  }
  function nameOf(d) {
    var id = d.getAttribute('aria-labelledby');
    var n = id && D.getElementById(id);
    return (n ? txt(n) : d.getAttribute('aria-label')) || '';
  }
  function openDialogs() {
    return [].filter.call(D.querySelectorAll('[role=dialog],[role=alertdialog],dialog[open]'), vis);
  }
  function firstField(d) {
    var f = focusables(d);
    var inp = f.find(function (e) { return /^(INPUT|SELECT|TEXTAREA)$/.test(e.tagName) && !e.readOnly; });
    return inp || f.find(function (e) { return !isClose(e); }) || f[0];
  }
  function isClose(e) {
    if (!e || e.tagName !== 'BUTTON') return false;
    var a = (e.getAttribute('data-act') || '') + ' ' + (e.id || '') + ' ' + (e.className || '');
    if (/(^|\s)(close|closeModal|dclose|mclose|x)(\s|$)|close/i.test(a)) return true;
    var l = txt(e);
    return /^(ปิด|close|×|✕|✖)$/i.test(l);
  }
  function closeBtn(d) {
    var f = [].filter.call(d.querySelectorAll('button'), vis);
    return f.find(isClose);
  }
  function syncDialogs() {
    var open = openDialogs();
    // drop dialogs that closed
    for (var i = stack.length - 1; i >= 0; i--) {
      var s = stack[i];
      if (open.indexOf(s.el) >= 0) continue;
      // replaced by a re-render in the same host with the same name: keep going with the new element
      var again = open.find(function (o) { return hostOf(o) === s.host && nameOf(o) === s.name && !stack.some(function (x) { return x.el === o; }); });
      if (again) {
        s.el = again;
        prep(again);
        if (!again.contains(D.activeElement)) {
          var f = focusables(again);
          var t = f[Math.min(s.idx, f.length - 1)] || firstField(again);
          if (t) t.focus({ preventScroll: true });
        }
        continue;
      }
      stack.splice(i, 1);
      var a = D.activeElement;
      if (!stack.length && (!a || a === D.body || !a.isConnected)) {
        if (s.opener && vis(s.opener)) s.opener.focus({ preventScroll: true });
      }
    }
    // add new ones
    open.forEach(function (d) {
      if (stack.some(function (x) { return x.el === d; })) return;
      var a = D.activeElement;
      var opener = (a && a !== D.body && !d.contains(a)) ? a : (stack.length ? null : lastFocus);
      stack.push({ el: d, host: hostOf(d), name: nameOf(d), opener: opener, idx: 0 });
      prep(d);
      if (!d.contains(D.activeElement)) {
        var t = firstField(d);
        if (t) t.focus({ preventScroll: true }); else { d.setAttribute('tabindex', '-1'); d.focus({ preventScroll: true }); }
      }
    });
  }
  function prep(d) {
    if (d.tagName !== 'DIALOG' && !d.hasAttribute('aria-modal')) d.setAttribute('aria-modal', 'true');
    if (!d.getAttribute('aria-labelledby')) {
      var h = d.querySelector('h1,h2,h3');
      if (h) {
        if (!h.id) h.id = 'a11y-dlg-' + Math.random().toString(36).slice(2, 8);
        d.setAttribute('aria-labelledby', h.id);
      }
    }
  }
  var lastFocus = null;
  D.addEventListener('focusin', function (e) {
    var top = stack[stack.length - 1];
    if (top && top.el.contains(e.target)) top.idx = Math.max(0, focusables(top.el).indexOf(e.target));
    else if (!top) lastFocus = e.target;
  }, true);
  D.addEventListener('keydown', function (e) {
    var top = stack[stack.length - 1];
    if (!top || !vis(top.el)) return;
    var d = top.el;
    if (e.key === 'Tab') {
      var f = focusables(d);
      if (!f.length) { e.preventDefault(); d.focus(); return; }
      var a = D.activeElement, i = f.indexOf(a);
      if (e.shiftKey && (i <= 0)) { e.preventDefault(); f[f.length - 1].focus(); }
      else if (!e.shiftKey && (i === -1 || i === f.length - 1)) { e.preventDefault(); f[0].focus(); }
    } else if (e.key === 'Escape' && !e.defaultPrevented && d.getAttribute('data-a11y-esc') !== 'own') {
      var b = closeBtn(d);
      if (b) { e.preventDefault(); b.click(); }
    }
  }, true);
  // keep focus from wandering behind an open dialog (clicks on the backdrop, script focus)
  D.addEventListener('focusin', function (e) {
    var top = stack[stack.length - 1];
    if (!top || !vis(top.el) || top.el.contains(e.target)) return;
    if (e.target.closest && e.target.closest('[role=dialog],[role=alertdialog],dialog,#toast,.a11y-skip')) return;
    var t = firstField(top.el);
    if (t) t.focus({ preventScroll: true });
  });

  /* ---------- run ---------- */
  var queued = false;
  function tick() {
    queued = false;
    try { addCss(); skip(); live(); icons(); titles(); landmarks(); syncDialogs(); } catch (err) { /* never break the page */ }
  }
  function queue() { if (!queued) { queued = true; (window.requestAnimationFrame || setTimeout)(tick); } }
  function start() {
    tick();
    new MutationObserver(queue).observe(D.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['hidden', 'class', 'open', 'style', 'aria-current', 'lang'] });
    new MutationObserver(queue).observe(D.documentElement, { attributes: true, attributeFilter: ['lang'] });
  }
  addCss();
  if (D.body) start(); else D.addEventListener('DOMContentLoaded', start);
  window.A11Y = { refresh: tick };
})();
