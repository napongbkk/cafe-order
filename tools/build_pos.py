#!/usr/bin/env python3
"""Build the standalone POS (pos/index.html) from the Claude-artifact source.

Usage: python3 tools/build_pos.py
Reads  src/cafe-pos.artifact.html and tools/standalone-shim.html
Writes pos/index.html
"""
import os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = open(os.path.join(ROOT, 'src', 'cafe-pos.artifact.html'), encoding='utf-8').read()
orig = src  # untouched copy for the public demo page
shim = open(os.path.join(ROOT, 'tools', 'standalone-shim.html'), encoding='utf-8').read()


def R(a, b):
    global src
    if a not in src:
        sys.exit('build_pos: patch point not found: ' + a[:80])
    src = src.replace(a, b, 1)


# The page runs as its own website, so it needs a full HTML document.
src = ('<!doctype html>\n<html lang="th">\n<head>\n<meta charset="utf-8">\n'
       '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
       '<meta name="theme-color" content="#F4F3F1">\n<link rel="icon" href="/icon.svg" type="image/svg+xml">\n'
       '<meta name="robots" content="noindex">\n<style>[hidden]{display:none!important}:root{color-scheme:light;padding:env(safe-area-inset-top,0px) 0 env(safe-area-inset-bottom,0px)}img{max-width:100%}.ugrp{display:flex;align-items:stretch;border:1px solid var(--line2);border-radius:10px;overflow:hidden;background:var(--surface)}.ugrp b{display:flex;align-items:center;padding:0 10px;background:var(--bg,#eef2f6);color:var(--ink);font-family:ui-monospace,Menlo,monospace;font-size:15px;letter-spacing:.5px;border-right:1px solid var(--line2);user-select:none}.form .ugrp input{border:0!important;border-radius:0!important;min-width:0}</style>\n</head>\n<body>\n' + src + '\n</body>\n</html>\n')
R('html,body{height:100%}', 'html,body{height:100%;margin:0}')
R('<title>POS คาเฟ่</title>', '<title>Coconut POS Cafe</title>')

# Runtime shim (login + Supabase store) loads before the app script.
R('<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>',
  shim + '\n<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>')

# Menu images come from Supabase Storage.
R("function imgUrl(id){return '/_blob/'+encodeURIComponent(id)}",
  "function imgUrl(id){return window.POS_IMG?window.POS_IMG(id):'/_blob/'+encodeURIComponent(id)}")

# Printing: on the web the page prints straight to the printer (hidden frame + print), no file to open.
# With Chrome/Edge started with --kiosk-printing the print dialog is skipped, so receipts come out by themselves.
PRINT_JS = ("<script>window.POS_PRINT=window.POS_PRINT||function(html){var f=document.createElement('iframe');f.setAttribute('aria-hidden','true');"
            "f.style.cssText='position:fixed;width:0;height:0;border:0;right:0;bottom:0';document.body.appendChild(f);f.srcdoc=html;"
            "setTimeout(function(){f.remove()},120000);return true};</script>")
