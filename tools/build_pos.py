#!/usr/bin/env python3
"""Build the standalone POS (pos/index.html) from the Claude-artifact source.

Usage: python3 tools/build_pos.py
Reads  src/cafe-pos.artifact.html and tools/standalone-shim.html
Writes pos/index.html
"""
import os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = open(os.path.join(ROOT, 'src', 'cafe-pos.artifact.html'), encoding='utf-8').read()
shim = open(os.path.join(ROOT, 'tools', 'standalone-shim.html'), encoding='utf-8').read()


def R(a, b):
    global src
    if a not in src:
        sys.exit('build_pos: patch point not found: ' + a[:80])
    src = src.replace(a, b, 1)


# The page runs as its own website, so it needs a full HTML document.
src = ('<!doctype html>\n<html lang="th">\n<head>\n<meta charset="utf-8">\n'
       '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
       '<meta name="theme-color" content="#2F6FB0">\n<link rel="icon" href="/icon.svg" type="image/svg+xml">\n'
       '<meta name="robots" content="noindex">\n<style>[hidden]{display:none!important}:root{color-scheme:light;padding:env(safe-area-inset-top,0px) 0 env(safe-area-inset-bottom,0px)}img{max-width:100%}</style>\n</head>\n<body>\n' + src + '\n</body>\n</html>\n')
R('html,body{height:100%}', 'html,body{height:100%;margin:0}')

# Runtime shim (login + Supabase store) loads before the app script.
R('<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>',
  shim + '\n<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>')

# Menu images come from Supabase Storage.
R("function imgUrl(id){return '/_blob/'+encodeURIComponent(id)}",
  "function imgUrl(id){return window.POS_IMG?window.POS_IMG(id):'/_blob/'+encodeURIComponent(id)}")

# Printing: print straight to the printer instead of saving a file.
R("  if(!S.downloads){toast('อุปกรณ์นี้บันทึกไฟล์สำหรับพิมพ์ไม่ได้');return false}",
  "  if(!S.downloads&&!window.POS_STANDALONE){toast('อุปกรณ์นี้บันทึกไฟล์สำหรับพิมพ์ไม่ได้');return false}")
R("  try{await S.downloads.save({filename:name+'.html',data:html})",
  "  if(window.POS_STANDALONE){window.POS_PRINT(html);toast('กำลังพิมพ์ '+name);return true}\n  try{await S.downloads.save({filename:name+'.html',data:html})")
R("function saveQrSheet(){\n  if(!S.downloads){toast('อุปกรณ์นี้บันทึกไฟล์ไม่ได้');return}",
  "function saveQrSheet(){\n  if(!S.downloads&&!window.POS_STANDALONE){toast('อุปกรณ์นี้บันทึกไฟล์ไม่ได้');return}")
R("  S.downloads.save({filename:'QR-สั่งอาหาร.html',data:html})",
  "  if(window.POS_STANDALONE){window.POS_PRINT(html);return}\n  S.downloads.save({filename:'QR-สั่งอาหาร.html',data:html})")
R("(S.downloads?'':'<div class=\"note\">", "(S.downloads||window.POS_STANDALONE?'':'<div class=\"note\">")

