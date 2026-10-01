// Claude HUD — an edge drawer + toasts for Claude Code sessions running in Cursor.
// Fed by hooks (see install.sh): events.jsonl = session state, req/ + ans/ = permission
// requests answered from here, limits.json = 5-hour / weekly usage.
import AppKit
import Carbon
import SwiftUI

let home = FileManager.default.homeDirectoryForCurrentUser
let hudDir = home.appendingPathComponent(".claude/hud")
let eventsURL = hudDir.appendingPathComponent("events.jsonl")
let reqDir = hudDir.appendingPathComponent("req")
let ansDir = hudDir.appendingPathComponent("ans")
let limitsURL = hudDir.appendingPathComponent("limits.json")
let projectsDir = home.appendingPathComponent(".claude/projects")
let columnWidth: CGFloat = 400
var hudPanel: NSPanel?
var hotKeyAction: (() -> Void)?

// MARK: - Model

enum Phase: Int {
  case permission, done, working, ready, ended  // sort order: most urgent first
  var color: Color {
    switch self {
    case .permission: Color(red: 1, green: 0.67, blue: 0.32)
    case .done: Color(red: 0.38, green: 0.96, blue: 0.74)
    case .working: Color(red: 0.45, green: 0.72, blue: 1)
    case .ready: Color(white: 0.62)
    case .ended: Color(white: 0.42)
    }
  }
  var label: String { ["Needs you", "Your turn", "Working", "Ready", "Ended"][rawValue] }
}

let red = Color(red: 1, green: 0.45, blue: 0.5)

struct Request: Equatable {
  let id: String, tool: String, detail: String
  var always: String?        // human label of Claude's own "don't ask again" suggestion
  var alwaysJSON: String?    // that suggestion, passed back as updatedPermissions
}

struct Session: Identifiable, Equatable {
  let id: String
  var cwd: String
  var phase: Phase
  var since: Date
  var pid: Int32 = 0
  var transcript = ""
  var activity = ""
  var request: Request?
  var name: String { (cwd as NSString).lastPathComponent }
}

struct Usage: Equatable { var tokens = 0, today = 0, context = 0, lastText = "" }
struct Limit: Equatable { let pct: Double, resets: Date; var eta: TimeInterval? }

struct Toast: Identifiable, Equatable {
  let id = UUID()
  let session: String  // "" = a usage notice
  let text: String
  var title = ""
  let created = Date()
}

func fmt(_ n: Int) -> String {
  n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.0fk", Double(n) / 1e3) : "\(n)"
}

func span(_ s: TimeInterval) -> String {
  let s = max(0, Int(s)), h = s / 3600, m = s % 3600 / 60
  return h >= 24 ? "\(h / 24)d \(h % 24)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
}

/// The Claude process's own working directory = the Cursor workspace (a hook's cwd follows `cd`).
func processCwd(_ pid: Int32) -> String? {
  var info = proc_vnodepathinfo()
  let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
  guard pid > 1, proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
  return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
}

// MARK: - Token counting (background, incremental over today's transcripts)

final class TokenCounter {
  private var day = Date.distantPast
  private var offsets: [String: UInt64] = [:]
  private var msgs: [String: [String: (n: Int, today: Bool)]] = [:]
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
      m[id] = (n("input_tokens") + n("cache_creation_input_tokens") + n("output_tokens"), isToday)
    }
    u.tokens = m.values.reduce(0) { $0 + $1.n }
    u.today = m.values.reduce(0) { $0 + ($1.today ? $1.n : 0) }
    msgs[path] = m
    usage[path] = u
  }
}

// MARK: - Store

final class Store: ObservableObject {
  @Published var sessions: [String: Session] = [:]
  @Published var usage: [String: Usage] = [:]
  @Published var toasts: [Toast] = []
  @Published var drawerOpen = false
  @Published var pinned = false      // opened from the keyboard: stays until Esc / hotkey
  @Published var selected = 0
  @Published var replyTarget: String?
  @Published var fiveHour: Limit?
  @Published var week: Limit?
  @Published var dnd = UserDefaults.standard.bool(forKey: "dnd") { didSet { UserDefaults.standard.set(dnd, forKey: "dnd") } }
  @Published var inMeeting = false
  var onLimits: (() -> Void)?
  var hoveredToast: UUID?
  var hitRects: [CGRect] = []
  private var offset: UInt64 = 0
  private var passthrough: [String: Date] = [:]
  private var limitsMod = Date.distantPast
  private var samples: [String: [(t: Date, p: Double)]] = [:]
  private var warned = Set<String>()
  private let counter = TokenCounter()
  private let queue = DispatchQueue(label: "hud", qos: .utility)
  static let spring = Animation.spring(response: 0.5, dampingFraction: 0.84)