# Windows shortcut: opens the POS in Chrome (or Edge) with --kiosk-printing, so print jobs go straight to the
# default printer with no dialog. Its own browser profile makes the flag work even while other Chrome windows are open.
KIOSK_JS = r"""<script>window.POS_KIOSK_HREF=function(){var u=location.origin+(location.pathname.indexOf('/demo')===0?'/demo':'/pos');
var L=['@echo off','rem Coconut POS: open the POS so receipts print straight to the default printer (no print dialog)',
'set "U='+u+'"','set "D=%LOCALAPPDATA%\\EasyPOS-Print"',
'set "C=%ProgramFiles%\\Google\\Chrome\\Application\\chrome.exe"',
'if not exist "%C%" set "C=%ProgramFiles(x86)%\\Google\\Chrome\\Application\\chrome.exe"',
'if not exist "%C%" set "C=%LOCALAPPDATA%\\Google\\Chrome\\Application\\chrome.exe"',
'if not exist "%C%" set "C=msedge"',
'start "" "%C%" --kiosk-printing --user-data-dir="%D%" --no-first-run --app="%U%"'];
return 'data:application/octet-stream;charset=utf-8,'+encodeURIComponent(L.join('\r\n')+'\r\n')};</script>"""
KIOSK = ("`<a class=\\\"btn\\\" style=\\\"align-self:flex-start;text-decoration:none\\\" download=\\\"CoconutPOS-AutoPrint.bat\\\" href=\\\"${window.POS_KIOSK_HREF?window.POS_KIOSK_HREF():'#'}\\\">${ic('print',18)}ดาวน์โหลดทางลัดพิมพ์อัตโนมัติ (Windows)</a>`")
WEB_PRINT = [
  ("  if(!S.downloads){toast('อุปกรณ์นี้บันทึกไฟล์สำหรับพิมพ์ไม่ได้');return false}",
   "  if(!S.downloads&&!window.POS_PRINT){toast('อุปกรณ์นี้พิมพ์ไม่ได้');return false}"),
  ("  try{await S.downloads.save({filename:name+'.html',data:html})",
   "  if(window.POS_PRINT){window.POS_PRINT(html);toast('กำลังพิมพ์ '+name);return true}\n  try{await S.downloads.save({filename:name+'.html',data:html})"),
  ("function saveQrSheet(){\n  if(!S.downloads){toast('อุปกรณ์นี้บันทึกไฟล์ไม่ได้');return}",
   "function saveQrSheet(){\n  if(!S.downloads&&!window.POS_PRINT){toast('อุปกรณ์นี้พิมพ์ไม่ได้');return}"),
  ("  S.downloads.save({filename:'QR-สั่งอาหาร.html',data:html})",
   "  if(window.POS_PRINT){window.POS_PRINT(html);return}\n  S.downloads.save({filename:'QR-สั่งอาหาร.html',data:html})"),
  ("(S.downloads?'':'<div class=\"note\">", "(S.downloads||window.POS_PRINT?'':'<div class=\"note\">"),
  ("ระบบจะบันทึกไฟล์ เปิดไฟล์แล้วหน้าต่างพิมพ์จะขึ้นเอง เลือกเครื่องพิมพ์ใบเสร็จของร้าน",
   "กดพิมพ์แล้วส่งเข้าเครื่องพิมพ์ค่าเริ่มต้นทันที ถ้าเปิดผ่านทางลัดพิมพ์อัตโนมัติ จะไม่มีหน้าต่างให้กดยืนยัน"),
  ("ผ่านไดรเวอร์ (บันทึกไฟล์แล้วสั่งพิมพ์) · ${PR.auto", "พิมพ์ตรงจากหน้าเว็บ · ${PR.auto"),
  ("ระบบจะบันทึกไฟล์แล้วเปิดเพื่อพิมพ์ ตั้งเครื่องพิมพ์ครัวเป็นค่าเริ่มต้นของเครื่องที่ใช้พิมพ์",
   "ระบบส่งพิมพ์ตรงจากหน้าเว็บ ตั้งเครื่องพิมพ์ครัวเป็นค่าเริ่มต้นของเครื่องที่ใช้พิมพ์ และเปิด POS จากทางลัดพิมพ์อัตโนมัติเพื่อไม่ต้องกดยืนยัน"),
  ("บันทึกไฟล์ QR ทุกโต๊ะสำหรับพิมพ์", "พิมพ์ QR ทุกโต๊ะ"),
  # Receipts print by themselves after payment unless the device turned it off after this change.
  ("try{const p=JSON.parse(localStorage.getItem('pos.print')||'null');if(p){",
   "try{const p=JSON.parse(localStorage.getItem('pos.print')||'null');if(p&&!p.webPrint){p.auto=true;p.webPrint=1}if(p){"),
  ("let PR={paper:'80',auto:false,", "let PR={paper:'80',auto:true,webPrint:1,"),
]
def web_print(t, label):
    for a, b in WEB_PRINT:
        if a not in t:
            sys.exit('build_pos: print patch point not found (' + label + '): ' + a[:80])
        t = t.replace(a, b, 1)
    return t
