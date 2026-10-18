package com.coconutpos.standalone;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Small JSON reader/writer (objects are LinkedHashMap, arrays ArrayList, numbers Double or Long). */
public final class Json {
  private Json() {}

  public static Object parse(String s) {
    P p = new P(s);
    p.ws();
    Object v = p.value();
    p.ws();
    if (p.i != s.length()) throw new IllegalArgumentException("bad_json");
    return v;
  }

  @SuppressWarnings("unchecked")
  public static Map<String, Object> obj(Object o) { return o instanceof Map ? (Map<String, Object>) o : null; }

  public static String str(Object v) { StringBuilder b = new StringBuilder(); write(b, v); return b.toString(); }

  @SuppressWarnings("unchecked")
  public static Object copy(Object v) {
    if (v instanceof Map) {
      Map<String, Object> m = new LinkedHashMap<>();
      for (Map.Entry<String, Object> e : ((Map<String, Object>) v).entrySet()) m.put(e.getKey(), copy(e.getValue()));
      return m;
    }
    if (v instanceof List) { List<Object> l = new ArrayList<>(); for (Object x : (List<Object>) v) l.add(copy(x)); return l; }
    return v;
  }

  @SuppressWarnings("unchecked")
  static void write(StringBuilder b, Object v) {
    if (v == null) b.append("null");
    else if (v instanceof String) quote(b, (String) v);
    else if (v instanceof Boolean) b.append(((Boolean) v) ? "true" : "false");
    else if (v instanceof Double || v instanceof Float) {
      double d = ((Number) v).doubleValue();
      if (Double.isNaN(d) || Double.isInfinite(d)) b.append("null");
      else if (d == Math.rint(d) && Math.abs(d) < 9.007199254740992E15) b.append((long) d);
      else b.append(d);
    } else if (v instanceof Number) b.append(((Number) v).longValue());
    else if (v instanceof Map) {
      b.append('{'); boolean first = true;
      for (Map.Entry<String, Object> e : ((Map<String, Object>) v).entrySet()) {
        if (!first) b.append(','); first = false; quote(b, e.getKey()); b.append(':'); write(b, e.getValue());
      }
      b.append('}');
    } else if (v instanceof List) {
      b.append('['); boolean first = true;
      for (Object x : (List<Object>) v) { if (!first) b.append(','); first = false; write(b, x); }
      b.append(']');
    } else quote(b, String.valueOf(v));
  }

  static void quote(StringBuilder b, String s) {
    b.append('"');
    for (int i = 0; i < s.length(); i++) {
      char c = s.charAt(i);
      switch (c) {
        case '"': b.append("\\\""); break;
        case '\\': b.append("\\\\"); break;
        case '\n': b.append("\\n"); break;
        case '\r': b.append("\\r"); break;
        case '\t': b.append("\\t"); break;
        case '\b': b.append("\\b"); break;
        case '\f': b.append("\\f"); break;
        default:
          if (c < 0x20 || c == 0x2028 || c == 0x2029) b.append(String.format("\\u%04x", (int) c)); else b.append(c);
      }
    }
    b.append('"');
  }

  private static final class P {
    final String s; int i;
    P(String s) { this.s = s; }
    void ws() { while (i < s.length()) { char c = s.charAt(i); if (c == ' ' || c == '\n' || c == '\r' || c == '\t') i++; else break; } }
    Object value() {
      if (i >= s.length()) throw new IllegalArgumentException("bad_json");
      char c = s.charAt(i);
      if (c == '{') return object();
      if (c == '[') return array();
      if (c == '"') return string();
      if (s.startsWith("true", i)) { i += 4; return Boolean.TRUE; }
      if (s.startsWith("false", i)) { i += 5; return Boolean.FALSE; }
      if (s.startsWith("null", i)) { i += 4; return null; }
      return number();
    }
    Map<String, Object> object() {
      Map<String, Object> m = new LinkedHashMap<>(); i++; ws();
      if (i < s.length() && s.charAt(i) == '}') { i++; return m; }
      while (true) {
        ws(); String k = string(); ws(); expect(':'); ws(); m.put(k, value()); ws();
        if (i < s.length() && s.charAt(i) == ',') { i++; continue; }
        expect('}'); return m;
      }
    }
    List<Object> array() {
      List<Object> l = new ArrayList<>(); i++; ws();
      if (i < s.length() && s.charAt(i) == ']') { i++; return l; }
      while (true) {
        ws(); l.add(value()); ws();
        if (i < s.length() && s.charAt(i) == ',') { i++; continue; }
        expect(']'); return l;
      }
    }
    String string() {
      expect('"'); StringBuilder b = new StringBuilder();
      while (true) {
        if (i >= s.length()) throw new IllegalArgumentException("bad_json");
        char c = s.charAt(i++);
        if (c == '"') return b.toString();
        if (c == '\\') {
          char e = s.charAt(i++);
          switch (e) {
            case 'n': b.append('\n'); break; case 'r': b.append('\r'); break; case 't': b.append('\t'); break;
            case 'b': b.append('\b'); break; case 'f': b.append('\f'); break;
            case 'u': b.append((char) Integer.parseInt(s.substring(i, i + 4), 16)); i += 4; break;
            default: b.append(e);
          }
        } else b.append(c);
      }
    }
    Object number() {
      int st = i; boolean dbl = false;
      while (i < s.length()) {
        char c = s.charAt(i);
        if ((c >= '0' && c <= '9') || c == '-' || c == '+') i++;
        else if (c == '.' || c == 'e' || c == 'E') { dbl = true; i++; }
        else break;
      }
      String t = s.substring(st, i);
      if (t.isEmpty()) throw new IllegalArgumentException("bad_json");
      if (!dbl) { try { return Long.parseLong(t); } catch (NumberFormatException ex) { /* fall through */ } }
      return Double.parseDouble(t);
    }
    void expect(char c) { if (i >= s.length() || s.charAt(i) != c) throw new IllegalArgumentException("bad_json"); i++; }
  }

  /** Iterates a JSON array safely. */
  public static Iterable<Object> list(Object o) {
    if (o instanceof List) { @SuppressWarnings("unchecked") List<Object> l = (List<Object>) o; return l; }
    return new Iterable<Object>() { public Iterator<Object> iterator() { return new ArrayList<Object>().iterator(); } };
  }
}