  init() {
    let fm = FileManager.default
    for d in [reqDir, ansDir] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
    for f in (try? fm.contentsOfDirectory(at: ansDir, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: f) }
    var ss = [String: Session]()
    readEvents(&ss, alert: false)  // rebuild state from history quietly
    sessions = ss
    if offset > 2_000_000 { try? Data().write(to: eventsURL); offset = 0 }
    refreshUsage()
    fetchLimits()
    Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in self?.tick() }
    Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.refreshUsage() }
    Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.fetchLimits() }
  }

  var quiet: Bool { dnd || inMeeting }
  var sorted: [Session] {
    sessions.values.filter { $0.phase != .ready || usage($0).tokens > 0 }.sorted { ($0.phase.rawValue, $1.since) < ($1.phase.rawValue, $0.since) }
  }
  var urgent: Phase? { sorted.first?.phase }
  var todayTokens: Int { usage.values.reduce(0) { $0 + $1.today } }
  func usage(_ s: Session) -> Usage {
    usage[s.transcript] ?? usage.first { $0.key.hasSuffix("/\(s.id).jsonl") }?.value ?? Usage()
  }

  /// Runs ~3×/s. Only publishes when something actually changed, so SwiftUI stays idle otherwise.
  private func tick() {
    var ss = sessions
    readEvents(&ss, alert: true)
    readRequests(&ss)
    let now = Date()
    for (id, s) in ss where s.phase != .ended && s.pid > 1 && kill(s.pid, 0) != 0 {
      ss[id]?.phase = .ended
      ss[id]?.since = now
      ss[id]?.activity = ""
    }
    ss = ss.filter {
      let age = now.timeIntervalSince($0.value.since)
      return $0.value.phase == .ended ? age < 60 : age < 8 * 3600
    }
    if ss != sessions {
      let shape = { (d: [String: Session]) in d.mapValues { "\($0.phase)\($0.request?.id ?? "")" } }
      if shape(ss) != shape(sessions) { withAnimation(Store.spring) { sessions = ss } } else { sessions = ss }
    }
    let kept = toasts.filter { t in
      if t.id == hoveredToast { return true }
      if t.session.isEmpty { return now.timeIntervalSince(t.created) < 12 }
      guard let s = ss[t.session] else { return false }
      return s.phase == .permission || replyTarget == t.session || now.timeIntervalSince(t.created) < 9
    }
    if kept != toasts { withAnimation(Store.spring) { toasts = kept } }
  }

  // MARK: usage

  private func refreshUsage() {
    let mod = (try? limitsURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    if let mod, mod != limitsMod, let d = try? Data(contentsOf: limitsURL),
       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
      limitsMod = mod
      func lim(_ k: String, _ label: String) -> Limit? {
        guard let o = j[k] as? [String: Any], let p = o["used_percentage"] as? Double else { return nil }
        let r = Date(timeIntervalSince1970: o["resets_at"] as? Double ?? 0)
        if r < Date() { return Limit(pct: 0, resets: r) }
        // Forecast: burn rate over the last hour of samples → time until 100%.
        var arr = (samples[k] ?? []).filter { Date().timeIntervalSince($0.t) < 3600 && $0.p <= p }
        arr.append((Date(), p))
        samples[k] = arr
        var eta: TimeInterval?
        if let first = arr.first, p > first.p {
          let left = (100 - p) / ((p - first.p) / Date().timeIntervalSince(first.t))
          if left < r.timeIntervalSinceNow { eta = left }
        }
        for th in [80.0, 95.0] where p >= th && warned.insert("\(k)\(th)\(r.timeIntervalSince1970)").inserted {
          notice("\(label) usage at \(Int(p))%", eta.map { "At this pace you hit the limit in ~\(span($0))" } ?? "Resets in \(span(r.timeIntervalSinceNow))")
        }
        return Limit(pct: p, resets: r, eta: eta)
      }
      let (f, w) = (lim("five_hour", "5-hour"), lim("seven_day", "Weekly"))
      if f != fiveHour { fiveHour = f }
      if w != week { week = w }
      onLimits?()
    }
    let meeting = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier?.lowercased().contains("cpthost") == true }
    if meeting != inMeeting { inMeeting = meeting }
    queue.async { [counter] in
      let u = counter.scan()
      DispatchQueue.main.async { if u != self.usage { self.usage = u } }
    }
  }

  /// 5-hour / weekly usage from the endpoint `/usage` uses, signed in with Claude Code's own login
  /// (read via /usr/bin/security, which already has Keychain access). Saved in the statusline's format.
  private func fetchLimits() {
    queue.async {
      let p = Process(), out = Pipe()
      p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
      p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
      p.standardOutput = out
      p.standardError = FileHandle.nullDevice
      guard (try? p.run()) != nil else { return }
      let data = out.fileHandleForReading.readDataToEndOfFile()
      p.waitUntilExit()
      guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = (j["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String else { return }
      var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 10)
      req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
      URLSession.shared.dataTask(with: req) { d, r, _ in
        guard (r as? HTTPURLResponse)?.statusCode == 200, let d,
              let u = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        var limits: [String: Any] = [:]
        for k in ["five_hour", "seven_day"] {
          guard let o = u[k] as? [String: Any], let pct = o["utilization"] as? Double, let r = o["resets_at"] as? String,
                let date = ISO8601DateFormatter().date(from: r.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
          else { continue }
          limits[k] = ["used_percentage": pct, "resets_at": date.timeIntervalSince1970]
        }
        if !limits.isEmpty, let out = try? JSONSerialization.data(withJSONObject: limits) {
          try? out.write(to: limitsURL, options: .atomic)
        }
      }.resume()
    }
  }

  // MARK: events.jsonl

  private func readEvents(_ ss: inout [String: Session], alert: Bool) {
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

  private func apply(_ j: [String: Any], _ ss: inout [String: Session], alert doAlert: Bool) {
    guard let id = j["s"] as? String, let ev = j["e"] as? String else { return }
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
    let keep = (prev == .working && next == .working) || (s.request != nil && (next == .working || next == .permission))
    if !keep { s.phase = next; s.since = ts }
    ss[id] = s
    guard doAlert, !keep, prev != next else { return }
    switch next {
    case .permission where Date().timeIntervalSince(passthrough[id] ?? .distantPast) > 120:
      self.alert(s, msg.isEmpty ? "Needs your attention" : msg, sound: "Glass")
    case .done: self.alert(s, "", sound: "Hero")
    case .ended: self.alert(s, "Session ended", sound: "Pop")
    default: break
    }
  }

  // MARK: permission requests (req/<id>.json written by perm.sh, answered via ans/<id>)

  private func readRequests(_ ss: inout [String: Session]) {
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
      alert(s, "", sound: "Glass")
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

  // MARK: actions

  private func alert(_ s: Session, _ text: String, sound: String) {
    guard !quiet else { return }  // do-not-disturb: state still updates, the edge still glows
    NSSound(named: sound)?.play()
    var t = toasts.filter { $0.session != s.id }
    t.append(Toast(session: s.id, text: text))
    if t.count > 4, let i = t.firstIndex(where: { sessions[$0.session]?.phase != .permission }) { t.remove(at: i) }
    withAnimation(Store.spring) { toasts = t }
  }

  private func notice(_ title: String, _ text: String) {
    guard !quiet else { return }
    NSSound(named: "Submarine")?.play()
    withAnimation(Store.spring) { toasts.append(Toast(session: "", text: text, title: title)) }
  }

  func dismiss(_ t: Toast) { withAnimation(Store.spring) { toasts.removeAll { $0.id == t.id } } }

  func close() {
    withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
      drawerOpen = false
      pinned = false
      replyTarget = nil
    }
  }

  /// Focus the Cursor window holding the session's folder, then its exact chat tab (optionally pre-filling a reply).
  func jump(_ s: Session, prompt: String? = nil) {
    NSWorkspace.shared.open([URL(fileURLWithPath: s.cwd)],
                            withApplicationAt: URL(fileURLWithPath: "/Applications/Cursor.app"),
                            configuration: NSWorkspace.OpenConfiguration())
    var c = URLComponents(string: "cursor://anthropic.claude-code/open")!
    c.queryItems = [URLQueryItem(name: "session", value: s.id)]
    if let p = prompt, !p.isEmpty { c.queryItems?.append(URLQueryItem(name: "prompt", value: p)) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSWorkspace.shared.open(c.url!) }
    close()
    withAnimation(Store.spring) { toasts.removeAll { $0.session == s.id } }
  }

  func end(_ s: Session) {
    if s.pid > 1 { kill(s.pid, SIGTERM) }
    withAnimation(Store.spring) {
      sessions[s.id]?.phase = .ended
      sessions[s.id]?.since = Date()
    }
  }

  /// Keyboard control while the drawer is open. Returns true when the key was handled.
  func key(_ e: NSEvent) -> Bool {
    guard drawerOpen, replyTarget == nil else { return false }
    let list = sorted
    let s = list.indices.contains(selected) ? list[selected] : nil
    switch (e.keyCode, e.charactersIgnoringModifiers ?? "") {
    case (53, _): close()
    case (125, _): withAnimation(.easeOut(duration: 0.15)) { selected = min(selected + 1, max(0, list.count - 1)) }
    case (126, _): withAnimation(.easeOut(duration: 0.15)) { selected = max(selected - 1, 0) }
    case (36, _): if let s { jump(s) }
    case (_, "a"): if let s { answer(s, .allow) }
    case (_, "w"): if let s, s.request?.always != nil { answer(s, .always) }
    case (_, "d"): if let s { answer(s, .deny) }
    case (_, "r"): if let s, s.phase != .ended { withAnimation(Store.spring) { replyTarget = s.id } }
    default: return false
    }
    return true
  }
}

// MARK: - Visual primitives

struct HitKey: PreferenceKey {
  static var defaultValue: [CGRect] = []
  static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

extension View {
  /// Marks this view as interactive; everywhere else clicks fall through to the apps below.
  func hitArea() -> some View {
    background(GeometryReader { Color.clear.preference(key: HitKey.self, value: [$0.frame(in: .global)]) })
  }

  func glass(_ r: CGFloat, tint: Color) -> some View {
    let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
    return background {
      ZStack {
        shape.fill(.black.opacity(0.3)).shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        shape.fill(.ultraThinMaterial)
        shape.fill(LinearGradient(colors: [Color(white: 0.09).opacity(0.78), Color(white: 0.02).opacity(0.9)],
                                  startPoint: .top, endPoint: .bottom))
        shape.fill(RadialGradient(colors: [tint.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 280))
      }
    }
    .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.04), tint.opacity(0.4)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
  }
}

/// Slide in from the screen edge, scaling up as it fades in. (No blur: a resting blur(0) keeps the
/// whole view rendering off-screen on the CPU.)
struct EdgeSlide: ViewModifier {
  let x: CGFloat, scale: CGFloat
  func body(content: Content) -> some View {
    content.scaleEffect(scale, anchor: .trailing).offset(x: x).opacity(x == 0 ? 1 : 0)
  }
}

extension AnyTransition {
  static let edge = AnyTransition.asymmetric(
    insertion: .modifier(active: EdgeSlide(x: 380, scale: 0.9), identity: EdgeSlide(x: 0, scale: 1)),
    removal: .modifier(active: EdgeSlide(x: 380, scale: 0.97), identity: EdgeSlide(x: 0, scale: 1)))
}

/// Spinner (working) / sonar ping (needs you) drawn with Core Animation, so it costs no SwiftUI redraws.
struct Motion: NSViewRepresentable {
  let phase: Phase
  func makeNSView(context: Context) -> NSView {
    let v = NSView()
    v.wantsLayer = true
    let ring = CAShapeLayer()
    ring.fillColor = nil
    ring.strokeColor = NSColor(phase.color).cgColor
    ring.lineCap = .round
    let box = CGRect(x: 0, y: 0, width: 18, height: 18)
    ring.frame = box
    if phase == .working {
      ring.path = CGPath(ellipseIn: box.insetBy(dx: 1.5, dy: 1.5), transform: nil)
      ring.lineWidth = 1.6
      ring.strokeEnd = 0.68
      let a = CABasicAnimation(keyPath: "transform.rotation.z")
      a.fromValue = 0
      a.toValue = -2 * Double.pi
      a.duration = 1.1
      a.repeatCount = .infinity
      ring.add(a, forKey: "spin")
    } else {
      ring.path = CGPath(ellipseIn: box.insetBy(dx: 5, dy: 5), transform: nil)
      ring.lineWidth = 1.5
      let scale = CABasicAnimation(keyPath: "transform.scale")
      scale.fromValue = 1
      scale.toValue = 2.2
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 0.9
      fade.toValue = 0
      let g = CAAnimationGroup()
      g.animations = [scale, fade]
      g.duration = 1.3
      g.timingFunction = CAMediaTimingFunction(name: .easeOut)
      g.repeatCount = .infinity
      ring.add(g, forKey: "ping")
    }
    v.layer?.addSublayer(ring)
    return v
  }
  func updateNSView(_ v: NSView, context: Context) {}
}

struct StatusDot: View {
  let phase: Phase
  var body: some View {
    ZStack {
      if phase == .working || phase == .permission { Motion(phase: phase).frame(width: 18, height: 18) }
      Circle().fill(RadialGradient(colors: [phase.color.opacity(0.45), .clear], center: .center, startRadius: 2, endRadius: 8))
        .frame(width: 16, height: 16)
      Circle().fill(phase.color).frame(width: 7, height: 7)
    }
    .frame(width: 18, height: 18)
    .id(phase)
  }
}

struct Pill: View {
  let title: String
  var icon: String?
  var tint: Color = .white
  var primary = false
  var key: String?
  let action: () -> Void
  @State private var hover = false
  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        if let icon { Image(systemName: icon).font(.system(size: 9.5, weight: .bold)) }
        Text(title)
        if let key { Text(key).font(.system(size: 9, weight: .bold, design: .monospaced)).opacity(0.5) }
      }
      .font(.system(size: 11.5, weight: .semibold, design: .rounded))
      .foregroundStyle(primary ? Color.black.opacity(0.85) : tint.opacity(hover ? 1 : 0.85))
      .padding(.horizontal, 11).padding(.vertical, 6)
      .background(Capsule().fill(primary ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(hover ? 0.16 : 0.08))))
      .overlay(Capsule().strokeBorder(.white.opacity(primary ? 0.3 : 0.08)))
    }
    .buttonStyle(Press())
    .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
  }
}