src = web_print(src, 'pos')
QRJS = '<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>'
src = src.replace(QRJS, KIOSK_JS + '\n' + QRJS, 1)

# Customer-app bridge talks to Supabase through RPCs (no connector needed).
R("async function bridgeTick(){",
  r"""async function bridgeTickSB(){
  let wait=10000;
  try{
    const lease=await S.db.doc('bridge/lock').acquire({holder:deviceId,ttlMs:30000});
    if(!lease.acquired){S.app.state='other';S.app.msg='มีเครื่องอื่นเป็นตัวรับออเดอร์จากแอปอยู่';renderAppStatus();scheduleBridge(20000);return}
    const snap=JSON.stringify(appSnapshot());const sendSnap=snap!==lastSnap&&(S.menu.length||S.shopLoaded);const o=sendSnap?JSON.parse(snap):null;
    const vals=appStatuses();
    const sid=window.POS_SESSION.shop.id;const r=await window.POS_SB.rpc('pos_shop_sync',{p_sid:sid,p_menu:o&&S.menu.length?o.menu:null,p_shopdata:o?o.shop:null,p_status:vals.length?vals:null});
    if(r.error)throw {code:'tool_error',message:r.error.message};
    if(sendSnap)lastSnap=snap;vals.forEach(([a,st,pd])=>{pushed[a]=st+'|'+pd});
    const rows=Array.isArray(r.data)?r.data:[];const acc=[];
    for(const ao of rows){const res=await importAppOrder(ao);if(res)acc.push([ao.id,res])}
    if(acc.length){
      const a2=await window.POS_SB.rpc('pos_shop_accept',{p_sid:sid,p_list:acc.map(([a,res])=>({id:a,pos_id:res.id,pos_no:res.no}))});
      if(a2.error)throw {code:'tool_error',message:a2.error.message};
      acc.forEach(([a])=>{pushed[a]='accepted|false'});S.app.count+=acc.length;
      toast('Mobile Order ใหม่ (รอชำระ): '+acc.map(([,res])=>res.where).join(', '));
      if(rows.length===20)wait=1500;
    }
    S.app.state='ok';S.app.msg='';S.app.last=Date.now();
  }catch(e){S.app.state='err';S.app.msg=e&&e.code==='tool_error'?'ซิงก์ไม่สำเร็จ: '+String(e.message||'').slice(0,120):'เชื่อมต่อฐานข้อมูลไม่สำเร็จ จะลองใหม่อัตโนมัติ';wait=15000}
  renderAppStatus();renderTop();scheduleBridge(wait);
}
async function bridgeTick(){
  if(window.POS_STANDALONE){bridgeT=null;if(!PR.bridge||!S.db||S.mode!=='live')return;return bridgeTickSB()}""")
R("บัญชีบนเครื่องนั้นต้องเชื่อม Supabase ไว้ ", "${window.POS_STANDALONE?'':'บัญชีบนเครื่องนั้นต้องเชื่อม Supabase ไว้ '}")

# No demo fallback while waiting for login.
R("setTimeout(()=>{if(S.mode==='loading')startDemo()},11000);",
  "if(!window.POS_STANDALONE)setTimeout(()=>{if(S.mode==='loading')startDemo()},11000);")

# Signed-in account + sign out in the top bar.
R('      <span id="appPill"></span>', '      <span id="acct"></span>\n      <span id="appPill"></span>')
R("  $('#appPill').innerHTML=",
  "  if(window.POS_STANDALONE&&window.POS_ACCOUNT){const a=window.POS_ACCOUNT();const bs=window.POS_BILLSTATE?window.POS_BILLSTATE():null;$('#acct').innerHTML=a.email?`${a.admin?`<span class=\"adminbar\">ผู้ดูแลระบบ · ${esc(a.shop?a.shop.name:'')} <a href=\"/admin\">กลับแดชบอร์ด</a></span>`:''}${bs&&bs.cls&&a.role==='manager'?`<button class=\"billpill ${bs.cls==='bad'?'bad':''}\" data-act=\"billgo\">${esc(bs.t)}</button>`:''}<span>${esc(a.login||a.email)} · ${a.admin?'ผู้ดูแลระบบ':({manager:'ผู้จัดการร้าน',staff:'พนักงาน'})[a.role]||''}</span>${window.EP_LANG_BTN?window.EP_LANG_BTN():''}<button class=\"btn sm\" data-act=\"logout\">ออกจากระบบ</button>`:''}\n  $('#appPill').innerHTML=")
