// Shop sign-up: create the login, store the application, take the payment slip, and send e-mails.
// E-mail goes out through Resend when RESEND_API_KEY is set (MAIL_FROM optional); otherwise it is skipped.
import { createClient } from "jsr:@supabase/supabase-js@2";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND = Deno.env.get("RESEND_API_KEY") || "";
const FROM = Deno.env.get("MAIL_FROM") || "POS คาเฟ่ <onboarding@resend.dev>";
const APP = (Deno.env.get("APP_URL") || "https://cafe-order-umber.vercel.app").replace(/\/$/, "");
const db = createClient(SB_URL, SERVICE, { auth: { persistSession: false } });

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const fail = (code: string, s = 400) => json({ error: code }, s);
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const baht = (n: number) => "฿" + Number(n || 0).toLocaleString("en-US");
const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

async function mail(to: string | string[], subject: string, body: string): Promise<boolean> {
  if (!RESEND) return false;
  const html = `<div style="font-family:Tahoma,sans-serif;font-size:15px;line-height:1.6;color:#1F2A37;max-width:560px;margin:auto">
    <div style="background:#2F6FB0;color:#fff;padding:14px 18px;border-radius:12px 12px 0 0;font-weight:700">POS คาเฟ่</div>
    <div style="border:1px solid #E1E8F0;border-top:0;padding:18px;border-radius:0 0 12px 12px">${body}</div></div>`;
  try {
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: FROM, to: Array.isArray(to) ? to : [to], subject, html }),
    });
    return r.ok;
  } catch (_) { return false; }
}
// Encrypted password copies so platform admins can look up any account's password.
let KEY: CryptoKey | null = null;
async function credKey() {
  if (KEY) return KEY;
  const raw = Deno.env.get("CRED_KEY") || ("pos-cred:" + SERVICE);
  const h = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(raw));
  KEY = await crypto.subtle.importKey("raw", h, "AES-GCM", false, ["encrypt", "decrypt"]);
  return KEY;
}
const b64 = (u: Uint8Array) => btoa(String.fromCharCode(...u));
const unb64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
async function remember(email: string, pw: string, source: string) {
  try {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await credKey(), new TextEncoder().encode(pw)));
    await db.from("pos_creds").upsert({ email: email.toLowerCase(), ct: b64(ct), iv: b64(iv), source, updated_at: new Date().toISOString() });
  } catch (e) { console.log("remember failed", String(e)); }
}
async function reveal(ct: string, iv: string): Promise<string | null> {
  try { return new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: unb64(iv) }, await credKey(), unb64(ct))); } catch (_) { return null; }
}
async function isAdmin(req: Request) {
  const me = await caller(req);
  if (!me) return false;
  const { data } = await db.from("pos_admins").select("email").ilike("email", me).maybeSingle();
  return !!data;
}
async function creds(req: Request, b: Record<string, string>) {
  if (!(await isAdmin(req))) return fail("forbidden", 403);
  let emails: string[] | null = null;
  if (b.sid) { const { data } = await db.from("pos_members").select("email").eq("shop_id", b.sid); emails = (data || []).map((x: { email: string }) => x.email); }
  let q = db.from("pos_creds").select("email,ct,iv,updated_at,source");
  if (emails) q = q.in("email", emails.length ? emails : ["-"]);
  const { data } = await q;
  const out: Record<string, { password: string | null; updated_at: string; source: string }> = {};
  for (const r of data || []) out[r.email] = { password: await reveal(r.ct, r.iv), updated_at: r.updated_at, source: r.source };
  return json({ creds: out });
}
// After a successful sign-in the client sends the password it used; it is checked against Auth before being stored.
async function rememberLogin(req: Request, b: Record<string, string>) {
  const me = await caller(req);
  const pw = String(b.password || "");
  if (!me || !pw) return fail("unauthorized", 401);
  const { data: mem } = await db.from("pos_members").select("email").eq("email", me).maybeSingle();
  const { data: adm } = await db.from("pos_admins").select("email").ilike("email", me).maybeSingle();
  if (!mem && !adm) return json({ ok: false });
  const { data: old } = await db.from("pos_creds").select("ct,iv").eq("email", me).maybeSingle();
  if (old && (await reveal(old.ct, old.iv)) === pw) return json({ ok: true });
  const anon = createClient(SB_URL, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } });
  const chk = await anon.auth.signInWithPassword({ email: me, password: pw });
  if (chk.error) return fail("bad_password", 400);
  await remember(me, pw, "login");
  return json({ ok: true });
}
// Any signed-in user changes their own password (kept in step with the admin copy).
async function myPw(req: Request, b: Record<string, string>) {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: u } = await db.auth.getUser(jwt);
  if (!u?.user) return fail("unauthorized", 401);
  const pw = String(b.password || "");
  if (pw.length < 8) return fail("weak_password");
  const r = await db.auth.admin.updateUserById(u.user.id, { password: pw });
  if (r.error) return fail("auth_failed", 500);
  await remember(u.user.email || "", pw, "self");
  return json({ ok: true });
}