struct Press: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1)
      .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
  }
}

/// Context-window ring: how close the session is to auto-compact.
struct ContextRing: View {
  let tokens: Int
  var body: some View {
    let window = tokens > 200_000 ? 1_000_000.0 : 200_000.0
    let f = min(1, Double(tokens) / window)
    let c = f > 0.85 ? red : f > 0.7 ? Phase.permission.color : Color.white.opacity(0.45)
    HStack(spacing: 4) {
      ZStack {
        Circle().stroke(.white.opacity(0.1), lineWidth: 2)
        Circle().trim(from: 0, to: f).stroke(c, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
      }
      .frame(width: 10, height: 10)
      Text(fmt(tokens)).font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(c)
    }
    .help("Context: \(fmt(tokens)) of \(fmt(Int(window))) (\(Int(f * 100))%)")
  }
}

// MARK: - Pieces shared by cards and toasts

struct RequestBlock: View {
  @ObservedObject var store: Store
  let s: Session
  let r: Request
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 6) {
        Image(systemName: "lock.shield.fill").foregroundStyle(Phase.permission.color)
        Text(r.tool).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
      }
      .font(.system(size: 11))
      Text(r.detail)
        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.78))
        .lineLimit(5).textSelection(.enabled)
        .padding(9).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.black.opacity(0.4)))
      HStack(spacing: 6) {
        Pill(title: "Allow", icon: "checkmark", tint: Phase.permission.color, primary: true) { store.answer(s, .allow) }
        if let always = r.always {
          Pill(title: "Always", icon: "checkmark.seal", tint: Phase.permission.color) { store.answer(s, .always) }
            .help("Allow and don't ask again: \(always)")
        }
        Pill(title: "Deny", icon: "xmark", tint: red) { store.answer(s, .deny) }
        Spacer(minLength: 0)
        Pill(title: "Cursor", icon: "arrow.up.right") { store.answer(s, .cursor) }
          .help("Answer in Cursor instead")
      }
      if let always = r.always {
        Text("Always = don't ask again for \(always)").font(.system(size: 9.5, design: .monospaced))
          .foregroundStyle(.white.opacity(0.35)).lineLimit(1).truncationMode(.middle)
      }
    }
  }
}