R("    case 'apptoggle':", "    case 'logout':if(window.POS_SB)window.POS_SB.auth.signOut().then(()=>location.reload());break;\n    case 'apptoggle':")

# Staff management (shop manager) and monthly billing in Settings.
R("const tabs=[['ui','ปรับแต่งรูปแบบระบบ'],['devices','อุปกรณ์และการรับเงิน'],",
  "const tabs=[['ui','ปรับแต่งรูปแบบระบบ'],['devices','อุปกรณ์และการรับเงิน'],...(window.POS_STANDALONE&&window.POS_ACCOUNT&&window.POS_ACCOUNT().role==='manager'?[['billing','ค่าบริการรายเดือน'],['staff','พนักงาน']]:[]),")
R("  else if(tab==='app'){",
  r"""  else if(tab==='billing'){body=`<h2>ค่าบริการรายเดือน</h2><div id="billingBox"><div class="muted">กำลังโหลด…</div></div>`;setTimeout(()=>{if(window.POS_BILLING)window.POS_BILLING.render($('#billingBox'))},0)}
  else if(tab==='staff'){const sh=(window.POS_SESSION||{}).shop||{};
    body=`<h2>พนักงาน</h2><span class="hint">สร้างบัญชีพนักงานด้วยชื่อผู้ใช้และรหัสผ่าน ไม่ต้องใช้อีเมล · พนักงานเข้าสู่ระบบด้วยชื่อผู้ใช้ที่ตั้งให้ · พนักงานใช้หน้าขาย Mobile Order โต๊ะ จอครัว ประวัติใบเสร็จ และรอบการขายได้ แต่เข้าเมนูและโปรโมชั่น ตั้งค่า และรายงานไม่ได้</span>
    <div class="note" id="staffQuota">บัญชีพนักงาน ${sh.staffUsed||0} / ${sh.staffLimit||0}</div>
    ${sh.trial||!(sh.staffLimit>0)?`<div class="note" style="background:var(--warn-soft,#FFF6D9);border:1px solid #F2B200">${sh.trial?'แพ็กเกจทดลองใช้ฟรีเพิ่มบัญชีพนักงานไม่ได้':'แพ็กเกจของร้านยังไม่มีโควตาบัญชีพนักงาน'} · ผู้จัดการใช้งานได้ทุกฟังก์ชันตามปกติ ${sh.trial?'เมื่อชำระค่าบริการและผู้ดูแลระบบยืนยันแล้ว จะเพิ่มพนักงานได้ทันที':'ติดต่อผู้ดูแลระบบเพื่อเพิ่มโควตา'}${sh.trial?' <button class="btn sm" type="button" data-act="billgo" style="margin-left:6px">ชำระค่าบริการ</button>':''}</div>`:''}
    <form class="form" id="staffForm" autocomplete="off"${sh.trial||!(sh.staffLimit>0)?' hidden':''}><div class="three"><label for="st_user">ชื่อผู้ใช้<span class="ugrp"><b title="รหัสร้าน แก้ไขไม่ได้">${esc(upfx())}</b><input id="st_user" required maxlength="27" autocapitalize="none" spellcheck="false" placeholder="เช่น user1"></span></label><label for="st_name">ชื่อพนักงาน<input id="st_name" maxlength="40"></label><label for="st_pw">รหัสผ่าน (อย่างน้อย 6 ตัว)<input id="st_pw" type="text" required minlength="6" autocomplete="new-password"></label></div>
      <span class="hint">ทุกชื่อผู้ใช้ขึ้นต้นด้วยรหัสร้าน <b>${esc(upfx())}</b> (แก้ไขไม่ได้) ต่อด้วย a-z 0-9 . _ - · พนักงานเข้าสู่ระบบด้วย เช่น <b>${esc(upfx())}user1</b> (ตัวพิมพ์เล็กหรือใหญ่ก็ได้)</span><button class="btn primary" type="submit" style="align-self:flex-start">เพิ่มพนักงาน</button></form>
    <div id="staffList"><div class="muted">กำลังโหลด…</div></div>
    <h2 style="margin-top:18px">รหัสผ่านของฉัน</h2><form class="form" id="myPwForm" autocomplete="off"><div class="two"><label for="my_pw">รหัสผ่านใหม่<input id="my_pw" type="password" minlength="8" required autocomplete="new-password"></label><label for="my_pw2">ยืนยันรหัสผ่านใหม่<input id="my_pw2" type="password" minlength="8" required autocomplete="new-password"></label></div>
      <span class="hint">อีเมลเข้าสู่ระบบ ${esc((window.POS_ACCOUNT&&window.POS_ACCOUNT().email)||'')} เปลี่ยนไม่ได้</span><button class="btn" type="submit" style="align-self:flex-start">เปลี่ยนรหัสผ่าน</button></form>`;setTimeout(loadStaff,0)}
  else if(tab==='app'){""")
