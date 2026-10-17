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
R('function toast(msg,kind){', 'window.POS_TOAST=(m)=>toast(m);function toast(msg,kind){')

page = ('<!doctype html>\n<html lang="th">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
        '<meta name="theme-color" content="#1f7fc0">\n<link rel="icon" href="/easypos.svg" type="image/svg+xml">\n'
        '<meta name="robots" content="noindex">\n<meta name="description" content="Easy POS Retail ระบบขายหน้าร้านสำหรับร้านค้า ร้านของชำ">\n'
        '<style>[hidden]{display:none!important}html,body{height:100%;margin:0}img{max-width:100%}</style>\n</head>\n<body>\n'
        + src + '\n</body>\n</html>\n')
os.makedirs(os.path.join(ROOT, 'retail'), exist_ok=True)
open(os.path.join(ROOT, 'retail', 'index.html'), 'w', encoding='utf-8').write(page)
print('built retail/index.html', len(page), 'bytes')