struct ReplyField: View {
  @ObservedObject var store: Store
  let s: Session
  @State private var draft = ""
  @FocusState private var focused: Bool
  var body: some View {
    HStack(spacing: 8) {
      TextField("Reply to \(s.name)…", text: $draft)
        .textFieldStyle(.plain).font(.system(size: 12.5, design: .rounded))
        .focused($focused)
        .onSubmit { store.jump(s, prompt: draft) }
        .onExitCommand { withAnimation(Store.spring) { store.replyTarget = nil } }
      Image(systemName: "return").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(draft.isEmpty ? 0.25 : 0.7))
    }
    .padding(.horizontal, 11).padding(.vertical, 9)
    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.black.opacity(0.45)))
    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Phase.done.color.opacity(focused ? 0.55 : 0.15)))
    .onAppear {
      hudPanel?.makeKey()
      DispatchQueue.main.async { focused = true }
    }
  }
}

// MARK: - Drawer

struct SessionCard: View {
  @ObservedObject var store: Store
  let s: Session
  let index: Int
  let selected: Bool
  @State private var hover = false
  @State private var shown = false
  @State private var confirmEnd = false

  var body: some View {
    let u = store.usage(s)
    let replying = store.replyTarget == s.id
    let lit = hover || selected
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 10) {
        StatusDot(phase: s.phase)
        VStack(alignment: .leading, spacing: 2) {
          Text(s.name).font(.system(size: 13.5, weight: .semibold, design: .rounded)).lineLimit(1)
          HStack(spacing: 5) {
            Text(s.phase.label).foregroundStyle(s.phase.color)
            Text("·")
            TimelineView(.everyMinute) { _ in Text(s.since.timeIntervalSinceNow > -60 ? "just now" : span(-s.since.timeIntervalSinceNow)) }
          }
          .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.45))
        }
        Spacer(minLength: 6)
        VStack(alignment: .trailing, spacing: 3) {
          Text(fmt(u.tokens)).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
            .help("Tokens this session (input + cache writes + output)")
          ContextRing(tokens: u.context)
        }
      }
      if s.phase == .working, !s.activity.isEmpty {
        HStack(spacing: 6) {
          Rectangle().fill(Phase.working.color.opacity(0.7)).frame(width: 2, height: 12)
          Text(s.activity).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
            .lineLimit(1).truncationMode(.middle)
        }
        .transition(.opacity)
      }
      if let r = s.request {
        RequestBlock(store: store, s: s, r: r)
      } else if s.phase == .done, !u.lastText.isEmpty {
        Text(u.lastText).font(.system(size: 11.5, design: .rounded)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
      }
      if (lit || replying) && s.request == nil {
        HStack(spacing: 6) {
          Pill(title: "Open", icon: "arrow.up.right", key: selected ? "↩" : nil) { store.jump(s) }
          if s.phase != .ended {
            Pill(title: "Reply", icon: "arrowshape.turn.up.left.fill", tint: Phase.done.color, key: selected ? "R" : nil) {
              withAnimation(Store.spring) { store.replyTarget = replying ? nil : s.id }
            }
          }
          Spacer()
          if s.phase != .ended {
            Pill(title: confirmEnd ? "End session?" : "End", icon: "power", tint: red) {
              if confirmEnd { store.end(s) } else {
                withAnimation(.easeOut(duration: 0.15)) { confirmEnd = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation { confirmEnd = false } }
              }
            }
          }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
      if replying { ReplyField(store: store, s: s).transition(.opacity.combined(with: .scale(scale: 0.97))) }
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(lit ? 0.075 : 0.04)))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
      .strokeBorder(s.phase.color.opacity(s.phase == .permission ? 0.5 : selected ? 0.45 : hover ? 0.22 : 0.07)))
    .contentShape(RoundedRectangle(cornerRadius: 16))
    .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
    .onTapGesture { store.jump(s) }
    .help(s.cwd)
    .offset(x: shown ? 0 : 36).opacity(shown ? 1 : 0)
    .onAppear { withAnimation(Store.spring.delay(0.05 + Double(index) * 0.045)) { shown = true } }
  }
}