R("/* ===== render ===== */",
  r"""function upfx(){const s=window.POS_SESSION&&window.POS_SESSION.shop;return (s&&s.userPrefix)||'???'}
const uname=u=>u?String(u).slice(0,3).toUpperCase()+String(u).slice(3):'';
async function loadStaff(){const el=$('#staffList');if(!el||!window.POS_SB)return;const sid=window.POS_SESSION.shop.id;
  const r=await window.POS_SB.from('pos_members').select('*').eq('shop_id',sid).order('created_at');if(r.error){el.innerHTML='<div class="note">โหลดรายชื่อไม่สำเร็จ</div>';return}
  const n=r.data.filter(x=>x.role==='staff'&&x.active).length;const q=$('#staffQuota');const lim=window.POS_SESSION.shop.staffLimit||0;window.POS_SESSION.shop.staffUsed=n;
  if(q)q.textContent=window.POS_SESSION.shop.trial?'บัญชีพนักงาน 0 / 0 · ทดลองใช้ฟรี':'บัญชีพนักงาน '+n+' / '+lim+(lim<=0?'':n>=lim?' · ครบจำนวนแล้ว ติดต่อผู้ดูแลระบบเพื่อเพิ่ม':' · เพิ่มได้อีก '+(lim-n)+' บัญชี');
  el.innerHTML=r.data.length?r.data.map(x=>{const login=x.username?uname(x.username):x.email;const pw=S.staffPw===x.email;return `<div class="mrow" style="flex-wrap:wrap"><div class="info"><b>${esc(x.name||login)}</b><small>${x.username?'ชื่อผู้ใช้: ':''}${esc(login)} · ${x.role==='manager'?'ผู้จัดการร้าน':'พนักงาน'}${x.active?'':' · ปิดใช้งาน'}</small></div>${x.role==='staff'?(pw?`<form class="stpw" data-email="${esc(x.email)}" style="display:flex;gap:6px;align-items:center"><input type="text" minlength="6" required placeholder="รหัสผ่านใหม่" aria-label="รหัสผ่านใหม่ของ ${esc(login)}" style="min-height:40px;max-width:180px"><button class="btn sm primary" type="submit">บันทึก</button><button class="btn sm" type="button" data-act="staffpwx">ยกเลิก</button></form>`:`<button class="btn sm" data-act="staffpw" data-id="${esc(x.email)}">เปลี่ยนรหัสผ่าน</button><button class="btn sm" data-act="staffactive" data-id="${esc(x.email)}" data-v="${x.active?'0':'1'}">${x.active?'ปิดใช้งาน':'เปิดใช้งาน'}</button>${S.confirm==='sfdel:'+x.email?`<button class="btn sm danger" data-act="staffdel" data-id="${esc(x.email)}">ยืนยันลบ</button><button class="btn sm" data-act="staffundel">ไม่ลบ</button>`:`<button class="btn sm" data-act="staffask" data-id="${esc(x.email)}">ลบ</button>`}`):''}</div>`}).join(''):'<div class="muted">ยังไม่มี</div>';
  const pf=el.querySelector('.stpw input');if(pf)pf.focus()}
async function staffFn(body){const s=await window.POS_SB.auth.getSession();const tok=s.data.session&&s.data.session.access_token;
  const r=await fetch('https://roggqmvmgfxsxynulpvk.supabase.co/functions/v1/pos-signup',{method:'POST',headers:{'apikey':window.POS_SB_KEY,'Authorization':'Bearer '+tok,'Content-Type':'application/json'},body:JSON.stringify(body)});return r.json().catch(()=>({error:'server_error'}))}
const STAFF_ERR={bad_username:'ชื่อผู้ใช้ (ต่อจากรหัสร้าน) ใช้ได้ a-z 0-9 . _ - ยาวไม่เกิน 27 ตัว',weak_password:'รหัสผ่านต้องมีอย่างน้อย 6 ตัวอักษร',username_taken:'ชื่อผู้ใช้นี้มีในร้านแล้ว ลองชื่ออื่น',staff_limit:'เกินจำนวนบัญชีพนักงานที่ร้านใช้ได้ ติดต่อผู้ดูแลระบบเพื่อเพิ่ม',locked:'ร้านถูกล็อก ชำระค่าบริการก่อน',forbidden:'เฉพาะผู้จัดการร้าน'};
function staffErr(e){const m=String(e&&e.message||'');return /staff_limit/.test(m)?'เกินจำนวนบัญชีพนักงานที่ร้านใช้ได้ ติดต่อผู้ดูแลระบบเพื่อเพิ่ม':/duplicate|pos_members_pkey/.test(m)?'อีเมลนี้ใช้กับร้านอื่นอยู่แล้ว':/bad_email/.test(m)?'อีเมลไม่ถูกต้อง':'บันทึกไม่สำเร็จ: '+m}

/* ===== render ===== */""")
R("    case 'logout':",
  r"""    case 'staffactive':window.POS_SB.from('pos_members').update({active:d.v==='1'}).eq('shop_id',window.POS_SESSION.shop.id).eq('email',d.id).then(r=>{if(r.error)toast(staffErr(r.error));loadStaff()});break;
    case 'staffask':S.confirm='sfdel:'+d.id;loadStaff();break;
    case 'staffundel':S.confirm=null;loadStaff();break;
    case 'staffdel':S.confirm=null;staffFn({action:'staff_del',email:d.id}).then(r=>{toast(r.error?(STAFF_ERR[r.error]||'ลบไม่สำเร็จ'):'ลบบัญชีแล้ว');loadStaff()});break;
    case 'staffpw':S.staffPw=d.id;loadStaff();break;
    case 'staffpwx':S.staffPw=null;loadStaff();break;
    case 'billgo':S.stab='billing';go('settings');break;
    case 'logout':""")
