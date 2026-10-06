import AppKit
import SwiftUI

extension Store {
  // MARK: events.jsonl

  func readEvents(_ ss: inout [String: Session], alert: Bool) {
    guard let h = try? FileHandle(forReadingFrom: eventsURL) else { return }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    if size < offset { offset = 0 }
    guard size > offset else { return }
    try? h.seek(toOffset: offset)
    guard let data = try? h.readToEnd(), let nl = data.lastIndex(of: 10) else { return }
    offset += UInt64(nl - data.startIndex + 1)  // a half-written line waits for next time
    for line in data[..<nl].split(separator: 10) {
      if let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { apply(j, &ss, alert: alert) }
    }
  }

  func apply(_ j: [String: Any], _ ss: inout [String: Session], alert doAlert: Bool) {
    guard let id = j["s"] as? String, let ev = j["e"] as? String else { return }
    if ev == "SubagentStart" || ev == "SubagentStop" {
      guard var s = ss[id], let aid = j["ai"] as? String else { return }
      s.agents[aid] = ev == "SubagentStart" ? (j["at"] as? String ?? "agent") : nil
      ss[id] = s
      return
    }
    let type = j["t"] as? String ?? "", msg = j["m"] as? String ?? ""
    let next: Phase
    switch ev {
    case "SessionStart": next = .ready
    case "UserPromptSubmit", "PreToolUse", "PostToolUse": next = .working
    case "Stop": next = .done
    case "SessionEnd": next = .ended
    case "Notification" where ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog"].contains(type):
      next = .permission
    default: return
    }
    let ts = (j["ts"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
    let prev = ss[id]?.phase
    if ss[id] == nil, let h = pendingHandoff, h.old != id, ts > h.at, ts.timeIntervalSince(h.at) < 900,
       (j["c"] as? String ?? "").hasPrefix(h.cwd) {
      retired[h.old] = id
      pendingHandoff = nil
    }
    var s = ss[id] ?? Session(id: id, cwd: j["c"] as? String ?? "?", phase: next, since: ts)
    if let p = j["p"] as? Int, p > 1, s.pid != Int32(p) {
      s.pid = Int32(p)
      if let c = processCwd(s.pid) { s.cwd = c }
    }
    if let tp = j["tp"] as? String, !tp.isEmpty { s.transcript = tp }
    if ev == "PreToolUse", let tool = j["tn"] as? String {
      let x = j["x"] as? String ?? ""
      s.activity = tool + (x.isEmpty ? "" : " · " + (x.hasPrefix("/") ? (x as NSString).lastPathComponent : x))
    } else if next == .done || next == .ended || ev == "UserPromptSubmit" {
      s.activity = ""
    }
    if next == .ended { s.agents = [:] }
    let keep = (prev == .working && next == .working) || (s.request != nil && (next == .working || next == .permission))
    if !keep { s.phase = next; s.since = ts }
    ss[id] = s
    guard doAlert, !keep, prev != next else { return }
    switch next {
    case .permission where Date().timeIntervalSince(passthrough[id] ?? .distantPast) > 120:
      self.alert(s, msg.isEmpty ? "Needs your attention" : msg, sound: "Glass", pref: "notifyPermission")
    case .done: self.alert(s, "", sound: "Hero", pref: "notifyDone")
    case .ended: self.alert(s, "Session ended", sound: "Pop", pref: "notifyEnded")
    default: break
    }
  }

}
