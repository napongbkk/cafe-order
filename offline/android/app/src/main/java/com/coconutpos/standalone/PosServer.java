package com.coconutpos.standalone;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.URLDecoder;
import java.nio.charset.Charset;
import java.security.SecureRandom;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Date;
import java.util.Enumeration;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TimeZone;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Pattern;

/**
 * Coconut POS Stand alone local server (Android / plain Java). Same HTTP API as offline/server/server.js
 * (see offline/API.md): serves the POS app to every device on the Wi-Fi/LAN and keeps the shop's data here.
 */
public final class PosServer {
  /** Where the app's web files come from (Android assets, or a folder when testing). */
  public interface Files { InputStream open(String path) throws IOException; }

  public static final String VERSION = "1.0.0";
  private static final Charset UTF8 = Charset.forName("UTF-8");
  private static final Pattern NAME_RE = Pattern.compile("^[A-Za-z0-9_.:-]{1,128}$");
  private static final Pattern FIELD_RE = Pattern.compile("^[A-Za-z0-9_]{1,64}(\\.[A-Za-z0-9_]{1,64}){0,3}$");
  private static final Pattern ASSET_RE = Pattern.compile("^[a-f0-9]{20}\\.[a-z0-9]{2,5}$");
  private static final List<String> OPS = Arrays.asList("==", "!=", ">", ">=", "<", "<=", "in");
  private static final Map<String, String> MIME = new LinkedHashMap<>();
  private static final Map<String, String> EXT = new LinkedHashMap<>();
  static {
    MIME.put("html", "text/html; charset=utf-8"); MIME.put("js", "text/javascript; charset=utf-8"); MIME.put("css", "text/css; charset=utf-8");
    MIME.put("json", "application/json"); MIME.put("svg", "image/svg+xml"); MIME.put("png", "image/png"); MIME.put("jpg", "image/jpeg");
    MIME.put("jpeg", "image/jpeg"); MIME.put("webp", "image/webp"); MIME.put("gif", "image/gif"); MIME.put("ico", "image/x-icon");
    MIME.put("woff2", "font/woff2"); MIME.put("mp4", "video/mp4"); MIME.put("webm", "video/webm"); MIME.put("mov", "video/quicktime");
    EXT.put("image/jpeg", "jpg"); EXT.put("image/png", "png"); EXT.put("image/webp", "webp"); EXT.put("image/gif", "gif");
    EXT.put("video/mp4", "mp4"); EXT.put("video/webm", "webm"); EXT.put("video/quicktime", "mov");
  }

  private final File dataDir, assetDir, backupDir;
  private final Files www;
  private final String platform, deviceName, hostScript;
  private final int port;
  private final Store store;
  private final String deviceId;
  private final long started = System.currentTimeMillis();
  private long seq;
  private final List<long[]> changes = new ArrayList<>(); // [seq, colIndex]
  private final List<String> colNames = new ArrayList<>();
  private final Object lock = new Object();
  private ServerSocket server;
  private ExecutorService pool;
  private volatile boolean running;
  private long lastBackupDay = -1;

  public PosServer(File dataDir, Files www, int port, String platform, String deviceName, String hostScript) throws IOException {
    this.dataDir = dataDir; this.www = www; this.port = port; this.platform = platform; this.deviceName = deviceName; this.hostScript = hostScript;
    assetDir = new File(dataDir, "assets"); assetDir.mkdirs();
    backupDir = new File(dataDir, "backups"); backupDir.mkdirs();
    store = new Store(dataDir);
    String id = store.meta("deviceId");
    if (id == null) { byte[] b = new byte[9]; new SecureRandom().nextBytes(b); id = "srv" + hex(b); store.setMeta("deviceId", id); }
    deviceId = id;
    String s = store.meta("seq");
    seq = s == null ? 0 : (long) Double.parseDouble(s);
  }

  public int port() { return port; }