R("  if(id==='catForm'){",
  r"""  if(id==='staffForm'){const u=$('#st_user').value.trim().toLowerCase(),pw=$('#st_pw').value;
    if(!/^[a-z0-9._-]{1,27}$/.test(u)){toast(STAFF_ERR.bad_username);return}if(pw.length<6){toast(STAFF_ERR.weak_password);return}
    const r=await staffFn({action:'staff_add',suffix:u,name:$('#st_name').value.trim()||null,password:pw});
    if(r.error){toast(STAFF_ERR[r.error]||('เพิ่มไม่สำเร็จ ('+r.error+')'));return}toast('เพิ่มพนักงานแล้ว · ชื่อผู้ใช้ '+uname(r.username||(upfx()+u)));f.reset();loadStaff();return}
  if(f.classList.contains('stpw')){const pw=f.querySelector('input').value;if(pw.length<6){toast(STAFF_ERR.weak_password);return}
    const r=await staffFn({action:'staff_pw',email:f.dataset.email,password:pw});if(r.error){toast(STAFF_ERR[r.error]||'เปลี่ยนไม่สำเร็จ');return}S.staffPw=null;toast('เปลี่ยนรหัสผ่านพนักงานแล้ว');loadStaff();return}
  if(id==='myPwForm'){const a1=$('#my_pw').value,a2=$('#my_pw2').value;if(a1.length<8){toast('รหัสผ่านต้องมีอย่างน้อย 8 ตัวอักษร');return}if(a1!==a2){toast('ยืนยันรหัสผ่านไม่ตรงกัน');return}
    const r=await staffFn({action:'my_pw',password:a1});if(!r||r.error){toast('เปลี่ยนรหัสผ่านไม่สำเร็จ'+(r&&r.error?' ('+r.error+')':''));return}f.reset();toast('เปลี่ยนรหัสผ่านแล้ว');return}
  if(id==='catForm'){""")

