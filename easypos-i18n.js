/* Easy POS public pages: Thai / English switch.
   Text nodes and a few attributes are swapped using the Thai text as the key, so the HTML stays plain Thai. */
(function(){
var EN={
'ผลิตภัณฑ์':'Products','ฟีเจอร์':'Features','ราคา':'Pricing','คำถามที่พบบ่อย':'FAQ','เข้าสู่ระบบ':'Log in',
'คาเฟ่ ร้านอาหาร ร้านเครื่องดื่ม':'Cafés, restaurants, drink shops','ร้านค้า ร้านของชำ มินิมาร์ท':'Shops, grocery stores, minimarts',
'เร็ว ๆ นี้':'Soon','ทดลองฟรี 30 วัน':'Free 30-day trial','ทดลองใช้ฟรี 30 วัน · ไม่ต้องผูกบัตร':'Free for 30 days · No card required',
'ขายง่าย':'Sell easily,','จบในเครื่องเดียว':'all in one device','POS สำหรับ':'The POS for your shop','ร้านของคุณ':'\u200b',
'Easy POS รวมหน้าขาย รับออเดอร์ผ่าน QR บนมือถือลูกค้า จอครัว จอลูกค้า และสมาชิกสะสมแต้มไว้ในที่เดียว ใช้บนแท็บเล็ต คอมพิวเตอร์ หรือมือถือก็ได้ เริ่มต้นเพียง':'Easy POS brings checkout, QR ordering from customers’ phones, a kitchen screen, a customer display and loyalty points together in one place. Use it on a tablet, computer or phone, from just',
'299 บาท/เดือน':'฿299/month','เริ่มทดลองใช้ฟรี':'Start free trial','ดูผลิตภัณฑ์':'See products',
'ไม่ต้องติดตั้งโปรแกรม':'Nothing to install','รับพร้อมเพย์ QR':'PromptPay QR payments','ยกเลิกได้ทุกเมื่อ':'Cancel anytime',
'ลาเต้เย็น':'Iced latte','ครัวซองต์':'Croissant','รวม':'Total','ชำระเงิน':'Pay','สั่งผ่านมือถือ':'Order on your phone',
'สแกน QR ที่โต๊ะ · โต๊ะ 4':'Scan the table QR · Table 4','ยืนยันสั่งอาหาร':'Place order','Mobile Order ใหม่':'New mobile order','A012 (โต๊ะ 4) · รอชำระ':'A012 (Table 4) · Awaiting payment',
'เลือก Easy POS ที่ใช่':'Choose the right Easy POS','สำหรับธุรกิจของคุณ':'for your business',
'แต่ละระบบมีหน้าเข้าสู่ระบบและบัญชีแยกกันชัดเจน ข้อมูลร้านไม่ปนกัน':'Each product has its own login and accounts, so shop data never mixes.',
'คาเฟ่ ร้านอาหาร ร้านเครื่องดื่ม เบเกอรี่':'Cafés, restaurants, drink shops, bakeries','พร้อมใช้งาน':'Available now',
'หน้าขายรวดเร็ว ตัวเลือกเมนู ร้อน/เย็น/ความหวาน':'Fast checkout with options like hot/iced/sweetness','Mobile Order ลูกค้าสแกน QR สั่งเอง':'Mobile Order: customers scan a QR and order',
'จอครัว/บาร์ และเรียกคิว':'Kitchen/bar screen and queue calling','ผังโต๊ะ เปิดบิล แยกโซน':'Floor plan, table bills, zones',
'จอลูกค้าพร้อมโฆษณารูป/วิดีโอ':'Customer display with image/video ads','สมาชิกสะสมแต้มด้วยเบอร์โทร':'Loyalty points by phone number',
'/ เดือน · ทดลองฟรี 30 วัน':'/ month · free 30-day trial','เข้าสู่ระบบร้านคาเฟ่ที่':'Café shops log in at','ทดลองใช้ฟรี 30 วัน':'Try free for 30 days','เข้าสู่ระบบ Cafe':'Cafe log in',
'กำลังพัฒนา':'In development','สแกนบาร์โค้ดขายสินค้า':'Sell by scanning barcodes','สต็อกสินค้า แจ้งเตือนของใกล้หมด':'Stock control with low-stock alerts',
'รับสินค้าเข้า ต้นทุน กำไร':'Goods receiving, cost and profit','ขายเงินเชื่อ ลูกค้าประจำ':'Credit sales for regular customers','รับพร้อมเพย์ QR พิมพ์ใบเสร็จ':'PromptPay QR and printed receipts',
'รายงานยอดขายรายวัน/สินค้าขายดี':'Daily sales and best-seller reports','/ เดือน · เมื่อเปิดให้บริการ':'/ month · at launch','ระบบเข้าสู่ระบบแยกที่':'Separate login at','· เปิดเร็ว ๆ นี้':'· opening soon',
'ดูรายละเอียด':'Learn more','เข้าสู่ระบบ Retail':'Retail log in','ฟีเจอร์ Easy POS Cafe':'Easy POS Cafe features',
'ครบทุกอย่างที่ร้านต้องใช้':'Everything your shop needs','ในราคาเดียว':'for one price','ไม่มีค่าติดตั้ง ไม่มีค่าโมดูลเพิ่ม ใช้ได้ทุกฟีเจอร์ตั้งแต่วันแรก':'No setup fee, no paid add-ons. Every feature from day one.',
'หน้าขายใช้ง่าย':'Easy checkout','แตะเมนู เลือกตัวเลือก รับเงินสด QR บัตร หรือโอน ทอนเงินอัตโนมัติ พิมพ์ใบเสร็จได้ทันที':'Tap items, pick options, take cash, QR, card or transfer. Change is calculated for you and receipts print instantly.',
'Mobile Order ผ่าน QR':'QR Mobile Order','ลูกค้าสแกนสั่งเองจากโต๊ะหรือสั่งกลับบ้าน ออเดอร์เข้าครัวเมื่อชำระที่เคาน์เตอร์แล้ว':'Customers order from their table or for takeaway. Orders go to the kitchen once paid at the counter.',
'จอครัวและคิว':'Kitchen screen & queue','ครัวและบาร์เห็นออเดอร์แบบเรียลไทม์ แยกสถานี กดทำเสร็จแล้วเรียกคิวลูกค้า':'Kitchen and bar see orders in real time by station, then call the customer’s number when ready.',
'จอลูกค้าและโฆษณา':'Customer display & ads','แสดงรายการและยอดชำระให้ลูกค้าเห็น พร้อม QR พร้อมเพย์ เวลาว่างเล่นรูปหรือวิดีโอโปรโมชัน':'Show items, totals and a PromptPay QR to customers, and play promo images or videos when idle.',
'สมาชิกสะสมแต้ม':'Loyalty points','ลูกค้าสมัครด้วยเบอร์โทร ได้แต้มทุกครั้งที่ซื้อ แลกแต้มได้ ดูยอดซื้อสะสมของแต่ละคน':'Customers join with their phone number, earn points on every purchase and redeem them. See each member’s total spend.',
'รายงานและรอบการขาย':'Reports & shifts','ยอดขายรายวัน เมนูขายดี แยกช่องทางชำระ เปิด–ปิดรอบ นับเงินในลิ้นชัก':'Daily sales, best sellers, payment breakdown, shift open/close and cash drawer counts.',
'ผังโต๊ะ':'Floor plan','วาดผังร้านเอง เห็นโต๊ะว่างหรือไม่ว่าง เปิดบิลตามโต๊ะ สั่งเพิ่มและย้ายโต๊ะได้':'Draw your own layout, see which tables are free, open bills by table, add orders and move tables.',
'บัญชีพนักงาน':'Staff accounts','ผู้จัดการสร้างชื่อผู้ใช้ให้พนักงาน กำหนดสิทธิ์ พนักงานขายได้แต่แก้เมนูและตั้งค่าไม่ได้':'Managers create staff usernames. Staff can sell but can’t change the menu or settings.',
'ใช้ได้ทุกอุปกรณ์':'Works on any device','เปิดผ่านเบราว์เซอร์บนแท็บเล็ต คอมพิวเตอร์ หรือมือถือ ข้อมูลซิงก์ทุกเครื่องทันที':'Runs in the browser on tablets, computers and phones, with data synced across devices instantly.',
'เริ่มใช้งาน':'Get started','เปิดร้านได้ใน 3 ขั้นตอน':'Open your shop in 3 steps','สมัครทดลองใช้':'Sign up for the trial',
'กรอกข้อมูลร้าน ชื่อ เบอร์โทร และอีเมลสำหรับเข้าสู่ระบบ เลือกทดลองฟรี 30 วัน':'Enter your shop details, name, phone and a login email, then choose the free 30-day trial.',
'รอยืนยันเปิดร้าน':'We confirm your shop','ทีมงานตรวจสอบและเปิดร้านให้ พร้อมลิงก์หน้าสั่งอาหารเฉพาะร้านของคุณ':'Our team reviews and opens your shop, with an ordering link just for you.',
'ใส่เมนูแล้วเริ่มขาย':'Add your menu and sell','เพิ่มเมนู รูปภาพ ราคา ตั้งค่าพร้อมเพย์ เพิ่มพนักงาน แล้วเริ่มรับออเดอร์ได้เลย':'Add items, photos and prices, set up PromptPay, add staff and start taking orders.',
'ราคาเดียว ใช้ได้ทุกฟีเจอร์':'One price, every feature','ไม่มีค่าติดตั้ง ไม่มีสัญญาผูกมัด ทดลองใช้ฟรีก่อนตัดสินใจ':'No setup fee, no contract. Try it free before you decide.',
'/ เดือน':'/ month','ใช้ฟรี 30 วันแรก ชำระผ่านพร้อมเพย์':'First 30 days free · pay by PromptPay',
'ทุกฟีเจอร์: หน้าขาย Mobile Order จอครัว จอลูกค้า สมาชิก รายงาน':'Every feature: checkout, Mobile Order, kitchen screen, customer display, members, reports',
'ใช้ได้ไม่จำกัดอุปกรณ์และไม่จำกัดจำนวนบิล':'Unlimited devices and unlimited bills','บัญชีพนักงานตามแพ็กเกจ':'Staff accounts by package','ดูวันหมดอายุและแจ้งชำระได้เองในระบบ':'See your renewal date and submit payments in the app',
'เริ่มทดลองใช้ฟรี 30 วัน':'Start your free 30-day trial','มีคำถาม? เรามีคำตอบ':'Questions? We have answers',
'ทดลองใช้ฟรี 30 วัน ต้องจ่ายเงินก่อนไหม':'Do I pay anything for the 30-day trial?',
'ไม่ต้อง เลือกแพ็กเกจ “ทดลองใช้ฟรี 30 วัน” ตอนสมัคร เมื่อร้านได้รับการยืนยันก็ใช้งานได้ทุกฟีเจอร์ทันที ใกล้ครบกำหนดค่อยชำระค่าบริการผ่านพร้อมเพย์จากหน้าตั้งค่าของร้าน':'No. Choose the “Free 30-day trial” package when you sign up. Once your shop is confirmed you get every feature. Pay by PromptPay from your shop settings when the trial is nearly over.',
'ต้องใช้อุปกรณ์อะไรบ้าง':'What equipment do I need?','ใช้แท็บเล็ต คอมพิวเตอร์ หรือมือถือที่มีเบราว์เซอร์และอินเทอร์เน็ตก็พอ ต่อเครื่องพิมพ์ใบเสร็จและลิ้นชักเก็บเงินเพิ่มได้ถ้าต้องการ':'Any tablet, computer or phone with a browser and internet. Add a receipt printer and cash drawer if you like.',
'Easy POS Cafe กับ Easy POS Retail ต่างกันอย่างไร':'How is Easy POS Cafe different from Easy POS Retail?',
'Cafe ออกแบบสำหรับร้านที่ขายเมนูมีตัวเลือก มีโต๊ะ ครัว และออเดอร์จากมือถือ ส่วน Retail สำหรับร้านค้าที่ขายสินค้าด้วยบาร์โค้ดและต้องคุมสต็อก ทั้งสองระบบมีบัญชีและหน้าเข้าสู่ระบบแยกกัน ตอนนี้ Retail กำลังพัฒนา':'Cafe is built for menus with options, tables, a kitchen and mobile orders. Retail is for shops that sell barcoded goods and track stock. Each has its own accounts and login. Retail is in development.',
'พนักงานเข้าใช้งานอย่างไร':'How do staff log in?','ผู้จัดการร้านสร้างบัญชีให้พนักงานในหน้าตั้งค่า ชื่อผู้ใช้ขึ้นต้นด้วยรหัสร้านของคุณ พนักงานเข้าสู่ระบบด้วยชื่อผู้ใช้และรหัสผ่าน ไม่ต้องใช้อีเมล':'The manager creates staff accounts in Settings. Usernames start with your shop code, and staff log in with a username and password, no email needed.',
'ถ้าไม่ต่ออายุ ข้อมูลจะหายไหม':'Will I lose my data if I don’t renew?','ไม่หาย หลังครบกำหนดมีช่วงผ่อนผัน 7 วัน จากนั้นการขายจะถูกล็อกไว้ชั่วคราว เมื่อชำระและได้รับการยืนยัน ร้านกลับมาใช้งานต่อได้พร้อมข้อมูลเดิม':'No. There’s a 7-day grace period, then selling is paused. Once payment is confirmed your shop is back with all its data.',
'พร้อมให้ร้านของคุณขายง่ายขึ้นหรือยัง':'Ready to make selling easier?','ทดลองใช้ Easy POS Cafe ฟรี 30 วัน จากนั้นเพียง 299 บาทต่อเดือน':'Try Easy POS Cafe free for 30 days, then just ฿299 a month.',
'สมัครทดลองใช้':'Sign up for the trial',
/* retail page */
'เข้าสู่ระบบสำหรับร้านค้า ร้านของชำ':'Log in for shops and grocery stores','กำลังพัฒนา · ยังไม่เปิดให้เข้าสู่ระบบ':'In development · Login not open yet',
'Easy POS Retail เป็นระบบแยกจาก Easy POS Cafe มีบัญชีและหน้าเข้าสู่ระบบของตัวเอง เมื่อเปิดให้บริการจะเข้าสู่ระบบได้ที่หน้านี้':'Easy POS Retail is separate from Easy POS Cafe, with its own accounts and login. You’ll log in on this page once it launches.',
'สต็อกสินค้า ต้นทุน กำไร':'Stock, cost and profit','รับพร้อมเพย์ QR และพิมพ์ใบเสร็จ':'PromptPay QR and printed receipts','กลับหน้าแรก Easy POS':'Back to Easy POS home',
'เป็นร้านคาเฟ่? เข้าสู่ระบบ Easy POS Cafe':'Run a café? Log in to Easy POS Cafe','ร้านคาเฟ่และร้านอาหาร':'Cafés and restaurants:','ทดลองใช้ Easy POS Cafe ฟรี 30 วัน':'try Easy POS Cafe free for 30 days',
/* attributes / meta */
'Easy POS หน้าแรก':'Easy POS home','เมนูหลัก':'Main menu','ลิงก์ท้ายหน้า':'Footer links','ภาษา':'Language',
'Easy POS · ระบบขายหน้าร้านสำหรับคาเฟ่และร้านค้า':'Easy POS · Point of sale for cafés and shops','เข้าสู่ระบบ · Easy POS Retail':'Log in · Easy POS Retail',
'Easy POS ระบบ POS ใช้ง่ายสำหรับคาเฟ่ ร้านอาหาร และร้านของชำ ขายหน้าร้าน รับออเดอร์ผ่านมือถือ จอครัว สมาชิกสะสมแต้ม เริ่มต้น 299 บาทต่อเดือน ทดลองใช้ฟรี 30 วัน':'Easy POS is an easy point of sale for cafés, restaurants and grocery stores: checkout, mobile ordering, kitchen screen and loyalty points from ฿299/month, with a free 30-day trial.',
'Easy POS Retail ระบบ POS สำหรับร้านค้าและร้านของชำ กำลังพัฒนา':'Easy POS Retail, a point of sale for shops and grocery stores, is in development.'
};
var KEY='epLang',orig=new WeakMap(),attrs=['aria-label','title','placeholder'];
function norm(s){return s.replace(/\s+/g,' ').trim()}
function pick(){var q=new URLSearchParams(location.search).get('lang');if(q==='en'||q==='th')return q;
  try{var s=localStorage.getItem(KEY);if(s==='en'||s==='th')return s}catch(e){}
  return /^th\b/i.test(navigator.language||'th')?'th':'en'}
function apply(lang){
  var w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT),n;
  while((n=w.nextNode())){if(n.parentElement&&n.parentElement.closest('script,style,[data-noi18n]'))continue;
    if(!orig.has(n)){var k=norm(n.nodeValue);if(!k||!EN[k])continue;orig.set(n,n.nodeValue)}
    var th=orig.get(n),key=norm(th),lead=th.match(/^\s*/)[0],trail=th.match(/\s*$/)[0];
    n.nodeValue=lang==='en'?lead+EN[key]+trail:th}
  document.querySelectorAll('['+attrs.join('],[')+']').forEach(function(el){attrs.forEach(function(a){if(!el.hasAttribute(a))return;var d='data-th-'+a;
    if(!el.hasAttribute(d)){if(!EN[norm(el.getAttribute(a))])return;el.setAttribute(d,el.getAttribute(a))}
    var th=el.getAttribute(d);el.setAttribute(a,lang==='en'?EN[norm(th)]:th)})});
  if(!document.documentElement.dataset.thTitle)document.documentElement.dataset.thTitle=document.title;
  var tt=document.documentElement.dataset.thTitle;document.title=lang==='en'&&EN[tt]?EN[tt]:tt;
  var md=document.querySelector('meta[name=description]');if(md){if(!md.dataset.th)md.dataset.th=md.content;md.content=lang==='en'&&EN[md.dataset.th]?EN[md.dataset.th]:md.dataset.th}
  document.documentElement.lang=lang;document.documentElement.classList.toggle('en',lang==='en');
  document.querySelectorAll('[data-lang]').forEach(function(b){b.setAttribute('aria-pressed',String(b.dataset.lang===lang))});
  window.EP_LANG=lang;try{document.dispatchEvent(new CustomEvent('ep-lang',{detail:lang}))}catch(e){}
}
window.EP_SET_LANG=function(l){try{localStorage.setItem(KEY,l)}catch(e){}apply(l)};
window.EP_LANG='th';
document.addEventListener('click',function(e){var b=e.target.closest('[data-lang]');if(b){e.preventDefault();window.EP_SET_LANG(b.dataset.lang)}});
function start(){var l=pick();if(l!=='th')apply(l);else{window.EP_LANG='th';document.querySelectorAll('[data-lang]').forEach(function(b){b.setAttribute('aria-pressed',String(b.dataset.lang==='th'))})}}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start);else start();
})();