# Customer-app bridge talks to Supabase through RPCs (no connector needed).
R("async function bridgeTick(){",
  r"""async function bridgeTickSB(){
  let wait=10000;
  try{
    const lease=await S.db.doc('bridge/lock').acquire({holder:deviceId,ttlMs:30000});
    if(!lease.acquired){S.app.state='other';S.app.msg='มีเครื่องอื่นเป็นตัวรับออเดอร์จากแอปอยู่';renderAppStatus();scheduleBridge(20000);return}
    const snap=JSON.stringify(appSnapshot());const sendSnap=snap!==lastSnap&&S.menu.length;const o=sendSnap?JSON.parse(snap):null;
    const vals=appStatuses();
    const sid=window.POS_SESSION.shop.id;const r=await window.POS_SB.rpc('pos_shop_sync',{p_sid:sid,p_menu:o?o.menu:null,p_shopdata:o?o.shop:null,p_status:vals.length?vals:null});
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
  "  if(window.POS_STANDALONE&&window.POS_ACCOUNT){const a=window.POS_ACCOUNT();const bs=window.POS_BILLSTATE?window.POS_BILLSTATE():null;$('#acct').innerHTML=a.email?`${a.admin?`<span class=\"adminbar\">ผู้ดูแลระบบ · ${esc(a.shop?a.shop.name:'')} <a href=\"/admin\">กลับแดชบอร์ด</a></span>`:''}${bs&&bs.cls&&a.role==='manager'?`<button class=\"billpill ${bs.cls==='bad'?'bad':''}\" data-act=\"billgo\">${esc(bs.t)}</button>`:''}<span>${esc(a.email)} · ${a.admin?'ผู้ดูแลระบบ':({manager:'ผู้จัดการร้าน',staff:'พนักงาน'})[a.role]||''}</span><button class=\"btn sm\" data-act=\"logout\">ออกจากระบบ</button>`:''}\n  $('#appPill').innerHTML=")
R("    case 'apptoggle':", "    case 'logout':if(window.POS_SB)window.POS_SB.auth.signOut().then(()=>location.reload());break;\n    case 'apptoggle':")

# Staff management (shop manager) and monthly billing in Settings.
R("const tabs=[['devices','อุปกรณ์และการรับเงิน'],",
  "const tabs=[['devices','อุปกรณ์และการรับเงิน'],...(window.POS_STANDALONE&&window.POS_ACCOUNT&&window.POS_ACCOUNT().role==='manager'?[['billing','ค่าบริการรายเดือน'],['staff','พนักงาน']]:[]),")
R("  else if(tab==='app'){",
  r"""  else if(tab==='billing'){body=`<h2>ค่าบริการรายเดือน</h2><div id="billingBox"><div class="muted">กำลังโหลด…</div></div>`;setTimeout(()=>{if(window.POS_BILLING)window.POS_BILLING.render($('#billingBox'))},0)}
  else if(tab==='staff'){const sh=(window.POS_SESSION||{}).shop||{};
    body=`<h2>พนักงาน</h2><span class="hint">เพิ่มอีเมลพนักงานที่นี่ แล้วให้พนักงานกด “สมัคร” ที่หน้าเข้าสู่ระบบด้วยอีเมลนั้น · พนักงานใช้หน้าขาย Mobile Order โต๊ะ จอครัว ประวัติใบเสร็จ และรอบการขายได้ แต่แก้เมนู ตั้งค่าร้าน และดูรายงานไม่ได้</span>
    <div class="note" id="staffQuota">บัญชีพนักงาน ${sh.staffUsed||0} / ${sh.staffLimit||0} · ต้องการเพิ่มจำนวน ติดต่อผู้ดูแลระบบ</div>
    <form class="form" id="staffForm"><div class="two"><label for="st_email">อีเมลพนักงาน<input id="st_email" type="email" required></label><label for="st_name">ชื่อ<input id="st_name" maxlength="40"></label></div><button class="btn primary" type="submit" style="align-self:flex-start">เพิ่มพนักงาน</button></form>
    <div id="staffList"><div class="muted">กำลังโหลด…</div></div>`;setTimeout(loadStaff,0)}
  else if(tab==='app'){""")
R("/* ===== render ===== */",
  r"""async function loadStaff(){const el=$('#staffList');if(!el||!window.POS_SB)return;const sid=window.POS_SESSION.shop.id;
  const r=await window.POS_SB.from('pos_members').select('*').eq('shop_id',sid).order('created_at');if(r.error){el.innerHTML='<div class="note">โหลดรายชื่อไม่สำเร็จ</div>';return}
  const n=r.data.filter(x=>x.role==='staff'&&x.active).length;const q=$('#staffQuota');const lim=window.POS_SESSION.shop.staffLimit||0;window.POS_SESSION.shop.staffUsed=n;
  if(q)q.textContent='บัญชีพนักงาน '+n+' / '+lim+(n>=lim?' · ครบจำนวนแล้ว ติดต่อผู้ดูแลระบบเพื่อเพิ่ม':' · เพิ่มได้อีก '+(lim-n)+' บัญชี');
  el.innerHTML=r.data.length?r.data.map(x=>`<div class="mrow"><div class="info"><b>${esc(x.name||x.email)}</b><small>${esc(x.email)} · ${x.role==='manager'?'ผู้จัดการร้าน':'พนักงาน'}${x.active?'':' · ปิดใช้งาน'}</small></div>${x.role==='staff'?`<button class="btn sm" data-act="staffactive" data-id="${esc(x.email)}" data-v="${x.active?'0':'1'}">${x.active?'ปิดใช้งาน':'เปิดใช้งาน'}</button>${S.confirm==='sfdel:'+x.email?`<button class="btn sm danger" data-act="staffdel" data-id="${esc(x.email)}">ยืนยันลบ</button><button class="btn sm" data-act="staffundel">ไม่ลบ</button>`:`<button class="btn sm" data-act="staffask" data-id="${esc(x.email)}">ลบ</button>`}`:''}</div>`).join(''):'<div class="muted">ยังไม่มี</div>'}
function staffErr(e){const m=String(e&&e.message||'');return /staff_limit/.test(m)?'เกินจำนวนบัญชีพนักงานที่ร้านใช้ได้ ติดต่อผู้ดูแลระบบเพื่อเพิ่ม':/duplicate|pos_members_pkey/.test(m)?'อีเมลนี้ใช้กับร้านอื่นอยู่แล้ว':/bad_email/.test(m)?'อีเมลไม่ถูกต้อง':'บันทึกไม่สำเร็จ: '+m}

/* ===== render ===== */""")
R("    case 'logout':",
  r"""    case 'staffactive':window.POS_SB.from('pos_members').update({active:d.v==='1'}).eq('shop_id',window.POS_SESSION.shop.id).eq('email',d.id).then(r=>{if(r.error)toast(staffErr(r.error));loadStaff()});break;
    case 'staffask':S.confirm='sfdel:'+d.id;loadStaff();break;
    case 'staffundel':S.confirm=null;loadStaff();break;
    case 'staffdel':S.confirm=null;window.POS_SB.from('pos_members').delete().eq('shop_id',window.POS_SESSION.shop.id).eq('email',d.id).eq('role','staff').then(r=>{toast(r.error?'ลบไม่สำเร็จ':'ลบแล้ว');loadStaff()});break;
    case 'billgo':S.stab='billing';go('settings');break;
    case 'logout':""")
R("  if(id==='catForm'){",
  r"""  if(id==='staffForm'){const em=$('#st_email').value.trim().toLowerCase();if(!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(em)){toast('ใส่อีเมลให้ถูกต้อง');return}
    const r=await window.POS_SB.from('pos_members').insert({email:em,name:$('#st_name').value.trim()||null,role:'staff',active:true,shop_id:window.POS_SESSION.shop.id});
    if(r.error){toast(staffErr(r.error));return}toast('เพิ่มพนักงานแล้ว ให้พนักงานสมัครด้วยอีเมลนี้');f.reset();loadStaff();return}
  if(id==='catForm'){""")

# Staff accounts do not see reports or the menu editor.
R("NAV.filter(([v])=>!(v==='kds'&&shop().kdsOff))",
  "NAV.filter(([v])=>!(v==='kds'&&shop().kdsOff)&&!(window.POS_STANDALONE&&window.POS_ACCOUNT&&window.POS_ACCOUNT().role!=='manager'&&['reports','menu'].includes(v)))")
R("function go(view){",
  "function go(view){if(window.POS_STANDALONE&&window.POS_ACCOUNT&&window.POS_ACCOUNT().role!=='manager'&&['reports','menu'].includes(view))view='sell';")

# Customer-app links carry the shop.
R("function appBase(){",
  "function appBase(){if(window.POS_SESSION&&window.POS_SESSION.shop)return location.origin+'/s/'+window.POS_SESSION.shop.slug+'/';")

# Default: this device pulls customer-app orders (a lease keeps it to one device).
R("let PR={paper:'80',", "let PR={bridge:!!window.POS_STANDALONE,paper:'80',")

os.makedirs(os.path.join(ROOT, 'pos'), exist_ok=True)
open(os.path.join(ROOT, 'pos', 'index.html'), 'w', encoding='utf-8').write(src)
print('built pos/index.html', len(src), 'bytes')
