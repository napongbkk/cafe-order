// Easy POS Retail: copy a shop's data (products, stock, bills, bill lines, members) into the shop's own Google Sheet.
// The shop shares its spreadsheet (Editor) with the platform's Google service account; the key is in pos_secrets.GOOGLE_SA_JSON.
// Actions: {action:'info'} -> service-account e-mail · {action:'sync', sid?} -> admin (any shop) or a member of the shop.
import { createClient } from "jsr:@supabase/supabase-js@2";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SB_URL, SERVICE, { auth: { persistSession: false } });
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const fail = (code: string, s = 400, extra: Record<string, unknown> = {}) => json({ error: code, ...extra }, s);

type SA = { client_email: string; private_key: string };
async function saKey(): Promise<SA | null> {
  const env = Deno.env.get("GOOGLE_SA_JSON");
  let raw = env || "";
  if (!raw) { const { data } = await db.from("pos_secrets").select("value").eq("key", "GOOGLE_SA_JSON").maybeSingle(); raw = (data?.value as string) || ""; }
  try { const j = JSON.parse(raw); return j.client_email && j.private_key ? j : null; } catch (_) { return null; }
}
const b64url = (u: Uint8Array | string) => btoa(typeof u === "string" ? u : String.fromCharCode(...u)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
let TOKEN: { t: string; exp: number } | null = null;
async function gToken(sa: SA): Promise<string> {
  if (TOKEN && TOKEN.exp > Date.now() + 60e3) return TOKEN.t;
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claim = b64url(JSON.stringify({ iss: sa.client_email, scope: "https://www.googleapis.com/auth/spreadsheets", aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600 }));
  const pem = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(head + "." + claim)));
  const r = await fetch("https://oauth2.googleapis.com/token", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: head + "." + claim + "." + b64url(sig) }) });
  const j = await r.json();
  if (!j.access_token) throw new Error("google_auth: " + (j.error_description || j.error || r.status));
  TOKEN = { t: j.access_token, exp: Date.now() + (j.expires_in || 3600) * 1000 };
  return TOKEN.t;
}
async function gapi(tok: string, method: string, url: string, body?: unknown) {
  const r = await fetch("https://sheets.googleapis.com/v4/spreadsheets/" + url, { method, headers: { Authorization: "Bearer " + tok, "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) { const m = (j as { error?: { message?: string; status?: string } }).error; const e = new Error(m?.message || String(r.status)); (e as Error & { status?: number }).status = r.status; throw e; }
  return j;
}
export function sheetIdFrom(v: string) { const m = String(v || "").match(/\/d\/([a-zA-Z0-9_-]{20,})/); return m ? m[1] : String(v || "").trim(); }

async function caller(req: Request) {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!jwt || jwt.split(".").length !== 3) return "";
  const { data: u } = await db.auth.getUser(jwt);
  return u?.user?.email?.toLowerCase() || "";
}

const D = (ms: unknown) => { const n = Number(ms); if (!n) return ""; const d = new Date(n + 7 * 3600e3); return d.toISOString().slice(0, 19).replace("T", " "); };
const PAY: Record<string, string> = { cash: "เงินสด", qr: "QR พร้อมเพย์", transfer: "โอนเงิน", card: "บัตร", credit: "ค้างชำระ", invoice: "ขายเชื่อ", points: "แต้ม", wallet: "กระเป๋าเงิน" };
type Row = (string | number | boolean | null)[];

async function sync(sid: string) {
  const sa = await saKey();
  if (!sa) return fail("no_google_key", 400);
  const { data: shop } = await db.from("pos_shops").select("id,name,product,sheet_id").eq("id", sid).maybeSingle();
  if (!shop) return fail("not_found", 404);
  const sheet = sheetIdFrom(shop.sheet_id || "");
  if (!sheet) return fail("no_sheet", 400);
  const rows: Record<string, { id: string; data: Record<string, unknown> }[]> = {};
  for (const col of ["products", "sales", "members", "branches", "staff"]) {
    const all: { id: string; data: Record<string, unknown> }[] = [];
    for (let from = 0; ; from += 1000) {
      const { data, error } = await db.from("pos_data").select("id,data").eq("shop_id", sid).eq("col", col).range(from, from + 999);
      if (error) return fail("db_error", 500);
      all.push(...(data || []) as { id: string; data: Record<string, unknown> }[]);
      if (!data || data.length < 1000) break;
    }
    rows[col] = all;
  }
  const bname: Record<string, string> = {}; rows.branches.forEach((b) => { bname[b.id] = String(b.data.name || b.id); });
  const sname: Record<string, string> = {}; rows.staff.forEach((s) => { sname[s.id] = String(s.data.name || ""); });
  const mname: Record<string, string> = {}; rows.members.forEach((m) => { mname[m.id] = String(m.data.name || ""); });
  const branches = rows.branches.map((b) => b.id);
  const prod: Row[] = [["รหัส", "บาร์โค้ด", "ชื่อสินค้า", "ประเภท", "หน่วย", "ราคาขาย", "ราคาส่ง", "ต้นทุน", "ขายที่ร้าน", ...branches.map((b) => "สต็อก " + bname[b]), "สต็อกรวม", "แจ้งเตือนเมื่อต่ำกว่า"]];
  rows.products.forEach(({ id, data: p }) => {
    const st = (p.stock || {}) as Record<string, number>;
    const shops = Array.isArray(p.shops) && p.shops.length ? (p.shops as string[]).map((b) => bname[b] || b).join(", ") : "ทุกร้าน";
    prod.push([id, String(p.barcode || ""), String(p.name || ""), String(p.cat || ""), String(p.unit || ""), Number(p.price) || 0, Number(p.price2) || "", Number(p.cost) || 0, shops,
      ...branches.map((b) => Number(st[b]) || 0), Object.values(st).reduce((a, n) => a + (Number(n) || 0), 0), Number(p.min) || ""]);
  });
  const sales = rows.sales.slice().sort((a, b) => Number(b.data.ts || 0) - Number(a.data.ts || 0));
  const bills: Row[] = [["เลขที่", "วันเวลา", "ร้าน", "พนักงาน", "สมาชิก", "ยอดก่อนลด", "ส่วนลด", "สุทธิ", "VAT", "ต้นทุน", "กำไร", "ชำระด้วย", "เงินทอน", "สถานะ", "หมายเหตุ"]];
  const lines: Row[] = [["เลขที่บิล", "วันเวลา", "ร้าน", "รหัสสินค้า", "สินค้า", "หน่วย", "จำนวน", "ราคา", "ส่วนลด", "รวม", "ต้นทุน/หน่วย"]];
  sales.forEach(({ data: s }) => {
    const disc = (Number(s.billDisc) || 0) + ((s.promos as { amt: number }[] | undefined) || []).reduce((a, p) => a + (Number(p.amt) || 0), 0) + (Number((s.reward as { value?: number } | undefined)?.value) || 0);
    const pay = ((s.pay as { m: string; amt: number }[] | undefined) || []).map((p) => (PAY[p.m] || p.m) + " " + p.amt).join(", ");
    bills.push([String(s.no || ""), D(s.ts), bname[String(s.branch)] || String(s.branch || ""), sname[String(s.staffId)] || "", mname[String(s.memberId)] || "", Number(s.sub) || 0, disc,
      Number(s.total) || 0, Number(s.vat) || 0, Number(s.cost) || 0, (Number(s.total) || 0) - (Number(s.cost) || 0), pay, Number(s.change) || 0, s.status === "void" ? "ยกเลิก" : "ชำระแล้ว", String(s.note || "")]);
    ((s.lines as Record<string, unknown>[] | undefined) || []).forEach((l) => lines.push([String(s.no || ""), D(s.ts), bname[String(s.branch)] || "", String(l.pid || l.id || ""), String(l.name || ""), String(l.unit || ""),
      Number(l.qty) || 0, Number(l.price) || 0, Number(l.disc) || 0, Number(l.total) || 0, Number(l.cost) || 0]));
  });
  const mem: Row[] = [["รหัส", "ชื่อ", "โทร", "แต้ม", "ยอดค้างชำระ", "ระดับราคา", "หมายเหตุ"]];
  rows.members.forEach(({ id, data: m }) => mem.push([id, String(m.name || ""), String(m.phone || ""), Number(m.points) || 0, Number(m.debt) || 0, String(m.level || ""), String(m.note || "")]));
  const info: Row[] = [["ร้าน", shop.name], ["อัปเดตล่าสุด", D(Date.now())], ["สินค้า", rows.products.length], ["บิลทั้งหมด", rows.sales.length], ["สมาชิก", rows.members.length],
    ["หมายเหตุ", "ไฟล์นี้ Easy POS เขียนทับทุกครั้งที่ซิงก์ แก้ไขข้อมูลที่หน้า POS"]];
  const TABS: [string, Row[]][] = [["ข้อมูลร้าน", info], ["สินค้า", prod], ["บิลขาย", bills], ["รายการขาย", lines], ["สมาชิก", mem]];

  try {
    const tok = await gToken(sa);
    const meta = await gapi(tok, "GET", sheet + "?fields=sheets.properties(title,sheetId)") as { sheets: { properties: { title: string } }[] };
    const have = new Set(meta.sheets.map((s) => s.properties.title));
    const add = TABS.filter(([t]) => !have.has(t)).map(([t]) => ({ addSheet: { properties: { title: t, gridProperties: { frozenRowCount: 1 } } } }));
    if (add.length) await gapi(tok, "POST", sheet + ":batchUpdate", { requests: add });
    await gapi(tok, "POST", sheet + "/values:batchClear", { ranges: TABS.map(([t]) => `'${t}'`) });
    await gapi(tok, "POST", sheet + "/values:batchUpdate", { valueInputOption: "RAW", data: TABS.map(([t, v]) => ({ range: `'${t}'!A1`, values: v })) });
    await db.from("pos_shops").update({ sheet_synced_at: new Date().toISOString(), sheet_error: null }).eq("id", sid);
    return json({ ok: true, counts: { products: rows.products.length, bills: rows.sales.length, members: rows.members.length } });
  } catch (e) {
    const st = (e as { status?: number }).status;
    const code = st === 403 || st === 404 ? "no_access" : /google_auth/.test(String(e)) ? "google_auth" : "sheets_error";
    const msg = String((e as Error).message || e).slice(0, 300);
    await db.from("pos_shops").update({ sheet_error: code + ": " + msg }).eq("id", sid);
    return fail(code, 400, { message: msg, email: sa.client_email });
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return fail("method", 405);
  let b: Record<string, string>;
  try { b = await req.json(); } catch (_) { return fail("bad_json"); }
  try {
    const me = await caller(req);
    if (!me) return fail("unauthorized", 401);
    const { data: adm } = await db.from("pos_admins").select("email").ilike("email", me).maybeSingle();
    if (b.action === "info") { const sa = await saKey(); return json({ email: sa?.client_email || null }); }
    if (b.action === "sync") {
      let sid = String(b.sid || "");
      if (!adm) {
        const { data: m } = await db.from("pos_members").select("shop_id,active").eq("email", me).maybeSingle();
        if (!m || !m.active) return fail("forbidden", 403);
        if (sid && sid !== m.shop_id) return fail("forbidden", 403);
        sid = m.shop_id;
        // Shops can ask at most once every 2 minutes; the admin any time.
        const { data: s } = await db.from("pos_shops").select("sheet_synced_at").eq("id", sid).maybeSingle();
        if (s?.sheet_synced_at && Date.now() - new Date(s.sheet_synced_at).getTime() < 120e3) return json({ ok: true, skipped: true });
      }
      if (!sid) return fail("no_shop");
      return await sync(sid);
    }
    return fail("bad_action");
  } catch (e) { console.error(e); return fail("server_error", 500); }
});