  public void start() throws IOException {
    server = new ServerSocket();
    server.setReuseAddress(true);
    server.bind(new InetSocketAddress("0.0.0.0", port));
    running = true;
    pool = Executors.newCachedThreadPool();
    Thread t = new Thread(new Runnable() { public void run() { acceptLoop(); } }, "coconut-accept");
    t.setDaemon(true); t.start();
    backup();
  }

  public void stop() {
    running = false;
    synchronized (lock) { lock.notifyAll(); }
    try { if (server != null) server.close(); } catch (IOException e) { /* ignore */ }
    if (pool != null) pool.shutdownNow();
    store.close();
  }

  private void acceptLoop() {
    while (running) {
      try {
        final Socket s = server.accept();
        pool.execute(new Runnable() { public void run() { serve(s); } });
      } catch (IOException e) { if (!running) return; }
    }
  }

  // ---------- data ----------
  private long bump(String col) {
    synchronized (lock) {
      seq++; store.setMeta("seq", String.valueOf(seq));
      int ci = colNames.indexOf(col); if (ci < 0) { colNames.add(col); ci = colNames.size() - 1; }
      changes.add(new long[] {seq, ci});
      if (changes.size() > 2000) changes.subList(0, changes.size() - 2000).clear();
      lock.notifyAll();
      return seq;
    }
  }

  private Object since(long n) {
    synchronized (lock) {
      if (n > seq || (!changes.isEmpty() && n < changes.get(0)[0] - 1) || (changes.isEmpty() && n < seq)) return null;
      LinkedHashSet<String> out = new LinkedHashSet<>();
      for (long[] c : changes) if (c[0] > n) out.add(colNames.get((int) c[1]));
      return new ArrayList<Object>(out);
    }
  }

  @SuppressWarnings("unchecked")
  static Object merge(Object a, Object b) {
    if (a instanceof Map && b instanceof Map) {
      Map<String, Object> out = new LinkedHashMap<>((Map<String, Object>) a);
      for (Map.Entry<String, Object> e : ((Map<String, Object>) b).entrySet())
        out.put(e.getKey(), out.containsKey(e.getKey()) ? merge(out.get(e.getKey()), e.getValue()) : e.getValue());
      return out;
    }
    return b;
  }

  public Map<String, Object> info() {
    Map<String, Object> m = new LinkedHashMap<>();
    m.put("app", "coconut-pos-offline"); m.put("version", VERSION); m.put("deviceId", deviceId); m.put("name", deviceName);
    m.put("platform", platform); m.put("port", (long) port); m.put("lan", new ArrayList<Object>(lanAddresses()));
    synchronized (lock) { m.put("seq", seq); }
    m.put("started", started); m.put("storage", "file");
    return m;
  }

  public static List<String> lanAddresses() {
    List<String> out = new ArrayList<>();
    try {
      Enumeration<NetworkInterface> en = NetworkInterface.getNetworkInterfaces();
      if (en != null) for (NetworkInterface ni : Collections.list(en)) {
        if (!ni.isUp() || ni.isLoopback()) continue;
        for (InetAddress a : Collections.list(ni.getInetAddresses())) if (a instanceof Inet4Address && !a.isLoopbackAddress()) out.add(a.getHostAddress());
      }
    } catch (Exception e) { /* none */ }
    Collections.sort(out, new java.util.Comparator<String>() {
      public int compare(String a, String b) { return (b.startsWith("192.168.") ? 1 : 0) - (a.startsWith("192.168.") ? 1 : 0); }
    });
    return out;
  }

  private void backup() {
    try {
      SimpleDateFormat f = new SimpleDateFormat("yyyyMMdd", Locale.US); f.setTimeZone(TimeZone.getDefault());
      String stamp = f.format(new Date());
      long day = Long.parseLong(stamp);
      if (day == lastBackupDay) return;
      lastBackupDay = day;
      File file = new File(backupDir, "coconut-pos-" + stamp + ".json");
      if (!file.exists()) store.backupTo(file);
      String[] names = backupDir.list();
      if (names != null) {
        List<String> l = new ArrayList<>();
        for (String n : names) if (n.matches("^coconut-pos-\\d{8}\\.(db|json)$")) l.add(n);
        Collections.sort(l);
        while (l.size() > 14) new File(backupDir, l.remove(0)).delete();
      }
    } catch (Exception e) { /* try again next time */ }
  }