struct LimitBar: View {
  let title: String
  let limit: Limit?
  var body: some View {
    let pct = min(100, limit?.pct ?? 0)
    let colors: [Color] = pct > 85 ? [Color(red: 1, green: 0.4, blue: 0.5), Color(red: 1, green: 0.25, blue: 0.4)]
      : pct > 60 ? [Color(red: 1, green: 0.8, blue: 0.35), Phase.permission.color]
      : [Color(red: 0.4, green: 0.95, blue: 0.95), Phase.working.color]
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(1.4).foregroundStyle(.white.opacity(0.45))
        Spacer()
        Text(limit.map { "\(Int($0.pct.rounded()))%" } ?? "—").font(.system(size: 13, weight: .semibold, design: .monospaced))
      }
      GeometryReader { g in
        ZStack(alignment: .leading) {
          Capsule().fill(.white.opacity(0.07))
          Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
            .frame(width: max(5, g.size.width * pct / 100))
            .shadow(color: colors[1].opacity(0.6), radius: 5)
        }
      }
      .frame(height: 5)
      Group {
        if let eta = limit?.eta {
          Text("limit in ~\(span(eta)) at this pace").foregroundStyle(Phase.permission.color.opacity(0.85))
        } else {
          Text(limit.map { "resets in \(span($0.resets.timeIntervalSinceNow))" } ?? "waiting for data").foregroundStyle(.white.opacity(0.35))
        }
      }
      .font(.system(size: 9.5, weight: .medium, design: .rounded))
    }
  }
}

