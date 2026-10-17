#!/usr/bin/env python3
"""Build Easy POS Retail (retail/index.html) from the Claude-artifact source.

Usage: python3 tools/build_retail.py
Reads  src/retail-pos.artifact.html   (the retail POS, also runs as a Claude artifact)
       tools/retail-shim.html         (login, per-shop data store, staff accounts, billing)
       tools/standalone-shim.html     (billing + data-store code shared with Easy POS Cafe)
Writes retail/index.html
"""
import os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
rd = lambda *p: open(os.path.join(ROOT, *p), encoding='utf-8').read()
src = rd('src', 'retail-pos.artifact.html')
shim = rd('tools', 'retail-shim.html')
cafe = rd('tools', 'standalone-shim.html')


def part(a, b):
    if a not in cafe or b not in cafe:
        sys.exit('build_retail: shared shim marker not found: ' + a)
    return cafe[cafe.index(a):cafe.index(b)]


shim = shim.replace('/*@@BILLING@@*/', part('/* ---------- billing (shop side) ---------- */', '/* ---------- data store'))
shim = shim.replace('/*@@STORE@@*/', part('/* ---------- data store', 'window.POS_PRINT='))
# The shared billing panel uses the cafe button classes; keep them styled here.
shim = shim.replace('class="btn primary big"', 'class="btn primary big sbtn pri"')


def R(a, b):
    global src
    if a not in src:
        sys.exit('build_retail: patch point not found: ' + a[:80])
    src = src.replace(a, b, 1)


R('<title>POS ร้านคุณสิมบัติ</title>', '<title>Easy POS Retail</title>')
# Runtime shim loads before the app's own scripts, so window.claude exists when the app starts.
first = src.index('<script')
src = src[:first] + shim + '\n' + src[first:]
# Let the shim show messages with the app's toast.
# Retail shops: the admin sets how many shops/warehouses this account may have.
R(" branchForm(el){const b=el&&el.dataset&&el.dataset.id?get('branches',el.dataset.id):null;",
  " branchForm(el){const b=el&&el.dataset&&el.dataset.id?get('branches',el.dataset.id):null;"
  "if(!b&&window.POS_BRANCH_LIMIT){const lim=window.POS_BRANCH_LIMIT();if(lim!=null&&all('branches').length>=lim)return toast('แพ็กเกจนี้มีร้าน/สาขา/คลังได้ '+lim+' แห่ง · ติดต่อผู้ดูแลระบบเพื่อเพิ่มจำนวน','bad')}")
R("(สลับร้านได้ที่แถบบน)</p>",
  "(สลับร้านได้ที่แถบบน)${window.POS_BRANCH_LIMIT&&window.POS_BRANCH_LIMIT()!=null?` · ร้าน/สาขา/คลัง ${all('branches').length} / ${window.POS_BRANCH_LIMIT()} (ผู้ดูแลระบบกำหนด)`:''}</p>")
R('function toast(msg,kind){', 'window.POS_TOAST=(m)=>toast(m);function toast(msg,kind){')
# Free mode: up to N products and N bills per month (admin sets the numbers; the database enforces them too).
R("function chain(p,fn){const n=(chains.get(p)||Promise.resolve()).then(fn).catch(e=>{toast(e&&e.code==='quota_exceeded'?",
  "function freeLim(){return window.POS_FREE_LIM?window.POS_FREE_LIM():null}"
  "function freeBillsFull(){const L=freeLim();if(!L)return false;const d=new Date();const m0=new Date(d.getFullYear(),d.getMonth(),1).getTime();return all('sales').filter(x=>x.ts>=m0).length>=L.bills}"
  "function freeItemsLeft(){const L=freeLim();return L?L.items-all('products').length:Infinity}"
  "function chain(p,fn){const n=(chains.get(p)||Promise.resolve()).then(fn).catch(e=>{toast(e&&e.code==='free_limit'?e.message:e&&e.code==='quota_exceeded'?")
R("function payModal(){const c=calc(ST.cart);if(!c.lines.length)return;",
  "function payModal(){const c=calc(ST.cart);if(!c.lines.length)return;if(freeBillsFull())return toast(window.POS_FREE_MSG('bills'),'bad');")
R("  put('products',Object.assign({},p,{id:p.id||uid(),name:v.name.trim(),",
  "  if(!p.id&&freeItemsLeft()<=0)return toast(window.POS_FREE_MSG('items'),'bad');\n  put('products',Object.assign({},p,{id:p.id||uid(),name:v.name.trim(),")