  // ---------- HTTP ----------
  private static final class Req {
    String method, path, query; Map<String, String> headers = new LinkedHashMap<>(); byte[] body = new byte[0];
    String param(String k) {
      if (query == null) return null;
      for (String kv : query.split("&")) {
        int i = kv.indexOf('='); String key = i < 0 ? kv : kv.substring(0, i);
        try { if (URLDecoder.decode(key, "UTF-8").equals(k)) return i < 0 ? "" : URLDecoder.decode(kv.substring(i + 1), "UTF-8"); }
        catch (Exception e) { return null; }
      }
      return null;
    }
  }

  private static String readLine(InputStream in) throws IOException {
    ByteArrayOutputStream b = new ByteArrayOutputStream(); int c;
    while ((c = in.read()) >= 0) { if (c == '\n') break; if (c != '\r') b.write(c); if (b.size() > 16384) throw new IOException("line too long"); }
    if (c < 0 && b.size() == 0) return null;
    return new String(b.toByteArray(), UTF8);
  }

  private void serve(Socket s) {
    try {
      s.setSoTimeout(70000);
      InputStream in = new BufferedInputStream(s.getInputStream());
      OutputStream out = s.getOutputStream();
      while (running) {
        String line;
        try { line = readLine(in); } catch (SocketTimeoutException e) { break; }
        if (line == null) break;
        if (line.isEmpty()) continue;
        String[] parts = line.split(" ");
        if (parts.length < 2) break;
        Req r = new Req(); r.method = parts[0];
        String target = parts[1]; int q = target.indexOf('?');
        r.path = q < 0 ? target : target.substring(0, q); r.query = q < 0 ? null : target.substring(q + 1);
        String h;
        while ((h = readLine(in)) != null && !h.isEmpty()) { int i = h.indexOf(':'); if (i > 0) r.headers.put(h.substring(0, i).trim().toLowerCase(Locale.US), h.substring(i + 1).trim()); }
        String cl = r.headers.get("content-length");
        long len = cl == null ? 0 : Long.parseLong(cl.trim());
        boolean big = r.path.equals("/api/asset");
        if (len > (big ? 60L * 1024 * 1024 : 20L * 1024 * 1024)) { respond(out, 413, "application/json", "{\"error\":\"too_large\"}".getBytes(UTF8), true, null); break; }
        if (len > 0) {
          byte[] b = new byte[(int) len]; int n = 0;
          while (n < len) { int k = in.read(b, n, (int) len - n); if (k < 0) break; n += k; }
          r.body = b;
        }
        boolean close = "close".equalsIgnoreCase(r.headers.get("connection"));
        try { handle(r, out, close); }
        catch (HttpError e) { respond(out, e.code, "application/json", ("{\"error\":\"" + e.getMessage() + "\"}").getBytes(UTF8), close, null); }
        catch (RuntimeException e) { respond(out, 500, "application/json", "{\"error\":\"server_error\"}".getBytes(UTF8), close, null); }
        if (close) break;
      }
    } catch (IOException e) { /* client went away */ }
    finally { try { s.close(); } catch (IOException e) { /* ignore */ } }
  }

  private static final class HttpError extends RuntimeException { final int code; HttpError(int c, String m) { super(m); code = c; } }

