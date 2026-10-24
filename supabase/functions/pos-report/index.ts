// Daily sales report by e-mail for Coconut POS shops (Cafe and Retail).
// - Hourly (pg_cron + pg_net, header x-cron-key = pos_secrets.REPORT_CRON_KEY): sends today's summary to every shop
//   whose settings have rptOn, rptTo (e-mails) and rptHour equal to the current hour in Bangkok.
// - A shop manager (signed in) can send a test now: POST {action:"test"} with their access token.
// Mail goes out like pos-signup: Gmail SMTP (GMAIL_USER/GMAIL_APP_PASSWORD) or Resend, keys from env or pos_secrets.
import { createClient } from "jsr:@supabase/supabase-js@2";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const FROM = Deno.env.get("MAIL_FROM") || "Coconut POS <onboarding@resend.dev>";
const db = createClient(SB_URL, SERVICE, { auth: { persistSession: false } });

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-key",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const fail = (code: string, s = 400) => json({ error: code }, s);
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const baht = (n: number) => "฿" + Number(n || 0).toLocaleString("en-US", { maximumFractionDigits: 2 });
const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

let RESEND = Deno.env.get("RESEND_API_KEY") || "", GUSER = "", GPASS = "", keyLoaded = false;
async function secret(k: string) { const { data } = await db.from("pos_secrets").select("value").eq("key", k).maybeSingle(); return (data?.value as string) || ""; }
async function mailOn() {
  if (!keyLoaded) {
    if (!RESEND) RESEND = await secret("RESEND_API_KEY");
    GUSER = Deno.env.get("GMAIL_USER") || await secret("GMAIL_USER");
    GPASS = (Deno.env.get("GMAIL_APP_PASSWORD") || await secret("GMAIL_APP_PASSWORD")).replace(/\s+/g, "");
    keyLoaded = true;
  }
  return !!(RESEND || (GUSER && GPASS));
}
async function mail(to: string[], subject: string, body: string): Promise<boolean> {
  if (!(await mailOn())) return false;
  const subj = subject.replace(/[\r\n]+/g, " ").replace(/\s+/g, " ").trim().slice(0, 150) || "Coconut POS";
  const html = `<div><h3>Coconut POS</h3>${body}</div>`;
  if (GUSER && GPASS) {
    try {
      const nm = (await import("npm:nodemailer@6.9.16")).default;
      const t = nm.createTransport({ host: "smtp.gmail.com", port: 465, secure: true, auth: { user: GUSER, pass: GPASS } });
      await t.sendMail({ from: `"Coconut POS" <${GUSER}>`, to: to.join(", "), subject: subj, html });
      return true;
    } catch (e) { console.log("gmail smtp error", String(e)); }
  }
  if (!RESEND) return false;
  try {
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST", headers: { Authorization: `Bearer ${RESEND}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: FROM, to, subject: subj, html }),
    });
    if (!r.ok) console.log("resend", r.status, await r.text());
    return r.ok;
  } catch (e) { console.log("resend error", String(e)); return false; }
}

// Bangkok is UTC+7 all year.
const BKK = 7 * 3600e3;
function bkkDay(now = Date.now()) {
  const local = new Date(now + BKK);
  const start = Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate()) - BKK;
  return { start, end: start + 86400e3, hour: local.getUTCHours(), label: `${local.getUTCDate()}/${local.getUTCMonth() + 1}/${local.getUTCFullYear() + 543}` };
}
const MLABEL: Record<string, string> = { cash: "เงินสด", qr: "QR พร้อมเพย์", promptpay: "QR พร้อมเพย์", card: "บัตรเครดิต", bank: "โอนเงิน", transfer: "โอนเงิน", invoice: "ขายเชื่อ", other: "อื่นๆ" };

async function settingsOf(shopId: string) {
  const { data } = await db.from("pos_data").select("id,data").eq("shop_id", shopId).eq("col", "settings").in("id", ["shop", "main"]);
  const row = (data || []).find((x) => x.id === "shop") || (data || [])[0];
  return (row?.data || {}) as Record<string, unknown>;
}
function recipients(v: unknown) { return String(v || "").split(/[,;\s]+/).map((x) => x.trim().toLowerCase()).filter((x) => EMAIL.test(x)).slice(0, 5); }

