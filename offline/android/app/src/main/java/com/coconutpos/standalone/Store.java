package com.coconutpos.standalone;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The shop's data on this device: a snapshot (coconut-pos.json) plus an append-only journal
 * (coconut-pos.journal), compacted every few thousand writes. Same files as the Windows file store.
 */
public final class Store {
  private static final Charset UTF8 = Charset.forName("UTF-8");
  private final File snapF, jF;
  private final Map<String, Map<String, Object>> cols = new LinkedHashMap<>();
  private Map<String, Object> meta = new LinkedHashMap<>();
  private Writer journal;
  private int jLines = 0;

  public Store(File dir) throws IOException {
    dir.mkdirs();
    snapF = new File(dir, "coconut-pos.json");
    jF = new File(dir, "coconut-pos.journal");
    if (snapF.exists()) {
      try {
        Map<String, Object> s = Json.obj(Json.parse(read(snapF)));
        if (s != null) {
          Map<String, Object> m = Json.obj(s.get("meta")); if (m != null) meta = m;
          Map<String, Object> cs = Json.obj(s.get("cols"));
          if (cs != null) for (Map.Entry<String, Object> e : cs.entrySet()) {
            Map<String, Object> docs = Json.obj(e.getValue());
            if (docs != null) col(e.getKey()).putAll(docs);
          }
        }
      } catch (RuntimeException ex) { /* unreadable snapshot: keep going with the journal */ }
    }
    if (jF.exists()) {
      BufferedReader r = new BufferedReader(new InputStreamReader(new FileInputStream(jF), UTF8));
      try {
        String line;
        while ((line = r.readLine()) != null) {
          if (line.isEmpty()) continue;
          Map<String, Object> x;
          try { x = Json.obj(Json.parse(line)); } catch (RuntimeException ex) { continue; }
          if (x == null) continue;
          jLines++;
          if (x.containsKey("m")) meta.put(String.valueOf(x.get("m")), x.get("v"));
          else if (x.containsKey("del")) col(String.valueOf(x.get("c"))).remove(String.valueOf(x.get("i")));
          else col(String.valueOf(x.get("c"))).put(String.valueOf(x.get("i")), x.get("d"));
        }
      } finally { r.close(); }
    }
    journal = new OutputStreamWriter(new FileOutputStream(jF, true), UTF8);
  }

  private static String read(File f) throws IOException {
    FileInputStream in = new FileInputStream(f);
    try {
      byte[] buf = new byte[(int) f.length()]; int n = 0;
      while (n < buf.length) { int k = in.read(buf, n, buf.length - n); if (k < 0) break; n += k; }
      return new String(buf, 0, n, UTF8);
    } finally { in.close(); }
  }

  private Map<String, Object> col(String c) {
    Map<String, Object> m = cols.get(c);
    if (m == null) { m = new LinkedHashMap<>(); cols.put(c, m); }
    return m;
  }

  private void write(Map<String, Object> o) {
    try {
      journal.write(Json.str(o)); journal.write('\n'); journal.flush();
      if (++jLines > 5000) compact();
    } catch (IOException e) { throw new RuntimeException(e); }
  }

  public synchronized void compact() {
    try {
      Map<String, Object> out = new LinkedHashMap<>();
      out.put("meta", meta);
      Map<String, Object> cs = new LinkedHashMap<>();
      for (Map.Entry<String, Map<String, Object>> e : cols.entrySet()) cs.put(e.getKey(), e.getValue());
      out.put("cols", cs);
      File tmp = new File(snapF.getPath() + ".tmp");
      Writer w = new OutputStreamWriter(new FileOutputStream(tmp), UTF8);
      try { w.write(Json.str(out)); } finally { w.close(); }
      if (!tmp.renameTo(snapF)) { snapF.delete(); if (!tmp.renameTo(snapF)) throw new IOException("rename failed"); }
      journal.close();
      new FileOutputStream(jF).close();
      journal = new OutputStreamWriter(new FileOutputStream(jF, true), UTF8);
      jLines = 0;
    } catch (IOException e) { throw new RuntimeException(e); }
  }

  public synchronized String meta(String k) { Object v = meta.get(k); return v == null ? null : String.valueOf(v); }
  public synchronized void setMeta(String k, String v) {
    meta.put(k, v);
    Map<String, Object> o = new LinkedHashMap<>(); o.put("m", k); o.put("v", v); write(o);
  }
  public synchronized Object get(String c, String id) { Object d = col(c).get(id); return d == null ? null : Json.copy(d); }
  public synchronized void put(String c, String id, Object data) {
    col(c).put(id, Json.copy(data));
    Map<String, Object> o = new LinkedHashMap<>(); o.put("c", c); o.put("i", id); o.put("d", data); write(o);
  }
  public synchronized void del(String c, String id) {
    col(c).remove(id);
    Map<String, Object> o = new LinkedHashMap<>(); o.put("c", c); o.put("i", id); o.put("del", 1L); write(o);
  }

