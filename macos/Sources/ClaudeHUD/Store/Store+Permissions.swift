import AppKit
import SwiftUI

extension Store {
  // MARK: permission requests (req/<id>.json written by perm.sh, answered via ans/<id>)

  func readRequests(_ ss: inout [String: Session]) {
    let fm = FileManager.default
    let files = ((try? fm.contentsOfDirectory(at: reqDir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
    if files.isEmpty && !ss.values.contains(where: { $0.request != nil }) { return }
    var live = Set<String>()
    for f in files {
      let rid = f.deletingPathExtension().lastPathComponent
      guard let d = try? Data(contentsOf: f), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let sid = j["session_id"] as? String else { continue }
      let pid = Int32(j["pid"] as? Int ?? 0)
      if pid > 1, kill(pid, 0) != 0 { try? fm.removeItem(at: f); continue }
      live.insert(rid)
      if ss[sid]?.request != nil { continue }  // one at a time per session
      let tool = j["tool_name"] as? String ?? "Tool"
      let input = j["tool_input"] as? [String: Any] ?? [:]
      let detail = ["command", "file_path", "url", "pattern", "query", "description", "prompt"]
        .lazy.compactMap { input[$0] as? String }.first
        ?? (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
      var r = Request(id: rid, tool: tool, detail: detail)
      if let sug = j["permission_suggestions"] as? [[String: Any]], !sug.isEmpty,
         let data = try? JSONSerialization.data(withJSONObject: sug) {
        r.alwaysJSON = String(data: data, encoding: .utf8)
        r.always = sug.map { s -> String in
          if let rules = s["rules"] as? [[String: Any]] {
            return rules.map { r in
              let t = r["toolName"] as? String ?? "", c = r["ruleContent"] as? String
              return c.map { "\(t)(\($0))" } ?? t
            }.joined(separator: ", ")
          }
          if let mode = s["mode"] as? String { return "mode: \(mode)" }
          if let dirs = s["directories"] as? [String] { return dirs.joined(separator: ", ") }
          return s["type"] as? String ?? "rule"
        }.joined(separator: " + ")
      }
      var s = ss[sid] ?? Session(id: sid, cwd: j["cwd"] as? String ?? "?", phase: .permission, since: Date())
      s.request = r
      s.phase = .permission
      s.since = Date()
      if s.pid < 2 { s.pid = pid; s.cwd = processCwd(pid) ?? s.cwd }
      if s.transcript.isEmpty { s.transcript = j["transcript_path"] as? String ?? "" }
      ss[sid] = s
      alert(s, "", sound: "Glass", pref: "notifyPermission")
    }
    for (id, s) in ss where s.request.map({ !live.contains($0.id) }) ?? false {
      ss[id]?.request = nil
      if s.phase == .permission { ss[id]?.phase = .working }
    }
  }

  enum Answer { case allow, always, deny, cursor }

  func answer(_ s: Session, _ a: Answer) {
    guard let r = s.request else { return jump(s) }
    let decision: String
    switch a {
    case .allow, .cursor: decision = #"{"behavior":"allow"}"#
    case .always: decision = #"{"behavior":"allow","updatedPermissions":"# + (r.alwaysJSON ?? "[]") + "}"
    case .deny: decision = #"{"behavior":"deny","message":"Denied from Claude HUD"}"#
    }
    let body = a == .cursor ? "" : #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":"# + decision + "}}"
    let tmp = ansDir.appendingPathComponent(r.id + ".tmp")
    try? body.write(to: tmp, atomically: false, encoding: .utf8)
    _ = try? FileManager.default.replaceItemAt(ansDir.appendingPathComponent(r.id), withItemAt: tmp)
    withAnimation(Store.spring) {
      sessions[s.id]?.request = nil
      if a != .cursor { sessions[s.id]?.phase = .working }
      toasts.removeAll { $0.session == s.id }
    }
    if a == .cursor { passthrough[s.id] = Date(); jump(s) }
  }

}
