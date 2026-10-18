/* Coconut POS: Thai / English switch for every page.
   Needs /i18n-en.js (window.EP_DICT, Thai -> English) loaded first.
   The pages are written in Thai; in English mode every Thai text node, a few attributes, the page title
   and alert/confirm/prompt messages are translated as they appear, so screens drawn later are covered too.
   Lookup order: whole text, then known phrases inside the text (longest first). */
(function(){
var D=window.EP_DICT||{},KEY='epLang',TH=/[฀-๿]/,ATTRS=['placeholder','title','aria-label'];
var lang='th',orig=new WeakMap(),cache=new Map(),busy=false,obs=null;
function norm(s){return s.replace(/\s+/g,' ').trim()}
function esc(s){return s.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')}
// Phrases of 4+ characters can be found inside longer text; shorter ones only match a whole text node.
var parts=Object.keys(D).filter(function(k){return k.length>=4&&TH.test(k)&&D[k]&&!/\bBank\b/.test(D[k])}).sort(function(a,b){return b.length-a.length});
var RE=parts.length?new RegExp(parts.map(esc).join('|'),'g'):null;
var MON={'ม.ค.':'Jan','ก.พ.':'Feb','มี.ค.':'Mar','เม.ย.':'Apr','พ.ค.':'May','มิ.ย.':'Jun','ก.ค.':'Jul','ส.ค.':'Aug','ก.ย.':'Sep','ต.ค.':'Oct','พ.ย.':'Nov','ธ.ค.':'Dec',
  'มกราคม':'January','กุมภาพันธ์':'February','มีนาคม':'March','เมษายน':'April','พฤษภาคม':'May','มิถุนายน':'June','กรกฎาคม':'July','สิงหาคม':'August','กันยายน':'September','ตุลาคม':'October','พฤศจิกายน':'November','ธันวาคม':'December'};
var MRE=new RegExp('('+Object.keys(MON).map(esc).join('|')+')(\\s*)(\\d{4})?','g');
// Short words that only make sense as whole words next to numbers ("3 วัน").
var W={'วัน':'days','บาท':'baht','ใบ':'receipts','รวม':'Total','รับ':'Received','โซน':'zones','เดือน':'months','ครั้ง':'times','รายการ':'items','คน':'people','ชิ้น':'pcs','แต้ม':'points','นาที':'min','ปิด':'off','เปิด':'on','ท่าน':'guests','โต๊ะ':'Table','คิว':'Queue','บิล':'bills','ที่':'seats','น.':'','ชม.':'h'};
function dates(s){return s.replace(MRE,function(m,mo,sp,y){return MON[mo]+(y?sp+(+y>2400?(+y-543):y):sp)})}
function words(s){return s.replace(/(^|[\s(·,])([\u0E00-\u0E7F.]+)(?=$|[\s)·,])/g,function(m,a,w){var e=W[w]!=null?W[w]:D[w];return e==null?m:a+e})}
function mixed(t){return t.split(/[\s·,:;()\/|]+/).some(function(x){return TH.test(x)&&/[A-Za-z]/.test(x)})}
function tr(s){
  if(!s||!TH.test(s))return s;
  if(cache.has(s))return cache.get(s);
  var lead=s.match(/^\s*/)[0],trail=s.match(/\s*$/)[0],k=norm(s),out=s;
  var k2=k.replace(/\d[\d,.]*/g,'{n}'),nums=k.match(/\d[\d,.]*/g);
  if(D[k]!=null)out=lead+D[k]+trail;
  else if(nums&&D[k2]!=null)out=lead+D[k2].replace(/\{n\}/g,function(){return nums.shift()||''})+trail;
  else{var x=dates(s);
    if(RE)x=x.replace(RE,function(m){return '\u0001'+D[m]+'\u0002'}).replace(/\u0002\u0001/g,' ').replace(/\u0002(?=[A-Za-z0-9฿(])/g,' ').replace(/([A-Za-z0-9.,)%])\u0001/g,'$1 ').replace(/[\u0001\u0002]/g,'');
    x=words(x).replace(/([a-z0-9%)])([A-Z(])/g,'$1 $2');
    // A phrase glued inside a longer Thai word (often a name) gives mixed text: keep the Thai instead.
    if(!mixed(x))out=x;else{var y=words(dates(s));if(!mixed(y))out=y}}
  if(cache.size>5000)cache.clear();cache.set(s,out);return out}
function skip(el){return el&&el.closest&&el.closest('script,style,textarea,[data-noi18n],[contenteditable=true]')}
function doText(n){var v=n.nodeValue;if(!v||!TH.test(v)||skip(n.parentElement))return;
  var t=tr(v);if(t!==v){if(!orig.has(n))orig.set(n,v);n.nodeValue=t}}
function doEl(el){if(!el.getAttribute||skip(el))return;
  ATTRS.forEach(function(a){var v=el.getAttribute(a);if(v&&TH.test(v)){var t=tr(v);if(t!==v){el.setAttribute('data-th-'+a,v);el.setAttribute(a,t)}}});
  if(el.tagName==='INPUT'&&/^(button|submit)$/i.test(el.type)&&TH.test(el.value)){el.setAttribute('data-th-value',el.value);el.value=tr(el.value)}}
function walk(root){if(!root)return;if(root.nodeType===3){doText(root);return}if(root.nodeType!==1&&root.nodeType!==11)return;
  if(root.nodeType===1){if(skip(root))return;doEl(root)}
  var w=document.createTreeWalker(root,NodeFilter.SHOW_TEXT|NodeFilter.SHOW_ELEMENT),n;
  while((n=w.nextNode())){if(n.nodeType===3)doText(n);else doEl(n)}}
function doTitle(){if(TH.test(document.title)){var t=tr(document.title);if(t!==document.title){document.documentElement.setAttribute('data-th-title',document.title);document.title=t}}
  var md=document.querySelector('meta[name=description]');if(md&&TH.test(md.content)){md.setAttribute('data-th',md.content);md.content=tr(md.content)}}
function onMut(list){if(busy||lang!=='en')return;busy=true;
  try{list.forEach(function(m){if(m.type==='characterData')doText(m.target);else if(m.type==='attributes')doEl(m.target);else m.addedNodes.forEach(walk)});doTitle()}finally{busy=false}}
function restore(){
  var w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT),n;while((n=w.nextNode())){if(orig.has(n)){n.nodeValue=orig.get(n);orig.delete(n)}}
  document.querySelectorAll('[data-th-placeholder],[data-th-title],[data-th-aria-label],[data-th-value]').forEach(function(el){
    ATTRS.concat(['value']).forEach(function(a){var k='data-th-'+a;if(el.hasAttribute(k)){if(a==='value')el.value=el.getAttribute(k);else el.setAttribute(a,el.getAttribute(k));el.removeAttribute(k)}})});
  var t=document.documentElement.getAttribute('data-th-title');if(t){document.title=t;document.documentElement.removeAttribute('data-th-title')}
  var md=document.querySelector('meta[name=description][data-th]');if(md){md.content=md.getAttribute('data-th');md.removeAttribute('data-th')}}
function apply(l){lang=l;window.EP_LANG=l;document.documentElement.lang=l;document.documentElement.classList.toggle('en',l==='en');
  if(l==='en'){busy=true;try{walk(document.body);doTitle()}finally{busy=false}
    if(!obs){obs=new MutationObserver(onMut);obs.observe(document.documentElement,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:ATTRS})}}
  else{if(obs){obs.disconnect();obs=null}restore()}
  document.querySelectorAll('[data-lang]').forEach(function(b){b.setAttribute('aria-pressed',String(b.dataset.lang===l))});
  try{document.dispatchEvent(new CustomEvent('ep-lang',{detail:l}))}catch(e){}}
// Native dialogs are translated too.
['alert','confirm','prompt'].forEach(function(f){var o=window[f];if(!o)return;window[f]=function(m){var a=[].slice.call(arguments);if(lang==='en'&&typeof m==='string')a[0]=tr(m);return o.apply(window,a)}});
function pick(){var q=new URLSearchParams(location.search).get('lang');if(q==='en'||q==='th'){try{localStorage.setItem(KEY,q)}catch(e){}return q}
  try{var s=localStorage.getItem(KEY);if(s==='en'||s==='th')return s}catch(e){}
  return /^th\b/i.test(navigator.language||'th')?'th':'en'}
window.EP_SET_LANG=function(l){try{localStorage.setItem(KEY,l)}catch(e){}apply(l)};
window.EP_T=function(s){return lang==='en'?tr(s):s};
window.EP_LANG='th';
document.addEventListener('click',function(e){var b=e.target.closest&&e.target.closest('[data-lang]');if(!b)return;e.preventDefault();e.stopPropagation();window.EP_SET_LANG(b.dataset.lang)},true);
window.addEventListener('storage',function(e){if(e.key===KEY&&(e.newValue==='en'||e.newValue==='th')&&e.newValue!==lang)apply(e.newValue)});
var CSS='.eplang{display:inline-flex;align-items:center;gap:2px;padding:3px;border-radius:11px;border:1px solid var(--line2,rgba(127,127,127,.35));background:var(--surface,transparent);flex-shrink:0;vertical-align:middle}'+
  '.eplang button{border:0;background:none;color:inherit;opacity:.7;font-family:inherit;font-weight:600;font-size:12px;line-height:1;min-height:30px;min-width:34px;padding:0 8px;border-radius:8px;cursor:pointer}'+
  '.eplang button[aria-pressed=true]{background:var(--accent,#4F7BFF);color:var(--on-accent,#fff);opacity:1}';
window.EP_LANG_BTN=function(){var l=window.EP_LANG||'th';return '<span class="eplang" role="group" aria-label="ภาษา / Language" data-noi18n><button type="button" data-lang="th" aria-pressed="'+(l==='th')+'">TH</button><button type="button" data-lang="en" aria-pressed="'+(l==='en')+'">EN</button></span>'};
function start(){if(!document.getElementById('eplangCss')){var st=document.createElement('style');st.id='eplangCss';st.textContent=CSS;document.head.appendChild(st)}
  document.querySelectorAll('[data-eplang]').forEach(function(el){if(!el.firstChild)el.innerHTML=window.EP_LANG_BTN()});apply(pick())}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start);else start();
})();