async function admins(): Promise<string[]> {
  const { data } = await db.from("pos_admins").select("email");
  return (data || []).map((x: { email: string }) => x.email);
}

async function apply(req: Request, b: Record<string, string>) {
  const f = {
    first: String(b.first_name || "").trim().slice(0, 60), last: String(b.last_name || "").trim().slice(0, 60),
    phone: String(b.phone || "").replace(/[^\d+]/g, "").slice(0, 15), address: String(b.address || "").trim().slice(0, 300),
    shop: String(b.shop_name || "").trim().slice(0, 80), email: String(b.email || "").trim().toLowerCase(),
    password: String(b.password || ""), pkg: String(b.package || ""),
  };
  const miss = !f.first ? "first_name" : !f.last ? "last_name" : f.phone.replace(/\D/g, "").length < 9 ? "phone" : !f.shop ? "shop_name" : f.address.length < 5 ? "address" : "";
  if (miss) { console.log("apply missing field", miss); return json({ error: "missing_fields", field: miss }, 400); }
  if (!EMAIL.test(f.email)) return fail("bad_email");
  if (f.password.length < 8) return fail("weak_password");
  const { data: plat } = await db.from("pos_platform").select("data").eq("key", "billing").maybeSingle();
  const pk = ((plat?.data?.packages || []) as Record<string, unknown>[]).find((p) => p.id === f.pkg);
  if (!pk) return fail("bad_package");
  const { data: mem } = await db.from("pos_members").select("email").eq("email", f.email).maybeSingle();
  if (mem) return fail("already_member");
  const { data: pend } = await db.from("pos_applications").select("id").ilike("email", f.email).eq("status", "pending").limit(1);
  if (pend && pend.length) return fail("already_pending");
  const { count } = await db.from("pos_applications").select("id", { count: "exact", head: true }).gt("created_at", new Date(Date.now() - 3600e3).toISOString());
  if ((count || 0) > 30) return fail("busy", 429);

  // An existing account applies while signed in (the page signs in first when the e-mail already has an account).
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  let signedIn = false;
  if (jwt && jwt.split(".").length === 3) {
    const { data: u } = await db.auth.getUser(jwt);
    signedIn = (u?.user?.email || "").toLowerCase() === f.email;
  }
  if (!signedIn) {
    const cu = await db.auth.admin.createUser({ email: f.email, password: f.password, email_confirm: true, user_metadata: { name: `${f.first} ${f.last}`, phone: f.phone } });
    if (cu.error) { console.log("createUser", cu.error.message); return fail(/already|registered|exists/i.test(cu.error.message) ? "email_exists" : "auth_failed"); }
    await remember(f.email, f.password, "signup");
  }

  const { data: app, error } = await db.from("pos_applications").insert({
    first_name: f.first, last_name: f.last, phone: f.phone, address: f.address, shop_name: f.shop, email: f.email, package: pk, amount: Number(pk.price) || 0,
  }).select("id,token,amount,package").single();
  if (error) { console.log("insert", error.message); return fail("save_failed", 500); }

  await mail(f.email, `ได้รับคำขอเปิดร้าน ${f.shop} แล้ว`,
    `<p>สวัสดีคุณ ${esc(f.first)}</p><p>เราได้รับคำขอเปิดร้าน <b>${esc(f.shop)}</b> แล้ว</p>
     <p>แพ็กเกจ: <b>${esc(pk.name)}</b> (${esc(pk.months)} เดือน) · ยอดชำระ <b>${baht(Number(pk.price))}</b></p>
     <p>หากยังไม่ได้แนบสลิป เข้าไปแนบได้ที่ <a href="${APP}/signup?id=${app.id}&t=${app.token}">${APP}/signup</a></p>
     <p>เมื่อผู้ดูแลระบบอนุมัติ เราจะส่งอีเมลยืนยันอีกครั้ง จากนั้นเข้าใช้งานที่ <a href="${APP}/pos">${APP}/pos</a> ด้วยอีเมลและรหัสผ่านที่ตั้งไว้</p>`);
  const ad = await admins();
  if (ad.length) await mail(ad, `คำขอเปิดร้านใหม่: ${f.shop}`,
    `<p><b>${esc(f.shop)}</b> · ${esc(f.first)} ${esc(f.last)} · ${esc(f.phone)} · ${esc(f.email)}</p><p>${esc(f.address)}</p>
     <p>แพ็กเกจ ${esc(pk.name)} · ${baht(Number(pk.price))}</p><p><a href="${APP}/admin#apps">เปิดแดชบอร์ดผู้ดูแลระบบ</a></p>`);
  return json({ id: app.id, token: app.token, amount: app.amount, package: app.package, mail: !!RESEND });
}