struct Drawer: View {
  @ObservedObject var store: Store
  var body: some View {
    let list = store.sorted
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .center, spacing: 8) {
        StatusDot(phase: store.urgent ?? .ready)
        Text("CLAUDE").font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(3).foregroundStyle(.white.opacity(0.75))
        Text("\(list.filter { $0.phase != .ended }.count) live")
          .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.4))
        Button { store.dnd.toggle() } label: {
          Image(systemName: store.quiet ? "moon.fill" : "moon")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(store.quiet ? Color(red: 0.7, green: 0.6, blue: 1) : .white.opacity(0.35))
            .frame(width: 22, height: 22)
            .background(Circle().fill(.white.opacity(store.quiet ? 0.1 : 0.04)))
        }
        .buttonStyle(Press())
        .help(store.inMeeting ? "Quiet: you're in a Zoom meeting" : store.dnd ? "Do not disturb is on" : "Do not disturb")
        Spacer()
        VStack(alignment: .trailing, spacing: 1) {
          Text(fmt(store.todayTokens)).font(.system(size: 16, weight: .semibold, design: .monospaced))
            .contentTransition(.numericText())
          Text("tokens today").font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.4))
        }
      }
      .contextMenu { Button("Quit Claude HUD") { NSApp.terminate(nil) } }

      HStack(spacing: 16) {
        LimitBar(title: "5-HOUR", limit: store.fiveHour)
        LimitBar(title: "WEEKLY", limit: store.week)
      }

      Rectangle().fill(LinearGradient(colors: [.clear, .white.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing))
        .frame(height: 1)

      if list.isEmpty {
        VStack(spacing: 6) {
          Image(systemName: "sparkles").font(.system(size: 18)).foregroundStyle(.white.opacity(0.3))
          Text("No sessions yet").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
      } else {
        let cards = VStack(spacing: 8) {
          ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
            SessionCard(store: store, s: s, index: i, selected: store.pinned && i == store.selected)
          }
        }
        ViewThatFits(in: .vertical) {
          cards
          ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) { cards }
              .onChange(of: store.selected) { _, i in
                if list.indices.contains(i) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(list[i].id, anchor: .center) } }
              }
          }
        }
      }
      if store.pinned {
        Text("↑↓  ↩ open  A allow  W always  D deny  R reply")
          .font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.3))
          .frame(maxWidth: .infinity)
      }
    }
    .padding(16)
    .frame(width: 340)
    .glass(24, tint: (store.urgent ?? .working).color)
    .hitArea()
  }
}