async function sendFor(shop: { id: string; name: string; product: string }, st: Record<string, unknown>, to: string[], test = false) {
  const d = bkkDay();
  const { data: r, error } = await db.rpc("pos_day_report", { p_shop: shop.id, p_from: d.start, p_to: d.end });
  if (error) { console.log("report", error.message); return false; }
  const rep = r as { bills: number; total: number; voids: number; methods: Record<string, number>; top: { name: string; qty: number }[] };
  const name = String(st.name || st.shop || shop.name || "ร้านของคุณ");
  const rows = Object.entries(rep.methods || {}).map(([m, v]) => `<tr><td>${esc(MLABEL[m] || m)}</td><td align="right">${baht(v)}</td></tr>`).join("");
  const top = (rep.top || []).map((x, i) => `<tr><td>${i + 1}. ${esc(x.name)}</td><td align="right">${Number(x.qty).toLocaleString("en-US")}</td></tr>`).join("");
  const body = `<p>สรุปยอดขาย <b>${esc(name)}</b> วันที่ ${d.label}${test ? " (ส่งทดสอบ ยอดถึงเวลาที่ส่ง)" : ""}</p>
    <table cellpadding="6" style="border-collapse:collapse">
      <tr><td>ยอดขายสุทธิ</td><td align="right"><b>${baht(rep.total)}</b></td></tr>
      <tr><td>จำนวนบิล</td><td align="right">${rep.bills}</td></tr>
      <tr><td>เฉลี่ยต่อบิล</td><td align="right">${baht(rep.bills ? Math.round(rep.total / rep.bills) : 0)}</td></tr>
      <tr><td>บิลที่ทำลาย</td><td align="right">${rep.voids}</td></tr></table>
    ${rows ? `<p><b>ช่องทางการชำระเงิน</b></p><table cellpadding="6">${rows}</table>` : ""}
    ${top ? `<p><b>${shop.product === "retail" ? "สินค้าขายดี" : "เมนูขายดี"}</b></p><table cellpadding="6">${top}</table>` : "<p>วันนี้ยังไม่มียอดขาย</p>"}
    <p style="color:#666">ตั้งค่าการส่งรายงานได้ที่หน้าตั้งค่าของร้านใน Coconut POS</p>`;
  return await mail(to, `สรุปยอดขาย ${name} ${d.label} · ${baht(rep.total)}`, body);
}

async function runHour() {
  const d = bkkDay();
  const { data: shops } = await db.from("pos_shops").select("id,name,product,status").neq("status", "suspended");
  let sent = 0, due = 0;
  for (const s of shops || []) {
    const st = await settingsOf(s.id);
    if (!st.rptOn || Number(st.rptHour ?? 22) !== d.hour) continue;
    const to = recipients(st.rptTo);
    if (!to.length) continue;
    due++;
    if (await sendFor(s, st, to)) sent++;
  }
  return { hour: d.hour, due, sent };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const cron = req.headers.get("x-cron-key") || "";
    if (cron) {
      const k = await secret("REPORT_CRON_KEY");
      if (!k || k !== cron) return fail("forbidden", 403);
      return json(await runHour());
    }
    const b = await req.json().catch(() => ({}));
    if (b.action !== "test") return fail("bad_action");
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: u } = await db.auth.getUser(jwt);
    const email = u?.user?.email?.toLowerCase();
    if (!email) return fail("unauthorized", 401);
    const { data: mem } = await db.from("pos_members").select("shop_id,role,active").eq("email", email).eq("active", true).maybeSingle();
    if (!mem || mem.role !== "manager") return fail("forbidden", 403);
    const { data: shop } = await db.from("pos_shops").select("id,name,product,status").eq("id", mem.shop_id).maybeSingle();
    if (!shop) return fail("not_found", 404);
    const st = await settingsOf(shop.id);
    const to = recipients(b.to || st.rptTo);
    if (!to.length) return fail("no_recipient");
    if (!(await mailOn())) return fail("mail_off", 503);
    const ok = await sendFor(shop, st, to, true);
    return ok ? json({ ok: true, to }) : fail("send_failed", 502);
  } catch (e) {
    console.log("pos-report", String(e));
    return fail("server_error", 500);
  }
});
