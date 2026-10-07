import AppKit
import Foundation
import HUDCore

// MARK: - Token counting (background, incremental over today's transcripts)

final class TokenCounter {
  private var day = Date.distantPast
  private var offsets: [String: UInt64] = [:]
  private var msgs: [String: [String: (n: Int, today: Bool, cost: Double)]] = [:]
  private var usage: [String: Usage] = [:]
  private let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  private let marker = Data("\"assistant\"".utf8)

  func scan() -> [String: Usage] {
    let today = Calendar.current.startOfDay(for: Date())
    if today != day { day = today; offsets = [:]; msgs = [:]; usage = [:] }
    let files = FileManager.default.enumerator(at: projectsDir, includingPropertiesForKeys: [.contentModificationDateKey])
    while let url = files?.nextObject() as? URL {
      guard url.pathExtension == "jsonl",
            let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            mod >= today else { continue }
      read(url.path)
    }
    return usage
  }

  private func read(_ path: String) {
    guard let h = FileHandle(forReadingAtPath: path) else { return }
    defer { try? h.close() }
    var off = offsets[path] ?? 0
    let size = (try? h.seekToEnd()) ?? 0
    if size < off { off = 0; msgs[path] = [:] }
    guard size > off else { return }
    try? h.seek(toOffset: off)
    guard let data = try? h.readToEnd(), let nl = data.lastIndex(of: 10) else { return }
    offsets[path] = off + UInt64(nl - data.startIndex + 1)
    var u = usage[path] ?? Usage()
    var m = msgs[path] ?? [:]
    for line in data[..<nl].split(separator: 10) where line.range(of: marker) != nil {
      guard let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            j["type"] as? String == "assistant", let msg = j["message"] as? [String: Any] else { continue }
      if let parts = msg["content"] as? [[String: Any]],
         let text = parts.last(where: { $0["type"] as? String == "text" })?["text"] as? String {
        u.lastText = text.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard let us = msg["usage"] as? [String: Any], let id = msg["id"] as? String else { continue }
      let n = { (k: String) in us[k] as? Int ?? 0 }
      u.context = n("input_tokens") + n("cache_creation_input_tokens") + n("cache_read_input_tokens")
      let isToday = (j["timestamp"] as? String).flatMap(iso.date(from:)).map { $0 >= day } ?? true
      let cw = n("cache_creation_input_tokens")
      let cw1h = min(cw, (us["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int ?? 0)
      let pr = price(msg["model"] as? String ?? "")
      let cost = (Double(n("input_tokens")) * pr.i + Double(n("output_tokens")) * pr.o + Double(cw - cw1h) * pr.i * 1.25
        + Double(cw1h) * pr.i * 2 + Double(n("cache_read_input_tokens")) * pr.r) / 1e6
      // Most of the context written again = the cache had expired, so the whole history was paid at full price.
      if m[id] == nil, isToday, cw >= 50_000, cw * 2 > u.context { u.recache += cw }
      if let model = msg["model"] as? String, !model.hasPrefix("<") { u.model = model }
      m[id] = (n("input_tokens") + cw + n("output_tokens"), isToday, cost)
    }
    u.tokens = m.values.reduce(0) { $0 + $1.n }
    u.today = m.values.reduce(0) { $0 + ($1.today ? $1.n : 0) }
    u.cost = m.values.reduce(0) { $0 + $1.cost }
    u.todayCost = m.values.reduce(0) { $0 + ($1.today ? $1.cost : 0) }
    msgs[path] = m
    usage[path] = u
  }
}