// MARK: - Toasts

struct ToastCard: View {
  @ObservedObject var store: Store
  let t: Toast
  let s: Session
  var body: some View {
    let text = t.text.isEmpty ? store.usage(s).lastText : t.text
    let replying = store.replyTarget == s.id
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 9) {
        StatusDot(phase: s.phase)
        Text(s.name).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
        Text(s.phase.label.uppercased()).font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(1.2)
          .foregroundStyle(s.phase.color)
          .padding(.horizontal, 7).padding(.vertical, 3)
          .background(Capsule().fill(s.phase.color.opacity(0.13)))
        Spacer()
        DismissButton { store.dismiss(t) }
      }
      if let r = s.request {
        RequestBlock(store: store, s: s, r: r)
      } else {
        if !text.isEmpty {
          Text(text).font(.system(size: 12, design: .rounded)).foregroundStyle(.white.opacity(0.68)).lineLimit(3)
        }
        if replying {
          ReplyField(store: store, s: s)
        } else if s.phase != .ended {
          HStack(spacing: 6) {
            Pill(title: "Reply", icon: "arrowshape.turn.up.left.fill", tint: Phase.done.color, primary: s.phase == .done) {
              withAnimation(Store.spring) { store.replyTarget = s.id }
            }
            Pill(title: "Open", icon: "arrow.up.right") { store.jump(s) }
          }
        }
      }
    }
    .padding(14)
    .frame(width: 340)
    .glass(20, tint: s.phase.color)
    .overlay(alignment: .leading) { AccentBar(color: s.phase.color) }
    .contentShape(Rectangle())
    .onTapGesture { store.jump(s) }
    .onHover { store.hoveredToast = $0 ? t.id : nil }
    .hitArea()
  }
}

struct NoticeCard: View {
  @ObservedObject var store: Store
  let t: Toast
  var body: some View {
    let c = Phase.permission.color
    HStack(alignment: .top, spacing: 11) {
      Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: 16, weight: .semibold)).foregroundStyle(c)
      VStack(alignment: .leading, spacing: 3) {
        Text(t.title).font(.system(size: 13, weight: .semibold, design: .rounded))
        Text(t.text).font(.system(size: 11.5, design: .rounded)).foregroundStyle(.white.opacity(0.6))
      }
      Spacer()
      DismissButton { store.dismiss(t) }
    }
    .padding(14)
    .frame(width: 340)
    .glass(20, tint: c)
    .overlay(alignment: .leading) { AccentBar(color: c) }
    .onHover { store.hoveredToast = $0 ? t.id : nil }
    .hitArea()
  }
}

struct AccentBar: View {
  let color: Color
  var body: some View {
    Capsule().fill(color).frame(width: 3).padding(.vertical, 16).offset(x: 1)
      .background(Capsule().fill(LinearGradient(colors: [.clear, color.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)).frame(width: 12).padding(.vertical, 14))
  }
}

struct DismissButton: View {
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.5))
        .frame(width: 20, height: 20).background(Circle().fill(.white.opacity(0.07)))
    }
    .buttonStyle(Press())
    .accessibilityLabel("Dismiss")
  }
}

// MARK: - Root

struct EdgeHandle: View {
  let phase: Phase?
  @State private var pulse = false
  var body: some View {
    let c = phase?.color ?? .white.opacity(0.35)
    Capsule().fill(c.gradient)
      .frame(width: 4, height: phase == .permission ? 90 : 64)
      .background(Capsule().fill(LinearGradient(colors: [.clear, c.opacity(0.4)], startPoint: .leading, endPoint: .trailing)).frame(width: 14).offset(x: -5))
      .opacity(phase == nil ? 0.45 : phase == .permission && pulse ? 0.45 : 1)
      .animation(phase == .permission ? .easeInOut(duration: 0.7).repeatForever() : .default, value: pulse)
      .onAppear { pulse = true }
      .id(phase)
  }
}