async function slip(b: Record<string, string>) {
  const { data: a } = await db.from("pos_applications").select("id,token,status,shop_name,email,amount").eq("id", b.id).maybeSingle();
  if (!a || a.token !== b.token) return fail("not_found", 404);
  if (a.status !== "pending") return fail("not_pending");
  const m = String(b.image || "").match(/^data:image\/(jpeg|png|webp);base64,([A-Za-z0-9+/=]+)$/);
  if (!m) return fail("bad_image");
  const bytes = Uint8Array.from(atob(m[2]), (c) => c.charCodeAt(0));
  if (bytes.length > 4 * 1024 * 1024) return fail("too_large");
  const path = `apply/${a.id}/${Date.now()}.${m[1] === "jpeg" ? "jpg" : m[1]}`;
  const up = await db.storage.from("pos-slips").upload(path, bytes, { contentType: `image/${m[1]}`, upsert: false });
  if (up.error) { console.log("upload", up.error.message); return fail("upload_failed", 500); }
  await db.from("pos_applications").update({ slip: path }).eq("id", a.id);
  const ad = await admins();
  if (ad.length) await mail(ad, `สลิปคำขอเปิดร้าน: ${a.shop_name}`, `<p>ร้าน <b>${esc(a.shop_name)}</b> แนบสลิป ${baht(Number(a.amount))} แล้ว</p><p><a href="${APP}/admin#apps">ตรวจและอนุมัติ</a></p>`);
  return json({ ok: true });
}

async function notify(req: Request, b: Record<string, string>) {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: u } = await db.auth.getUser(jwt);
  const email = u?.user?.email?.toLowerCase();
  if (!email) return fail("unauthorized", 401);
  const { data: isAdm } = await db.from("pos_admins").select("email").ilike("email", email).maybeSingle();
  if (!isAdm) return fail("forbidden", 403);
  const { data: a } = await db.from("pos_applications").select("*").eq("id", b.id).maybeSingle();
  if (!a) return fail("not_found", 404);
  let sent = false;
  if (a.status === "approved") {
    const { data: s } = await db.from("pos_shops").select("slug,expires_at").eq("id", a.shop_id).maybeSingle();
    sent = await mail(a.email, `อนุมัติเปิดร้าน ${a.shop_name} แล้ว`,
      `<p>สวัสดีคุณ ${esc(a.first_name)}</p><p>ร้าน <b>${esc(a.shop_name)}</b> ได้รับการอนุมัติแล้ว ใช้งานได้ถึง ${new Date(s?.expires_at || Date.now()).toLocaleDateString("th-TH", { dateStyle: "long" })}</p>
       <p>เข้าใช้งาน POS: <a href="${APP}/pos">${APP}/pos</a> ด้วยอีเมล ${esc(a.email)} และรหัสผ่านที่ตั้งไว้ตอนสมัคร</p>
       <p>ลิงก์สั่งอาหารของลูกค้า: <a href="${APP}/s/${s?.slug}">${APP}/s/${esc(s?.slug)}</a></p>${a.admin_note ? `<p>หมายเหตุ: ${esc(a.admin_note)}</p>` : ""}`);
  } else if (a.status === "rejected") {
    sent = await mail(a.email, `คำขอเปิดร้าน ${a.shop_name} ยังไม่ได้รับการอนุมัติ`,
      `<p>สวัสดีคุณ ${esc(a.first_name)}</p><p>คำขอเปิดร้าน <b>${esc(a.shop_name)}</b> ยังไม่ได้รับการอนุมัติ</p>${a.admin_note ? `<p>เหตุผล: ${esc(a.admin_note)}</p>` : ""}<p>ติดต่อผู้ดูแลระบบหากมีข้อสงสัย</p>`);
  }
  return json({ sent, mail: !!RESEND });
}

