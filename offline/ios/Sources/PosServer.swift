import Foundation
import Network

/// Coconut POS Stand alone local server (iOS). Same HTTP API as offline/server/server.js (see offline/API.md):
/// serves the POS app to every device on the Wi-Fi/LAN and keeps the shop's data on this iPad/iPhone.
final class PosServer {
  static let version = "1.0.0"
  let port: UInt16
  private let dataDir: URL, assetDir: URL, backupDir: URL, wwwDir: URL
  private let store: Store
  private let q = DispatchQueue(label: "coconut.server")
  private var listener: NWListener?
  private(set) var deviceId = ""
  private var seq = 0
  private var changes: [(Int, String)] = []
  private var waiters: [() -> Void] = []
  private let started = Int(Date().timeIntervalSince1970 * 1000)
  private var lastBackupDay = ""
  let deviceName: String

  private static let nameRe = try! NSRegularExpression(pattern: "^[A-Za-z0-9_.:-]{1,128}$")
  private static let fieldRe = try! NSRegularExpression(pattern: "^[A-Za-z0-9_]{1,64}(\\.[A-Za-z0-9_]{1,64}){0,3}$")
  private static let assetRe = try! NSRegularExpression(pattern: "^[a-f0-9]{20}\\.[a-z0-9]{2,5}$")
  private static let ops: Set<String> = ["==", "!=", ">", ">=", "<", "<=", "in"]
  private static let mime: [String: String] = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8",
    "json": "application/json", "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp",
    "gif": "image/gif", "ico": "image/x-icon", "woff2": "font/woff2", "mp4": "video/mp4", "webm": "video/webm", "mov": "video/quicktime"]
  private static let ext: [String: String] = ["image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif",
    "video/mp4": "mp4", "video/webm": "webm", "video/quicktime": "mov"]
  static func ok(_ re: NSRegularExpression, _ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

  init(dataDir: URL, wwwDir: URL, port: UInt16, deviceName: String) throws {
    self.dataDir = dataDir; self.wwwDir = wwwDir; self.port = port; self.deviceName = deviceName
    assetDir = dataDir.appendingPathComponent("assets"); backupDir = dataDir.appendingPathComponent("backups")
    try FileManager.default.createDirectory(at: assetDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
    store = try Store(dir: dataDir)
    if let d = store.getMeta("deviceId") { deviceId = d } else {
      deviceId = "srv" + PosServer.hex(count: 9); store.setMeta("deviceId", deviceId)
    }
    seq = Int(Double(store.getMeta("seq") ?? "0") ?? 0)
  }

  static func hex(count: Int) -> String { (0..<count).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }

  func start(ready: @escaping (Error?) -> Void) {
    do {
      let params = NWParameters.tcp
      params.allowLocalEndpointReuse = true
      let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
      var reported = false
      l.stateUpdateHandler = { st in
        switch st {
        case .ready: if !reported { reported = true; ready(nil) }
        case .failed(let e): if !reported { reported = true; ready(e) }
        default: break
        }
      }
      l.newConnectionHandler = { [weak self] c in self?.accept(c) }
      l.start(queue: q)
      listener = l
      q.async { self.backup() }
    } catch { ready(error) }
  }

  func stop() { listener?.cancel(); q.sync { for w in waiters { w() }; waiters = []; store.close() } }

  // MARK: data
  private func bump(_ col: String) -> Int {
    seq += 1; store.setMeta("seq", String(seq))
    changes.append((seq, col)); if changes.count > 2000 { changes.removeFirst(changes.count - 2000) }
    let w = waiters; waiters = []; for f in w { f() }
    return seq
  }
  private func since(_ n: Int) -> Any {
    if n > seq || (!changes.isEmpty && n < changes[0].0 - 1) || (changes.isEmpty && n < seq) { return NSNull() }
    var out: [String] = []
    for c in changes where c.0 > n && !out.contains(c.1) { out.append(c.1) }
    return out
  }
  static func merge(_ a: Any?, _ b: Any) -> Any {
    if let x = a as? [String: Any], let y = b as? [String: Any] {
      var out = x
      for (k, v) in y { out[k] = x[k] != nil ? merge(x[k], v) : v }
      return out
    }
    return b
  }

  static func lanAddresses() -> [String] {
    var out: [String] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
    defer { freeifaddrs(ifaddr) }
    var p: UnsafeMutablePointer<ifaddrs>? = first
    while let cur = p {
      let flags = Int32(cur.pointee.ifa_flags)
      if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
          let ip = String(cString: host)
          if !ip.hasPrefix("169.254.") { out.append(ip) }
        }
      }
      p = cur.pointee.ifa_next
    }
    return out.sorted { ($0.hasPrefix("192.168.") ? 0 : 1) < ($1.hasPrefix("192.168.") ? 0 : 1) }
  }

  func info() -> [String: Any] {
    ["app": "coconut-pos-offline", "version": PosServer.version, "deviceId": deviceId, "name": deviceName, "platform": "ios",
     "port": Int(port), "lan": PosServer.lanAddresses(), "seq": seq, "started": started, "storage": "file"]
  }

  private func backup() {
    let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.locale = Locale(identifier: "en_US_POSIX")
    let stamp = f.string(from: Date())
    if stamp == lastBackupDay { return }
    lastBackupDay = stamp
    let file = backupDir.appendingPathComponent("coconut-pos-\(stamp).json")
    if !FileManager.default.fileExists(atPath: file.path) { store.backup(to: file) }
    if let names = try? FileManager.default.contentsOfDirectory(atPath: backupDir.path) {
      var l = names.filter { $0.hasPrefix("coconut-pos-") }.sorted()
      while l.count > 14 { try? FileManager.default.removeItem(at: backupDir.appendingPathComponent(l.removeFirst())) }
    }
  }

  // MARK: HTTP
  private struct Req { var method = "", path = "", query: [String: String] = [:], headers: [String: String] = [:], body = Data() }

  private func accept(_ c: NWConnection) {
    c.start(queue: q)
    read(c, Data())
  }

  private func read(_ c: NWConnection, _ buf: Data) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
      guard let self = self else { return }
      var b = buf
      if let d = data { b.append(d) }
      if err != nil { c.cancel(); return }
      if let r = self.parse(&b) {
        if r.0 == nil { self.reply(c, 413, ["error": "too_large"], close: true); return }
        let close = (r.0!.headers["connection"] ?? "").lowercased() == "close"
        self.handle(r.0!, c, close: close)
        if !close { self.readNext(c, b) }
        return
      }
      if done { c.cancel(); return }
      self.read(c, b)
    }
  }
  private func readNext(_ c: NWConnection, _ rest: Data) {
    var b = rest
    if !b.isEmpty, let r = parse(&b), let req = r.0 {
      let close = (req.headers["connection"] ?? "").lowercased() == "close"
      handle(req, c, close: close)
      if !close { readNext(c, b) }
      return
    }
    read(c, b)
  }

  /// Returns (request, ) when a full request is in buf (and removes it), (nil, ) when it is too large, nil when more data is needed.
  private func parse(_ buf: inout Data) -> (Req?, Int)? {
    guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else { return buf.count > 65536 ? (nil, 0) : nil }
    let head = String(decoding: buf[buf.startIndex..<sep.lowerBound], as: UTF8.self)
    var lines = head.components(separatedBy: "\r\n")
    let first = lines.removeFirst().split(separator: " ")
    guard first.count >= 2 else { return (nil, 0) }
    var r = Req(); r.method = String(first[0])
    let target = String(first[1])
    if let qi = target.firstIndex(of: "?") {
      r.path = String(target[..<qi])
      for kv in target[target.index(after: qi)...].split(separator: "&") {
        let parts = kv.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" }
        if let k = parts.first { r.query[k] = parts.count > 1 ? parts[1] : "" }
      }
    } else { r.path = target }
    for l in lines { if let i = l.firstIndex(of: ":") { r.headers[l[..<i].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
    let len = Int(r.headers["content-length"] ?? "0") ?? 0
    if len > 60 * 1024 * 1024 { return (nil, 0) }
    let bodyStart = sep.upperBound
    if buf.distance(from: bodyStart, to: buf.endIndex) < len { return nil }
    let bodyEnd = buf.index(bodyStart, offsetBy: len)
    r.body = Data(buf[bodyStart..<bodyEnd])
    buf = Data(buf[bodyEnd...])
    return (r, 0)
  }

  private func send(_ c: NWConnection, _ code: Int, _ type: String, _ body: Data, close: Bool, extra: [String: String] = [:]) {
    var h = "HTTP/1.1 \(code) \(code == 200 ? "OK" : code == 404 ? "Not Found" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
    for (k, v) in extra { h += "\(k): \(v)\r\n" }
    if extra["Cache-Control"] == nil { h += "Cache-Control: no-store\r\n" }
    h += close ? "Connection: close\r\n\r\n" : "Connection: keep-alive\r\n\r\n"
    var d = Data(h.utf8); d.append(body)
    c.send(content: d, completion: .contentProcessed { _ in if close { c.cancel() } })
  }
  private func reply(_ c: NWConnection, _ code: Int, _ obj: Any, close: Bool, extra: [String: String] = [:]) {
    let d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    send(c, code, "application/json", d, close: close, extra: extra)
  }
  private func bodyJSON(_ r: Req) -> [String: Any]? {
    if r.body.isEmpty { return [:] }
    return (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any]
  }

  private func handle(_ r: Req, _ c: NWConnection, close: Bool) {
    backup()
    let p = r.path.removingPercentEncoding ?? r.path
    let seg = p.split(separator: "/").map(String.init)
    let m = r.method
    func bad(_ code: Int, _ e: String) { reply(c, code, ["error": e], close: close) }
    if seg.first == "api" {
      let a = seg.count > 1 ? seg[1] : ""
      if a == "info" && m == "GET" { reply(c, 200, info(), close: close); return }
      if a == "col" && seg.count == 3 && m == "GET" {
        let col = seg[2]; guard PosServer.ok(PosServer.nameRe, col) else { bad(400, "bad_name"); return }
        var wh: [(String, String, Any)] = []; var of: String? = nil; var desc = false
        if let w = r.query["w"], let arr = (try? JSONSerialization.jsonObject(with: Data(w.utf8))) as? [Any] {
          for x in arr {
            guard let t = x as? [Any], t.count == 3, let f = t[0] as? String, let op = t[1] as? String else { continue }
            guard PosServer.ok(PosServer.fieldRe, f) else { bad(400, "bad_field"); return }
            if PosServer.ops.contains(op) { wh.append((f, op, t[2])) }
          }
        }
        if let o = r.query["o"], let arr = (try? JSONSerialization.jsonObject(with: Data(o.utf8))) as? [Any], let f = arr.first as? String, PosServer.ok(PosServer.fieldRe, f) {
          of = f; desc = (arr.count > 1 ? arr[1] as? String : nil) == "desc"
        }
        let lim = max(1, min(50000, Int(Double(r.query["l"] ?? "50000") ?? 50000)))
        reply(c, 200, ["seq": seq, "docs": store.query(col, wh, of, desc, lim)], close: close); return
      }
      if a == "doc" && seg.count == 4 {
        let col = seg[2], id = seg[3]
        guard PosServer.ok(PosServer.nameRe, col), PosServer.ok(PosServer.nameRe, id) else { bad(400, "bad_name"); return }
        if m == "GET" { reply(c, 200, ["data": store.get(col, id) ?? NSNull()], close: close); return }
        if m == "PUT" {
          guard let b = bodyJSON(r), let d = b["data"] as? [String: Any] else { bad(400, "bad_data"); return }
          store.put(col, id, d); reply(c, 200, ["ok": true, "seq": bump(col)], close: close); return
        }
        if m == "PATCH" {
          guard let b = bodyJSON(r) else { bad(400, "bad_json"); return }
          guard let cur = store.get(col, id) else { bad(404, "not_found"); return }
          let next = PosServer.merge(cur, b["patch"] ?? [String: Any]())
          store.put(col, id, next); reply(c, 200, ["ok": true, "data": next, "seq": bump(col)], close: close); return
        }
        if m == "DELETE" { store.del(col, id); reply(c, 200, ["ok": true, "seq": bump(col)], close: close); return }
      }
      if a == "lease" && seg.count == 4 && m == "POST" {
        let col = seg[2], id = seg[3]
        guard PosServer.ok(PosServer.nameRe, col), PosServer.ok(PosServer.nameRe, id), let b = bodyJSON(r), let holder = b["holder"] else { bad(400, "bad_lease"); return }
        let ttl = max(1000, min(600000, (b["ttlMs"] as? NSNumber)?.intValue ?? 30000))
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let iso = ISO8601DateFormatter()
        if let cur = store.get(col, id) as? [String: Any], "\(cur["holder"] ?? "")" != "\(holder)", let u = (cur["untilMs"] as? NSNumber)?.intValue, u > now {
          reply(c, 200, ["acquired": false, "expiresAt": iso.string(from: Date(timeIntervalSince1970: Double(u) / 1000))], close: close); return
        }
        let exp = now + ttl
        let at = iso.string(from: Date(timeIntervalSince1970: Double(exp) / 1000))
        store.put(col, id, ["holder": "\(holder)", "untilMs": exp, "until": at])
        reply(c, 200, ["acquired": true, "expiresAt": at], close: close); return
      }
      if a == "changes" && m == "GET" {
        let n = Int(Double(r.query["since"] ?? "0") ?? 0)
        let wait = min(55.0, Double(r.query["wait"] ?? "25") ?? 25)
        if n != seq { reply(c, 200, ["seq": seq, "cols": since(n)], close: close); return }
        var done = false
        let fin: () -> Void = { [weak self] in
          guard let self = self, !done else { return }
          done = true
          self.reply(c, 200, ["seq": self.seq, "cols": self.since(n)], close: close)
        }
        waiters.append(fin)
        q.asyncAfter(deadline: .now() + wait) { fin() }
        return
      }
      if a == "asset" && seg.count == 2 && m == "POST" {
        let ty = (r.headers["content-type"] ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard let e = PosServer.ext[ty] else { bad(415, "bad_type"); return }
        let id = PosServer.hex(count: 10) + "." + e
        do { try r.body.write(to: assetDir.appendingPathComponent(id)) } catch { bad(500, "write_failed"); return }
        reply(c, 200, ["id": id, "sizeBytes": r.body.count, "contentType": ty], close: close); return
      }
      if a == "asset" && seg.count == 3 && m == "DELETE" {
        if PosServer.ok(PosServer.assetRe, seg[2]) { try? FileManager.default.removeItem(at: assetDir.appendingPathComponent(seg[2])) }
        reply(c, 200, ["ok": true], close: close); return
      }
      if a == "export" && m == "GET" {
        reply(c, 200, ["app": "coconut-pos-offline", "exportedAt": ISO8601DateFormatter().string(from: Date()), "collections": store.all()], close: close,
              extra: ["Content-Disposition": "attachment; filename=\"coconut-pos-backup.json\""]); return
      }
      bad(404, "not_found"); return
    }
    if seg.count == 2 && seg[0] == "assets" && PosServer.ok(PosServer.assetRe, seg[1]) {
      guard let d = try? Data(contentsOf: assetDir.appendingPathComponent(seg[1])) else { bad(404, "not_found"); return }
      send(c, 200, PosServer.type(seg[1]), d, close: close, extra: ["Cache-Control": "public, max-age=31536000, immutable"]); return
    }
    var rel = p == "/" ? "index.html" : String(p.dropFirst())
    if rel.hasSuffix("/") { rel += "index.html" }
    if rel.contains("..") { bad(403, "forbidden"); return }
    var url = wwwDir.appendingPathComponent(rel)
    if !FileManager.default.fileExists(atPath: url.path) {
      if rel.contains(".") { bad(404, "not_found"); return }
      rel = "index.html"; url = wwwDir.appendingPathComponent(rel)
    }
    guard let d = try? Data(contentsOf: url) else { bad(404, "not_found"); return }
    send(c, 200, PosServer.type(rel), d, close: close, extra: ["Cache-Control": "no-cache"])
  }

  static func type(_ name: String) -> String { mime[(name as NSString).pathExtension.lowercased()] ?? "application/octet-stream" }
}