struct Root: View {
  @ObservedObject var store: Store
  var body: some View {
    ZStack(alignment: .trailing) {
      Color.clear
      if store.drawerOpen {
        Drawer(store: store).padding(.trailing, 12).padding(.vertical, 18).transition(.edge)
      } else {
        EdgeHandle(phase: store.urgent).padding(.trailing, 1).transition(.opacity)
      }
    }
    .overlay(alignment: .topTrailing) {
      if !store.drawerOpen {
        VStack(alignment: .trailing, spacing: 10) {
          ForEach(store.toasts) { t in
            if t.session.isEmpty {
              NoticeCard(store: store, t: t).transition(.edge)
            } else if let s = store.sessions[t.session] {
              ToastCard(store: store, t: t, s: s).transition(.edge)
            }
          }
        }
        .padding(.top, 10).padding(.trailing, 12)
      }
    }
    .onPreferenceChange(HitKey.self) { store.hitRects = $0 }
    .environment(\.colorScheme, .dark)
    .foregroundStyle(.white)
  }
}

// MARK: - App

final class Panel: NSPanel {
  override var canBecomeKey: Bool { true }
}

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let store = Store()
  var panel: Panel!
  var statusItem: NSStatusItem!
  var edgeSince: Date?
  var leftSince: Date?

  func applicationDidFinishLaunching(_ n: Notification) {
    let host = NSHostingView(rootView: Root(store: store))
    host.sizingOptions = []
    panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.contentView = host
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.delegate = self
    hudPanel = panel
    place()
    panel.orderFrontRegardless()
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                           object: nil, queue: .main) { [weak self] _ in self?.place() }
    Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.track() }

    // Keyboard: ⌥Space toggles the drawer; arrows/letters drive it while it's open.
    hotKeyAction = { [weak self] in self?.toggle() }
    registerHotKey()
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.store.key(e) == true ? nil : e }

    // Menu bar: live 5-hour · weekly usage; click toggles the drawer.
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.target = self
    statusItem.button?.action = #selector(toggle)
    store.onLimits = { [weak self] in self?.updateStatus() }
    updateStatus()
  }

  func registerHotKey() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in hotKeyAction?(); return noErr }, 1, &spec, nil, nil)
    var ref: EventHotKeyRef?
    RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: 0x4855_4421, id: 1),
                        GetApplicationEventTarget(), 0, &ref)
  }

  @objc func toggle() {
    if store.drawerOpen { return store.close() }
    store.selected = 0
    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
      store.pinned = true
      store.drawerOpen = true
    }
    panel.makeKeyAndOrderFront(nil)
  }

  func updateStatus() {
    let f = store.fiveHour.map { "\(Int($0.pct.rounded()))%" } ?? "–"
    let w = store.week.map { "\(Int($0.pct.rounded()))%" } ?? "–"
    statusItem.button?.attributedTitle = NSAttributedString(
      string: " \(f) · \(w)", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)])
    statusItem.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude usage")
    statusItem.button?.imagePosition = .imageLeading
    statusItem.button?.toolTip = "Claude usage — 5-hour · weekly (⌥Space opens the drawer)"
  }

  func place() {
    guard let v = NSScreen.screens.first?.visibleFrame else { return }
    panel.setFrame(NSRect(x: v.maxX - columnWidth, y: v.minY, width: columnWidth, height: v.height), display: true)
  }

  /// Hover the right screen edge to open; leave the drawer to close. Clicks pass through everywhere but our cards.
  func track() {
    guard let screen = NSScreen.screens.first else { return }
    let m = NSEvent.mouseLocation, f = panel.frame
    let p = CGPoint(x: m.x - f.minX, y: f.maxY - m.y)
    let overUI = store.hitRects.contains { $0.insetBy(dx: -8, dy: -8).contains(p) }
    if panel.ignoresMouseEvents == overUI { panel.ignoresMouseEvents = !overUI }

    let atEdge = m.x >= screen.frame.maxX - 2 && f.minY...f.maxY ~= m.y
    edgeSince = atEdge ? (edgeSince ?? Date()) : nil
    if !store.drawerOpen, let t = edgeSince, Date().timeIntervalSince(t) > 0.12 {
      withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { store.drawerOpen = true }
    }
    guard store.drawerOpen, !store.pinned else { return }
    if overUI || atEdge || store.replyTarget != nil { leftSince = nil; return }
    leftSince = leftSince ?? Date()
    if Date().timeIntervalSince(leftSince!) > 0.4 { store.close() }
  }

  func windowDidResignKey(_ n: Notification) {
    if store.pinned { store.close() } else { withAnimation(Store.spring) { store.replyTarget = nil } }
  }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // no Dock icon
app.run()