  static Object path(Object o, String f) {
    for (String k : f.split("\\.")) { Map<String, Object> m = Json.obj(o); if (m == null) return null; o = m.get(k); }
    return o;
  }

  @SuppressWarnings({"unchecked", "rawtypes"})
  static int cmp(Object a, Object b) {
    if (a instanceof Number && b instanceof Number) return Double.compare(((Number) a).doubleValue(), ((Number) b).doubleValue());
    if (a instanceof String && b instanceof String) return ((String) a).compareTo((String) b);
    if (a instanceof Boolean && b instanceof Boolean) return ((Boolean) a).compareTo((Boolean) b);
    return String.valueOf(a).compareTo(String.valueOf(b));
  }

  static boolean test(Object v, String op, Object x) {
    if (x instanceof Number && v instanceof String) { try { v = Double.parseDouble((String) v); } catch (NumberFormatException e) { /* keep */ } }
    if ("in".equals(op)) {
      if (v == null) return false;
      for (Object y : Json.list(x)) {
        boolean sameType = (v instanceof Number && y instanceof Number) || (y != null && v.getClass().equals(y.getClass()));
        if (sameType && cmp(v, y) == 0) return true;
      }
      return false;
    }
    if (v == null) return "!=".equals(op) && x != null;
    boolean same = (v instanceof Number && x instanceof Number) || (v instanceof String && x instanceof String) || (v instanceof Boolean && x instanceof Boolean);
    if ("==".equals(op)) return same && cmp(v, x) == 0;
    if ("!=".equals(op)) return !same || cmp(v, x) != 0;
    if (!same) return false;
    int c = cmp(v, x);
    if (">".equals(op)) return c > 0;
    if (">=".equals(op)) return c >= 0;
    if ("<".equals(op)) return c < 0;
    if ("<=".equals(op)) return c <= 0;
    return true;
  }

  /** Documents of a collection matching [[field, op, value], ...], optionally ordered, at most limit. */
  public synchronized List<Map<String, Object>> query(String c, List<Object[]> where, final String orderField, final boolean desc, int limit) {
    List<Map<String, Object>> rows = new ArrayList<>();
    for (Map.Entry<String, Object> e : col(c).entrySet()) {
      boolean ok = true;
      for (Object[] w : where) if (!test(path(e.getValue(), (String) w[0]), (String) w[1], w[2])) { ok = false; break; }
      if (!ok) continue;
      Map<String, Object> r = new LinkedHashMap<>(); r.put("id", e.getKey()); r.put("data", e.getValue()); rows.add(r);
    }
    if (orderField != null) {
      Collections.sort(rows, new Comparator<Map<String, Object>>() {
        public int compare(Map<String, Object> a, Map<String, Object> b) {
          Object A = path(a.get("data"), orderField), B = path(b.get("data"), orderField);
          int r = A == null ? -1 : B == null ? 1 : cmp(A, B);
          return desc ? -r : r;
        }
      });
    }
    List<Map<String, Object>> out = new ArrayList<>();
    for (int i = 0; i < rows.size() && i < limit; i++) {
      Map<String, Object> r = rows.get(i); Map<String, Object> o = new LinkedHashMap<>();
      o.put("id", r.get("id")); o.put("data", Json.copy(r.get("data"))); out.add(o);
    }
    return out;
  }

  /** Every document, for the export. */
  public synchronized Map<String, List<Object>> all() {
    Map<String, List<Object>> out = new LinkedHashMap<>();
    for (Map.Entry<String, Map<String, Object>> e : cols.entrySet()) {
      if ("_sys".equals(e.getKey()) || "bridge".equals(e.getKey())) continue;
      List<Object> l = new ArrayList<>();
      for (Map.Entry<String, Object> d : e.getValue().entrySet()) {
        Map<String, Object> m = new LinkedHashMap<>(); m.put("id", d.getKey());
        Map<String, Object> data = Json.obj(Json.copy(d.getValue())); if (data != null) m.putAll(data);
        l.add(m);
      }
      out.put(e.getKey(), l);
    }
    return out;
  }

  public synchronized void backupTo(File f) throws IOException {
    compact();
    FileInputStream in = new FileInputStream(snapF); FileOutputStream o = new FileOutputStream(f);
    try { byte[] buf = new byte[65536]; int n; while ((n = in.read(buf)) > 0) o.write(buf, 0, n); } finally { in.close(); o.close(); }
  }

  public synchronized void close() { try { compact(); journal.close(); } catch (Exception e) { /* ignore */ } }
}