  private static void respond(OutputStream out, int code, String type, byte[] body, boolean close, Map<String, String> extra) throws IOException {
    StringBuilder h = new StringBuilder();
    h.append("HTTP/1.1 ").append(code).append(code == 200 ? " OK" : code == 404 ? " Not Found" : " Error").append("\r\n");
    h.append("Content-Type: ").append(type).append("\r\n");
    h.append("Content-Length: ").append(body.length).append("\r\n");
    if (extra != null) for (Map.Entry<String, String> e : extra.entrySet()) h.append(e.getKey()).append(": ").append(e.getValue()).append("\r\n");
    if (extra == null || !extra.containsKey("Cache-Control")) h.append("Cache-Control: no-store\r\n");
    h.append(close ? "Connection: close\r\n" : "Connection: keep-alive\r\n");
    h.append("\r\n");
    out.write(h.toString().getBytes(UTF8)); out.write(body); out.flush();
  }

  private static void json(OutputStream out, int code, Object o, boolean close) throws IOException {
    respond(out, code, "application/json", Json.str(o).getBytes(UTF8), close, null);
  }

  private static Map<String, Object> map(Object... kv) {
    Map<String, Object> m = new LinkedHashMap<>();
    for (int i = 0; i + 1 < kv.length; i += 2) m.put((String) kv[i], kv[i + 1]);
    return m;
  }

  private static Map<String, Object> bodyJson(Req r) {
    if (r.body.length == 0) return new LinkedHashMap<>();
    try { Map<String, Object> m = Json.obj(Json.parse(new String(r.body, UTF8))); if (m == null) throw new HttpError(400, "bad_json"); return m; }
    catch (IllegalArgumentException e) { throw new HttpError(400, "bad_json"); }
    catch (StringIndexOutOfBoundsException e) { throw new HttpError(400, "bad_json"); }
  }