// Admin sets a new password for a shop account; an encrypted copy is kept for the admin.
async function setPassword(req: Request, b: Record<string, string>) {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: u } = await db.auth.getUser(jwt);
  const admin = u?.user?.email?.toLowerCase();
  if (!admin) return fail("unauthorized", 401);
  const { data: isAdm } = await db.from("pos_admins").select("email").ilike("email", admin).maybeSingle();
  if (!isAdm) return fail("forbidden", 403);
  const email = String(b.email || "").trim().toLowerCase();
  if (!EMAIL.test(email)) return fail("bad_email");
  const { data: mem } = await db.from("pos_members").select("email").eq("email", email).maybeSingle();
  if (!mem) return fail("not_member");
  let pw = String(b.password || "");
  if (!pw) {
    const abc = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";
    const r = crypto.getRandomValues(new Uint32Array(10));
    pw = Array.from(r, (x) => abc[x % abc.length]).join("");
  }
  if (pw.length < 8) return fail("weak_password");
  const { data: uid } = await db.rpc("pos_auth_user_id", { p_email: email });
  let created = false;
  if (uid) {
    const up = await db.auth.admin.updateUserById(uid as string, { password: pw });
    if (up.error) { console.log("updateUser", up.error.message); return fail("auth_failed", 500); }
  } else {
    const cu = await db.auth.admin.createUser({ email, password: pw, email_confirm: true });
    if (cu.error) { console.log("createUser", cu.error.message); return fail("auth_failed", 500); }
    created = true;
  }
  await remember(email, pw, "admin");
  console.log("password set by admin for a shop account");
  return json({ ok: true, password: pw, created });
}