R("const ex=all('products').find(p=>c[0]&&p.barcode===c[0]);const st=Object.assign({},ex?ex.stock:{});",
  "const ex=all('products').find(p=>c[0]&&p.barcode===c[0]);if(!ex&&freeItemsLeft()<=0){ST.freeSkip=(ST.freeSkip||0)+1;return}const st=Object.assign({},ex?ex.stock:{});")
R("  toast(`นำเข้าใหม่ ${n} · อัปเดต ${u} รายการ`);$('#impText').value=''},",
  "  toast(`นำเข้าใหม่ ${n} · อัปเดต ${u} รายการ`+(ST.freeSkip?` · ข้าม ${ST.freeSkip} รายการ (ใช้งานฟรีจำกัดสินค้า ${freeLim().items} รายการ)`:''),ST.freeSkip?'bad':undefined);ST.freeSkip=0;$('#impText').value=''},")

page = ('<!doctype html>\n<html lang="th">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
        '<meta name="theme-color" content="#1f7fc0">\n<link rel="icon" href="/easypos.svg" type="image/svg+xml">\n'
        '<meta name="robots" content="noindex">\n<meta name="description" content="Easy POS Retail ระบบขายหน้าร้านสำหรับร้านค้า ร้านของชำ">\n'
        '<style>[hidden]{display:none!important}html,body{height:100%;margin:0}img{max-width:100%}</style>\n</head>\n<body>\n'
        + src + '\n</body>\n</html>\n')
os.makedirs(os.path.join(ROOT, 'retail'), exist_ok=True)
open(os.path.join(ROOT, 'retail', 'index.html'), 'w', encoding='utf-8').write(page)
print('built retail/index.html', len(page), 'bytes')

# Public demo: the same app on its own, data stays in this browser (no login, nothing shared).
demo = rd('src', 'retail-pos.artifact.html').replace('<title>POS ร้านคุณสิมบัติ</title>', '<title>เดโม Easy POS Retail · ทดลองใช้ได้ทันที</title>', 1)
demo = demo.replace('ร้านคุณสิมบัติ', 'ร้านตัวอย่าง').replace('คุณสิมบัติ', 'เจ้าของร้าน')
BAR = ('<div style="position:fixed;left:50%;bottom:10px;transform:translateX(-50%);z-index:300;display:flex;gap:10px;align-items:center;'
       'padding:6px 8px 6px 14px;border-radius:999px;background:#13202c;color:#fff;font:600 13px/1.2 system-ui,sans-serif;box-shadow:0 8px 24px rgba(0,0,0,.25);max-width:calc(100vw - 24px)">'
       '<span>เดโม · ข้อมูลเก็บในเบราว์เซอร์นี้เท่านั้น</span><a href="/retail/signup" style="background:#2a9df4;color:#fff;text-decoration:none;padding:6px 12px;border-radius:999px;white-space:nowrap">สมัครใช้งานจริง</a></div>')
# The demo opens straight on the sales screen: sample data on first visit, signed in as the owner.
AUTO = ("<script>(function(){var n=0;function go(){if(typeof A==='undefined'||typeof ST==='undefined'||!ST.ready){if(n++<100)setTimeout(go,50);return}"
        "if(!all('staff').length)A.loadSample();var o=all('staff').find(function(s){return s.role==='owner'})||all('staff')[0];"
        "if(o&&!me()){ST.user=o.id;loc.set('simbat-user',o.id)}ST.route='pos';render()}go()})();</script>")
demo = ('<!doctype html>\n<html lang="th">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
        '<link rel="icon" href="/easypos.svg" type="image/svg+xml">\n'
        '<meta name="description" content="ลองใช้ Easy POS Retail ได้ทันที ไม่ต้องสมัคร">\n'
        '<style>[hidden]{display:none!important}html,body{height:100%;margin:0}img{max-width:100%}</style>\n</head>\n<body>\n'
        + demo + '\n' + BAR + '\n' + AUTO + '\n</body>\n</html>\n')
os.makedirs(os.path.join(ROOT, 'retail', 'demo'), exist_ok=True)
open(os.path.join(ROOT, 'retail', 'demo', 'index.html'), 'w', encoding='utf-8').write(demo)
print('built retail/demo/index.html', len(demo), 'bytes')