  private void handle(Req r, OutputStream out, boolean close) throws IOException {
    String p;
    try { p = URLDecoder.decode(r.path.replace("+", "%2B"), "UTF-8"); } catch (Exception e) { throw new HttpError(400, "bad_path"); }
    List<String> seg = new ArrayList<>();
    for (String x : p.split("/")) if (!x.isEmpty()) seg.add(x);
    String m = r.method;
    if (!seg.isEmpty() && seg.get(0).equals("api")) {
      backup();
      String a = seg.size() > 1 ? seg.get(1) : "";
      if (a.equals("info") && m.equals("GET")) { json(out, 200, info(), close); return; }
      if (a.equals("col") && seg.size() == 3 && m.equals("GET")) {
        String col = seg.get(2); if (!NAME_RE.matcher(col).matches()) throw new HttpError(400, "bad_name");
        List<Object[]> where = new ArrayList<>(); String orderF = null; boolean desc = false;
        try {
          String w = r.param("w");
          if (w != null) for (Object x : Json.list(Json.parse(w))) {
            List<Object> c = new ArrayList<>(); for (Object y : Json.list(x)) c.add(y);
            if (c.size() != 3 || !(c.get(0) instanceof String) || !FIELD_RE.matcher((String) c.get(0)).matches()) throw new HttpError(400, "bad_field");
            if (!(c.get(1) instanceof String) || !OPS.contains(c.get(1))) continue;
            where.add(new Object[] {c.get(0), c.get(1), c.get(2)});
          }
          String o = r.param("o");
          if (o != null) { List<Object> c = new ArrayList<>(); for (Object y : Json.list(Json.parse(o))) c.add(y);
            if (c.size() >= 1 && c.get(0) instanceof String && FIELD_RE.matcher((String) c.get(0)).matches()) { orderF = (String) c.get(0); desc = c.size() > 1 && "desc".equals(c.get(1)); } }
        } catch (IllegalArgumentException e) { throw new HttpError(400, "bad_query"); }
        int lim = 50000; String l = r.param("l");
        if (l != null) { try { lim = Math.max(1, Math.min(50000, (int) Double.parseDouble(l))); } catch (NumberFormatException e) { /* default */ } }
        long sq; synchronized (lock) { sq = seq; }
        json(out, 200, map("seq", sq, "docs", store.query(col, where, orderF, desc, lim)), close); return;
      }
      if (a.equals("doc") && seg.size() == 4) {
        String col = seg.get(2), id = seg.get(3);
        if (!NAME_RE.matcher(col).matches() || !NAME_RE.matcher(id).matches()) throw new HttpError(400, "bad_name");
        if (m.equals("GET")) { json(out, 200, map("data", store.get(col, id)), close); return; }
        if (m.equals("PUT")) {
          Object d = bodyJson(r).get("data"); if (!(d instanceof Map)) throw new HttpError(400, "bad_data");
          long sq; synchronized (lock) { store.put(col, id, d); sq = bump(col); }
          json(out, 200, map("ok", true, "seq", sq), close); return;
        }
        if (m.equals("PATCH")) {
          Object patch = bodyJson(r).get("patch"); long sq; Object next;
          synchronized (lock) {
            Object cur = store.get(col, id); if (cur == null) throw new HttpError(404, "not_found");
            next = merge(cur, patch == null ? new LinkedHashMap<String, Object>() : patch); store.put(col, id, next); sq = bump(col);
          }
          json(out, 200, map("ok", true, "data", next, "seq", sq), close); return;
        }
        if (m.equals("DELETE")) { long sq; synchronized (lock) { store.del(col, id); sq = bump(col); } json(out, 200, map("ok", true, "seq", sq), close); return; }
      }
      if (a.equals("lease") && seg.size() == 4 && m.equals("POST")) {
        String col = seg.get(2), id = seg.get(3); Map<String, Object> b = bodyJson(r); Object holder = b.get("holder");
        if (!NAME_RE.matcher(col).matches() || !NAME_RE.matcher(id).matches() || holder == null) throw new HttpError(400, "bad_lease");
        long ttl = 30000; if (b.get("ttlMs") instanceof Number) ttl = Math.max(1000, Math.min(600000, ((Number) b.get("ttlMs")).longValue()));
        long now = System.currentTimeMillis();
        Map<String, Object> res;
        synchronized (lock) {
          Map<String, Object> cur = Json.obj(store.get(col, id));
          if (cur != null && !String.valueOf(holder).equals(cur.get("holder")) && cur.get("untilMs") instanceof Number && ((Number) cur.get("untilMs")).longValue() > now) {
            res = map("acquired", false, "expiresAt", iso(((Number) cur.get("untilMs")).longValue()));
          } else {
            long exp = now + ttl; store.put(col, id, map("holder", String.valueOf(holder), "untilMs", exp, "until", iso(exp)));
            res = map("acquired", true, "expiresAt", iso(exp));
          }
        }
        json(out, 200, res, close); return;
      }
      if (a.equals("changes") && m.equals("GET")) {
        long n = 0; try { n = (long) Double.parseDouble(r.param("since") == null ? "0" : r.param("since")); } catch (NumberFormatException e) { /* 0 */ }
        long wait = 25; try { if (r.param("wait") != null) wait = Math.min(55, (long) Double.parseDouble(r.param("wait"))); } catch (NumberFormatException e) { /* 25 */ }
        long until = System.currentTimeMillis() + wait * 1000;
        Map<String, Object> res;
        synchronized (lock) {
          while (running && seq == n) { long left = until - System.currentTimeMillis(); if (left <= 0) break; try { lock.wait(left); } catch (InterruptedException e) { break; } }
          res = map("seq", seq, "cols", since(n));
        }
        json(out, 200, res, close); return;
      }
      if (a.equals("asset") && seg.size() == 2 && m.equals("POST")) {
        String ty = r.headers.get("content-type"); ty = ty == null ? "" : ty.split(";")[0].trim();
        String ext = EXT.get(ty); if (ext == null) throw new HttpError(415, "bad_type");
        byte[] rnd = new byte[10]; new SecureRandom().nextBytes(rnd); String id = hex(rnd) + "." + ext;
        FileOutputStream f = new FileOutputStream(new File(assetDir, id)); try { f.write(r.body); } finally { f.close(); }
        json(out, 200, map("id", id, "sizeBytes", (long) r.body.length, "contentType", ty), close); return;
      }
      if (a.equals("asset") && seg.size() == 3 && m.equals("DELETE")) { if (ASSET_RE.matcher(seg.get(2)).matches()) new File(assetDir, seg.get(2)).delete(); json(out, 200, map("ok", true), close); return; }
      if (a.equals("export") && m.equals("GET")) {
        Map<String, String> h = new LinkedHashMap<>(); h.put("Content-Disposition", "attachment; filename=\"coconut-pos-backup.json\"");
        respond(out, 200, "application/json", Json.str(map("app", "coconut-pos-offline", "exportedAt", iso(System.currentTimeMillis()), "collections", store.all())).getBytes(UTF8), close, h); return;
      }
      throw new HttpError(404, "not_found");
    }
    if (seg.size() == 2 && seg.get(0).equals("assets") && ASSET_RE.matcher(seg.get(1)).matches()) {
      File f = new File(assetDir, seg.get(1));
      if (!f.isFile()) throw new HttpError(404, "not_found");
      Map<String, String> h = new LinkedHashMap<>(); h.put("Cache-Control", "public, max-age=31536000, immutable");
      respond(out, 200, mime(f.getName()), readAll(new FileInputStream(f)), close, h); return;
    }
    // Static app files
    String rel = p.equals("/") ? "index.html" : p.substring(1);
    if (rel.endsWith("/")) rel += "index.html";
    if (rel.contains("..")) throw new HttpError(403, "forbidden");
    byte[] body;
    try { body = readAll(www.open(rel)); }
    catch (IOException e) {
      if (rel.contains(".")) throw new HttpError(404, "not_found");
      rel = "index.html"; body = readAll(www.open(rel));
    }
    if (rel.equals("index.html") && hostScript != null && r.headers.containsKey("x-coconut-host")) {
      // The app on this device asked for the page: tell it it runs on the main machine.
      String html = new String(body, UTF8);
      int i = html.indexOf("<head>");
      if (i >= 0) html = html.substring(0, i + 6) + "\n<script>" + hostScript + "</script>" + html.substring(i + 6);
      body = html.getBytes(UTF8);
    }
    Map<String, String> h = new LinkedHashMap<>(); h.put("Cache-Control", "no-cache");
    respond(out, 200, mime(rel), body, close, h);
  }