// Shop managers create staff logins with a username + password (no e-mail); the login e-mail is internal.
const STAFF_DOMAIN = "staff.cafe-pos.app";
const USERNAME = /^[a-z0-9][a-z0-9._-]{2,29}$/;
async function caller(req: Request) {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: u } = await db.auth.getUser(jwt);
  return u?.user?.email?.toLowerCase() || "";
}
async function managerShop(req: Request, b: Record<string, string>): Promise<{ sid: string } | Response> {
  const me = await caller(req);
  if (!me) return fail("unauthorized", 401);
  const { data: adm } = await db.from("pos_admins").select("email").ilike("email", me).maybeSingle();
  if (adm && b.sid) return { sid: b.sid };
  const { data: m } = await db.from("pos_members").select("shop_id,role,active").eq("email", me).maybeSingle();
  if (!m || !m.active || m.role !== "manager") return fail("forbidden", 403);
  const { data: locked } = await db.rpc("pos_shop_locked", { p_sid: m.shop_id });
  if (locked) return fail("locked", 403);
  return { sid: m.shop_id };
}
async function authId(email: string): Promise<string | null> {
  const { data } = await db.rpc("pos_auth_user_id", { p_email: email });
  return (data as string) || null;
}
async function staffAdd(req: Request, b: Record<string, string>) {
  const ms = await managerShop(req, b); if (ms instanceof Response) return ms;
  // Every username starts with the shop's 3-letter prefix; the manager only chooses the part after it.
  const { data: shop } = await db.from("pos_shops").select("user_prefix").eq("id", ms.sid).maybeSingle();
  const prefix = String(shop?.user_prefix || "").toLowerCase();
  if (!/^[a-z]{3}$/.test(prefix)) return fail("no_prefix", 500);
  let suffix = String(b.suffix ?? b.username ?? "").trim().toLowerCase();
  if (suffix.startsWith(prefix) && b.suffix == null) suffix = suffix.slice(3);
  if (!/^[a-z0-9._-]{1,27}$/.test(suffix)) return fail("bad_username");
  const username = prefix + suffix;
  const name = String(b.name || "").trim().slice(0, 60) || null;
  const pw = String(b.password || "");
  if (!USERNAME.test(username)) return fail("bad_username");
  if (pw.length < 6) return fail("weak_password");
  const email = `${username}@${STAFF_DOMAIN}`;
  const { data: t1 } = await db.from("pos_members").select("email").eq("email", email).limit(1);
  const { data: t2 } = await db.from("pos_members").select("email").ilike("username", username).limit(1);
  if ((t1 && t1.length) || (t2 && t2.length)) return fail("username_taken");
  if (await authId(email)) return fail("username_taken");
  const ins = await db.from("pos_members").insert({ email, username, name, role: "staff", active: true, shop_id: ms.sid });
  if (ins.error) return fail(/staff_limit/.test(ins.error.message) ? "staff_limit" : /duplicate|unique/.test(ins.error.message) ? "username_taken" : "save_failed");
  const cu = await db.auth.admin.createUser({ email, password: pw, email_confirm: true, user_metadata: { name, username } });
  if (cu.error) { console.log("createUser", cu.error.message); await db.from("pos_members").delete().eq("email", email); return fail("auth_failed", 500); }
  await remember(email, pw, "manager");
  return json({ ok: true, username });
}
async function staffTarget(req: Request, b: Record<string, string>) {
  const ms = await managerShop(req, b); if (ms instanceof Response) return ms;
  const { data: t } = await db.from("pos_members").select("email,role,shop_id").eq("email", String(b.email || "").toLowerCase()).maybeSingle();
  if (!t || t.shop_id !== ms.sid || t.role !== "staff") return fail("not_found", 404);
  return t;
}
async function staffPw(req: Request, b: Record<string, string>) {
  const t = await staffTarget(req, b); if (t instanceof Response) return t;
  const pw = String(b.password || "");
  if (pw.length < 6) return fail("weak_password");
  const id = await authId(t.email);
  const r = id ? await db.auth.admin.updateUserById(id, { password: pw }) : await db.auth.admin.createUser({ email: t.email, password: pw, email_confirm: true });
  if (r.error) { console.log("staffPw", r.error.message); return fail("auth_failed", 500); }
  await remember(t.email, pw, "manager");
  return json({ ok: true });
}
async function staffDel(req: Request, b: Record<string, string>) {
  const t = await staffTarget(req, b); if (t instanceof Response) return t;
  await db.from("pos_members").delete().eq("email", t.email);
  if (t.email.endsWith("@" + STAFF_DOMAIN)) { const id = await authId(t.email); if (id) await db.auth.admin.deleteUser(id); await db.from("pos_creds").delete().eq("email", t.email); }
  return json({ ok: true });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return fail("method", 405);
  let b: Record<string, string>;
  try { b = await req.json(); } catch (_) { return fail("bad_json"); }
  try {
    if (b.action === "apply") return await apply(req, b);
    if (b.action === "slip") return await slip(b);
    if (b.action === "notify") return await notify(req, b);
    if (b.action === "setpw") return await setPassword(req, b);
    if (b.action === "staff_add") return await staffAdd(req, b);
    if (b.action === "staff_pw") return await staffPw(req, b);
    if (b.action === "staff_del") return await staffDel(req, b);
    if (b.action === "creds") return await creds(req, b);
    if (b.action === "remember") return await rememberLogin(req, b);
    if (b.action === "my_pw") return await myPw(req, b);
    return fail("bad_action");
  } catch (e) {
    console.error(e);
    return fail("server_error", 500);
  }
});