# Staff accounts do not see reports or the menu editor.
R("NAV.filter(([v])=>!(v==='kds'&&shop().kdsOff))",
  "NAV.filter(([v])=>!(v==='kds'&&shop().kdsOff)&&!(window.POS_STANDALONE&&window.POS_ACCOUNT&&window.POS_ACCOUNT().role!=='manager'&&['reports','menu','settings'].includes(v)))")
R("function go(view){",
  "function staffBlocked(v){return !!(window.POS_STANDALONE&&window.POS_ACCOUNT&&window.POS_ACCOUNT().role!=='manager'&&['reports','menu','settings'].includes(v))}\nfunction go(view){if(staffBlocked(view)){if(view==='settings')toast('เฉพาะผู้จัดการร้าน');view='sell'}")
R("function render(force){","function render(force){if(staffBlocked(S.view))S.view='sell';")

# Customer-app links carry the shop.
R("function appBase(){",
  "function appBase(){if(window.POS_SESSION&&window.POS_SESSION.shop)return location.origin+'/s/'+window.POS_SESSION.shop.slug;")

# Default: this device pulls customer-app orders (a lease keeps it to one device).
R("let PR={paper:'80',", "let PR={bridge:!!window.POS_STANDALONE,paper:'80',")

os.makedirs(os.path.join(ROOT, 'pos'), exist_ok=True)
open(os.path.join(ROOT, 'pos', 'index.html'), 'w', encoding='utf-8').write(src)
print('built pos/index.html', len(src), 'bytes')

# Public demo: the same app in its built-in demo mode (no login, nothing is saved).
demo = orig.replace('<title>POS คาเฟ่</title>', '<title>เดโม Coconut POS Cafe · ทดลองใช้ได้ทันที</title>', 1)
demo = web_print(demo, 'demo')
demo = demo.replace('<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>',
  PRINT_JS + KIOSK_JS + '\n<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>', 1)
demo = demo.replace('<span id="appPill"></span>',
  '<span data-eplang></span><a class="btn sm" href="/signup" style="text-decoration:none">สมัครทดลองใช้ฟรี</a><span id="appPill"></span>', 1)
demo = ('<!doctype html>\n<html lang="th">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
        '<meta name="theme-color" content="#F3F7FB">\n<link rel="icon" href="/easypos.svg?v=2" type="image/svg+xml">\n'
        '<meta name="description" content="ลองใช้ Coconut POS Cafe ได้ทันที ไม่ต้องสมัคร ข้อมูลในเดโมไม่ถูกบันทึก">\n'
        '<style>[hidden]{display:none!important}html,body{height:100%;margin:0}img{max-width:100%}</style>\n</head>\n<body>\n'
        + demo + '\n<script src="/i18n-en.js"></script>\n<script src="/easypos-i18n.js"></script>\n</body>\n</html>\n')
os.makedirs(os.path.join(ROOT, 'demo'), exist_ok=True)
open(os.path.join(ROOT, 'demo', 'index.html'), 'w', encoding='utf-8').write(demo)
print('built demo/index.html', len(demo), 'bytes')