  private static String mime(String name) {
    int i = name.lastIndexOf('.'); String e = i < 0 ? "" : name.substring(i + 1).toLowerCase(Locale.US);
    String t = MIME.get(e); return t == null ? "application/octet-stream" : t;
  }

  private static byte[] readAll(InputStream in) throws IOException {
    try { ByteArrayOutputStream b = new ByteArrayOutputStream(); byte[] buf = new byte[65536]; int n; while ((n = in.read(buf)) > 0) b.write(buf, 0, n); return b.toByteArray(); }
    finally { in.close(); }
  }

  private static String hex(byte[] b) { StringBuilder s = new StringBuilder(); for (byte x : b) s.append(String.format("%02x", x & 0xff)); return s.toString(); }

  private static String iso(long ms) {
    SimpleDateFormat f = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US); f.setTimeZone(TimeZone.getTimeZone("UTC"));
    return f.format(new Date(ms));
  }

  /** Desktop test entry: java PosServer <dataDir> <wwwDir> <port> */
  public static void main(String[] args) throws Exception {
    final File w = new File(args[1]);
    PosServer s = new PosServer(new File(args[0]), new Files() {
      public InputStream open(String path) throws IOException { File f = new File(w, path); if (!f.isFile()) throw new IOException("missing"); return new FileInputStream(f); }
    }, Integer.parseInt(args[2]), "android", "test-device", "window.COCONUT_HOST={platform:'android'};");
    s.start();
    System.out.println("Coconut POS Java server on port " + args[2] + " " + lanAddresses());
    Thread.sleep(Long.MAX_VALUE);
  }
}
