import Foundation

/// The shop's data on this device: a snapshot (coconut-pos.json) plus an append-only journal
/// (coconut-pos.journal), compacted every few thousand writes. Same files as the Android/Windows file store.
final class Store {
  private let snapURL: URL
  private let journalURL: URL
  private var cols: [String: [String: Any]] = [:]
  private var order: [String: [String]] = [:] // insertion order per collection
  private var meta: [String: String] = [:]
  private var handle: FileHandle?
  private var jLines = 0

  init(dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    snapURL = dir.appendingPathComponent("coconut-pos.json")
    journalURL = dir.appendingPathComponent("coconut-pos.journal")
    if let d = try? Data(contentsOf: snapURL), let s = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
      if let m = s["meta"] as? [String: Any] { for (k, v) in m { meta[k] = "\(v)" } }
      if let cs = s["cols"] as? [String: Any] {
        for (c, docs) in cs { if let docs = docs as? [String: Any] { for (id, d) in docs { setLocal(c, id, d) } } }
      }
    }
    if let d = try? Data(contentsOf: journalURL), let text = String(data: d, encoding: .utf8) {
      for line in text.split(separator: "\n") {
        guard let ld = line.data(using: .utf8), let x = try? JSONSerialization.jsonObject(with: ld) as? [String: Any] else { continue }
        jLines += 1
        if let k = x["m"] as? String { meta[k] = x["v"].map { "\($0)" } }
        else if x["del"] != nil, let c = x["c"] as? String, let i = x["i"] as? String { removeLocal(c, i) }
        else if let c = x["c"] as? String, let i = x["i"] as? String, let dd = x["d"] { setLocal(c, i, dd) }
      }
    }
    if !FileManager.default.fileExists(atPath: journalURL.path) { FileManager.default.createFile(atPath: journalURL.path, contents: nil) }
    handle = try FileHandle(forWritingTo: journalURL)
    handle?.seekToEndOfFile()
  }

  private func setLocal(_ c: String, _ id: String, _ d: Any) {
    if cols[c] == nil { cols[c] = [:]; order[c] = [] }
    if cols[c]![id] == nil { order[c]!.append(id) }
    cols[c]![id] = d
  }
  private func removeLocal(_ c: String, _ id: String) {
    guard cols[c]?[id] != nil else { return }
    cols[c]![id] = nil
    order[c]!.removeAll { $0 == id }
  }

  private func write(_ o: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
    handle?.write(d); handle?.write("\n".data(using: .utf8)!)
    jLines += 1
    if jLines > 5000 { compact() }
  }

  func compact() {
    var cs: [String: Any] = [:]
    for (c, m) in cols { cs[c] = m }
    let out: [String: Any] = ["meta": meta, "cols": cs]
    if let d = try? JSONSerialization.data(withJSONObject: out) {
      let tmp = snapURL.appendingPathExtension("tmp")
      try? d.write(to: tmp, options: .atomic)
      _ = try? FileManager.default.replaceItemAt(snapURL, withItemAt: tmp)
      if !FileManager.default.fileExists(atPath: snapURL.path) { try? d.write(to: snapURL, options: .atomic) }
    }
    try? handle?.close()
    try? Data().write(to: journalURL)
    handle = try? FileHandle(forWritingTo: journalURL)
    jLines = 0
  }

  func getMeta(_ k: String) -> String? { meta[k] }
  func setMeta(_ k: String, _ v: String) { meta[k] = v; write(["m": k, "v": v]) }
  func get(_ c: String, _ id: String) -> Any? { cols[c]?[id] }
  func put(_ c: String, _ id: String, _ d: Any) { setLocal(c, id, d); write(["c": c, "i": id, "d": d]) }
  func del(_ c: String, _ id: String) { removeLocal(c, id); write(["c": c, "i": id, "del": 1]) }

  static func path(_ o: Any?, _ f: String) -> Any? {
    var cur = o
    for k in f.split(separator: ".") { guard let m = cur as? [String: Any] else { return nil }; cur = m[String(k)] }
    return cur
  }

  static func isBool(_ v: Any?) -> Bool {
    guard let n = v as? NSNumber else { return false }
    return CFGetTypeID(n) == CFBooleanGetTypeID()
  }
  static func num(_ v: Any?) -> Double? {
    if isBool(v) { return nil }
    if let n = v as? NSNumber { return n.doubleValue }
    return nil
  }
  static func compare(_ a: Any?, _ b: Any?) -> Int? {
    if let x = num(a), let y = num(b) { return x < y ? -1 : (x > y ? 1 : 0) }
    if let x = a as? String, let y = b as? String { return x < y ? -1 : (x > y ? 1 : 0) }
    if isBool(a), isBool(b), let x = a as? Bool, let y = b as? Bool { return x == y ? 0 : (x ? 1 : -1) }
    return nil
  }
  static func test(_ v: Any?, _ op: String, _ x: Any) -> Bool {
    var v = v
    if num(x) != nil, let s = v as? String, let d = Double(s) { v = d as NSNumber }
    if op == "in" {
      guard let list = x as? [Any] else { return false }
      return list.contains { compare(v, $0) == 0 }
    }
    let c = compare(v, x)
    switch op {
    case "==": return c == 0
    case "!=": return c != 0
    case ">": return c.map { $0 > 0 } ?? false
    case ">=": return c.map { $0 >= 0 } ?? false
    case "<": return c.map { $0 < 0 } ?? false
    case "<=": return c.map { $0 <= 0 } ?? false
    default: return true
    }
  }

  func query(_ c: String, _ wh: [(String, String, Any)], _ orderField: String?, _ desc: Bool, _ limit: Int) -> [[String: Any]] {
    var rows: [(String, Any)] = []
    for id in order[c] ?? [] {
      guard let d = cols[c]?[id] else { continue }
      if wh.allSatisfy({ Store.test(Store.path(d, $0.0), $0.1, $0.2) }) { rows.append((id, d)) }
    }
    if let f = orderField {
      rows.sort { a, b in
        let A = Store.path(a.1, f), B = Store.path(b.1, f)
        let r: Int = A == nil ? -1 : (B == nil ? 1 : (Store.compare(A, B) ?? 0))
        return desc ? r > 0 : r < 0
      }
    }
    return rows.prefix(limit).map { ["id": $0.0, "data": $0.1] }
  }

  func all() -> [String: [[String: Any]]] {
    var out: [String: [[String: Any]]] = [:]
    for (c, m) in cols where c != "_sys" && c != "bridge" {
      out[c] = (order[c] ?? []).compactMap { id in
        guard var d = m[id] as? [String: Any] else { return nil }
        d["id"] = id
        return d
      }
    }
    return out
  }

  func backup(to url: URL) { compact(); try? FileManager.default.removeItem(at: url); try? FileManager.default.copyItem(at: snapURL, to: url) }
  func close() { compact(); try? handle?.close() }
}
