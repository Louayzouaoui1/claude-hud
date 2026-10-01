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
var hotKeyRef: EventHotKeyRef?

let prefs: UserDefaults = {
  let d = UserDefaults.standard
  d.register(defaults: ["theme": "aurora", "glass": 0.85, "edgeGlow": true, "edgeDelay": 0.12,
                        "notifyPermission": true, "notifyDone": true, "notifyEnded": true, "notifyUsage": true,
                        "sounds": true, "toastSeconds": 9.0, "meetingQuiet": true, "answerInHUD": true,
                        "hotkey": 0, "menuBar": true, "loginItem": true,
                        "heavyBurn": 1_000_000.0, "groupByWorkspace": true,
                        "idleMinutes": 10.0, "firstPrompt": "", "autoEndOld": true, "autoSend": true, "syncDevices": true])
  return d
}()

enum Theme: String, CaseIterable, Identifiable {
  case aurora, nebula, ember, mono
  var id: String { rawValue }
  var colors: [Color] {
    switch self {
    case .aurora: [Color(red: 0.4, green: 0.95, blue: 0.95), Color(red: 0.45, green: 0.72, blue: 1)]
    case .nebula: [Color(red: 0.86, green: 0.6, blue: 1), Color(red: 1, green: 0.45, blue: 0.78)]
    case .ember: [Color(red: 1, green: 0.84, blue: 0.45), Color(red: 1, green: 0.5, blue: 0.32)]
    case .mono: [Color(white: 0.96), Color(white: 0.62)]
    }
  }
}

let hotkeys: [(name: String, code: Int, mods: Int)] = [
  ("⌥ Space", kVK_Space, optionKey), ("⌃⌥ Space", kVK_Space, controlKey | optionKey),
  ("⌘⇧ Space", kVK_Space, cmdKey | shiftKey), ("⌥ C", kVK_ANSI_C, optionKey),
]

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
  var title = ""                     // Claude's own session name (from ~/.claude/sessions), e.g. "blaze-app-a8"
  var agents: [String: String] = [:]  // running subagents: id → type
  var folder: String { (cwd as NSString).lastPathComponent }
  var name: String { title.isEmpty ? folder : title }
}

struct Usage: Equatable { var tokens = 0, today = 0, context = 0, lastText = "", cost = 0.0, todayCost = 0.0 }

struct Device: Identifiable, Equatable {
  let id: String, name: String, updated: Date, tokens: Int, cost: Double, live: Int
  var mine = false
  var online: Bool { Date().timeIntervalSince(updated) < 180 }
}

let deviceDir = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Claude HUD/devices")

/// Title of Cursor's focused window, when Cursor is frontmost (needs Accessibility).
func cursorWindowTitle() -> String? {
  guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
        app.bundleIdentifier == "com.todesktop.230313mzl4w4u92" else { return nil }
  var win: CFTypeRef?, title: CFTypeRef?
  let ax = AXUIElementCreateApplication(app.processIdentifier)
  guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success, let win else { return nil }
  AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &title)
  return title as? String
}

/// "15:42" today, "Sat 14:00" later.
func clock(_ d: Date) -> String {
  let f = DateFormatter()
  f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "EEE HH:mm"
  return f.string(from: d)
}

func money(_ d: Double) -> String { d >= 100 ? String(format: "$%.0f", d) : String(format: "$%.2f", d) }

/// API list price per million tokens (input, output, cache read). Cache writes cost 1.25× input (5 min) / 2× (1 h).
func price(_ model: String) -> (i: Double, o: Double, r: Double) {
  if model.contains("fable") || model.contains("mythos") { return (10, 50, 0.25) }
  if model.contains("opus-5-5") { return (4, 20, 0.2) }
  if model.contains("opus-4-1") || model.contains("opus-4-2025") { return (15, 75, 1.5) }
  if model.contains("opus") { return (5, 25, 0.5) }
  if model.contains("sonnet-5") { return (2, 10, 0.2) }
  if model.contains("sonnet") { return (3, 15, 0.3) }
  if model.contains("haiku") { return (1, 5, 0.1) }
  return (5, 25, 0.5)
}
struct Limit: Equatable {
  let pct: Double, resets: Date
  var out: Date?        // when it runs out at the current pace (only if before the reset)
  var paced = false     // a pace is known; with out == nil that means "lasts until reset"
  var eta: TimeInterval? { out?.timeIntervalSinceNow }
}

struct Toast: Identifiable, Equatable {
  let id = UUID()
  let session: String  // "" = a usage notice
  let text: String
  var title = ""
  var heavy = false
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
  @Published var burn: [String: Int] = [:]
  private var tokenSamples: [String: [(t: Date, n: Int)]] = [:]
  private var heavyWarned = Set<String>()
  @Published var query = ""
  @Published var focusSearch = false
  var searching = false
  @Published var collapsed = Set(prefs.stringArray(forKey: "collapsed") ?? []) {
    didSet { prefs.set(Array(collapsed), forKey: "collapsed") }
  }
  /// Handed-off sessions: old id → the session that continued it ("" until it starts).
  @Published var retired = prefs.dictionary(forKey: "retired") as? [String: String] ?? [:] {
    didSet { prefs.set(retired, forKey: "retired") }
  }
  @Published var recent: [String] = []
  @Published var devices: [Device] = []
  private var pendingHandoff: (old: String, cwd: String, at: Date)?
  private var prepared: [String: (file: URL, at: Date)] = [:]
  private var reminded: [String: Date] = [:]
  private var lastDeviceSync = Date.distantPast
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

  var quiet: Bool { dnd || (inMeeting && prefs.bool(forKey: "meetingQuiet")) }
  var sorted: [Session] {
    let list = sessions.values.filter { $0.phase != .ready || usage($0).tokens > 0 }
    let rankOf = { (s: Session) in self.retired[s.id] != nil ? 9 : s.phase.rawValue }
    let byPhase = { (a: Session, b: Session) in (rankOf(a), b.since) < (rankOf(b), a.since) }
    guard prefs.bool(forKey: "groupByWorkspace") else { return list.sorted(by: byPhase) }
    // Workspaces ordered by their most urgent session, sessions by phase inside each.
    let rank = Dictionary(grouping: list, by: \.cwd).mapValues { $0.map(rankOf).min() ?? 9 }
    return list.sorted { a, b in a.cwd == b.cwd ? byPhase(a, b) : (rank[a.cwd]!, a.cwd) < (rank[b.cwd]!, b.cwd) }
  }
  var urgent: Phase? { sorted.first { retired[$0.id] == nil }?.phase }

  /// Sessions matching the search box.
  var filtered: [Session] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !q.isEmpty else { return sorted }
    return sorted.filter { s in
      [s.name, s.folder, s.activity, usage(s).lastText].contains { $0.lowercased().contains(q) }
    }
  }
  /// What the keyboard moves through: filtered, minus collapsed workspaces.
  var visible: [Session] {
    prefs.bool(forKey: "groupByWorkspace") && query.isEmpty ? filtered.filter { !collapsed.contains($0.cwd) } : filtered
  }
  var todayCost: Double { usage.values.reduce(0) { $0 + $1.todayCost } }

  func toggleCollapse(_ key: String) {
    withAnimation(Store.spring) { if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) } }
  }
  func successor(of id: String) -> Session? { retired[id].flatMap { sessions[$0] } }
  func predecessor(of id: String) -> Session? { retired.first { $0.value == id }.flatMap { sessions[$0.key] } }
  var todayTokens: Int { usage.values.reduce(0) { $0 + $1.today } }
  /// The session's own transcript plus its subagents' transcripts.
  func usage(_ s: Session) -> Usage {
    var u = usage[s.transcript] ?? usage.first { $0.key.hasSuffix("/\(s.id).jsonl") }?.value ?? Usage()
    for (k, v) in usage where k.contains("/\(s.id)/subagents/") { u.tokens += v.tokens; u.today += v.today }
    return u
  }

  /// Why a session is expensive right now, or nil.
  func heavy(_ s: Session) -> String? {
    guard s.phase != .ended, retired[s.id] == nil else { return nil }
    let u = usage(s), b = burn[s.id] ?? 0
    if Double(b) >= prefs.double(forKey: "heavyBurn") { return "\(fmt(b)) tokens in the last 10 min" }
    if u.context >= 350_000 { return "context \(fmt(u.context)) is re-sent every turn" }
    if s.agents.count >= 3 { return "\(s.agents.count) agents running at once" }
    return nil
  }

  /// Token growth per session over the last 10 minutes; warns once when a session turns heavy.
  private func updateBurn() {
    let now = Date()
    var b: [String: Int] = [:]
    for s in sessions.values {
      let n = usage(s).tokens
      var arr = (tokenSamples[s.id] ?? []).filter { now.timeIntervalSince($0.t) < 600 }
      arr.append((now, n))
      tokenSamples[s.id] = arr
      b[s.id] = max(0, n - arr[0].n)
    }
    if b != burn { burn = b }
    for s in sessions.values where s.phase != .permission {
      guard let why = heavy(s), heavyWarned.insert(s.id).inserted else { continue }
      alert(s, "Heavy: \(why)", sound: "Basso", pref: "notifyUsage", heavy: true)
      prepareHandoff(s)
    }
    heavyWarned = heavyWarned.filter { id in sessions[id].map { heavy($0) != nil } ?? false }
  }

  /// Claude's session registry: gives each live session its own name.
  private func readRegistry() {
    let dir = home.appendingPathComponent(".claude/sessions")
    var names: [String: String] = [:], dirs: [String: String] = [:], seen: [String: Double] = [:]
    for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" {
      guard let d = try? Data(contentsOf: f), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let id = j["sessionId"] as? String, let n = j["name"] as? String else { continue }
      names[id] = n
      dirs[id] = j["cwd"] as? String
      if let c = j["cwd"] as? String { seen[c] = max(seen[c] ?? 0, j["updatedAt"] as? Double ?? 0) }
    }
    let r = Array(seen.sorted { $0.value > $1.value }.map(\.key).prefix(10))
    if r != recent { recent = r }
    var ss = sessions
    for (id, s) in ss {
      if let n = names[id], n != s.title { ss[id]?.title = n }
      if let c = dirs[id], c != s.cwd { ss[id]?.cwd = c }
    }
    if ss != sessions { sessions = ss }
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
      return s.phase == .permission || replyTarget == t.session || now.timeIntervalSince(t.created) < prefs.double(forKey: "toastSeconds")
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
        // Pace: recent samples when they span 5+ min, else the average since the window opened.
        let start = r.addingTimeInterval(k == "five_hour" ? -5 * 3600 : -7 * 86400)
        var rate: Double?
        if let first = arr.first, p > first.p, Date().timeIntervalSince(first.t) >= 300 {
          rate = (p - first.p) / Date().timeIntervalSince(first.t)
        } else if p > 0, Date().timeIntervalSince(start) > 600 {
          rate = p / Date().timeIntervalSince(start)
        }
        var eta: TimeInterval?
        if let rate, rate > 0, (100 - p) / rate < r.timeIntervalSinceNow { eta = (100 - p) / rate }
        for th in [80.0, 95.0] where p >= th && warned.insert("\(k)\(th)\(r.timeIntervalSince1970)").inserted {
          notice("\(label) usage at \(Int(p))%", eta.map { "At this pace you hit the limit in ~\(span($0))" } ?? "Resets in \(span(r.timeIntervalSinceNow))")
        }
        return Limit(pct: p, resets: r, out: eta.map { Date().addingTimeInterval($0) }, paced: rate != nil)
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
      DispatchQueue.main.async {
        if u != self.usage { self.usage = u }
        self.readRegistry()
        self.updateBurn()
        self.remindIdle()
        self.syncDevices()
      }
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

  // MARK: actions

  private func alert(_ s: Session, _ text: String, sound: String, pref: String, heavy: Bool = false) {
    guard !quiet, prefs.bool(forKey: pref), retired[s.id] == nil else { return }  // muted: state still updates, the edge still glows
    if prefs.bool(forKey: "sounds") { NSSound(named: sound)?.play() }
    var t = toasts.filter { $0.session != s.id }
    t.append(Toast(session: s.id, text: text, heavy: heavy))
    if t.count > 4, let i = t.firstIndex(where: { sessions[$0.session]?.phase != .permission }) { t.remove(at: i) }
    withAnimation(Store.spring) { toasts = t }
  }

  private func notice(_ title: String, _ text: String) {
    guard !quiet, prefs.bool(forKey: "notifyUsage") else { return }
    if prefs.bool(forKey: "sounds") { NSSound(named: "Submarine")?.play() }
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
    var q = [URLQueryItem(name: "session", value: s.id)]
    if let p = prompt, !p.isEmpty { q.append(URLQueryItem(name: "prompt", value: p)) }
    openInCursor(s.cwd, q)
    close()
    withAnimation(Store.spring) { toasts.removeAll { $0.session == s.id } }
  }

  /// Starts a fresh session in the same workspace, seeded with a handoff note built from the old transcript
  /// (no tokens spent summarising). The old session stays open and reachable via Claude's SendMessage.
  func handoff(_ s: Session) {
    // The note travels inside the prompt: nothing to read outside the project, so no permission prompt.
    let note: String
    if let p = prepared[s.id], Date().timeIntervalSince(p.at) < 900, let t = try? String(contentsOf: p.file, encoding: .utf8) {
      note = t
    } else {
      note = handoffNote(s)
      writeHandoff(s)  // keep a copy on disk
    }
    let prompt = """
      I'm continuing a previous Claude session ("\(s.name)") that got too expensive to keep going. \
      Pick up where it stopped using the handoff below. Open only the files you actually need; don't re-explore the codebase.

      \(note)
      """
    openInCursor(s.cwd, [URLQueryItem(name: "prompt", value: prompt)], send: prefs.bool(forKey: "autoSend"))
    close()
    pendingHandoff = (s.id, s.cwd, Date())
    if prefs.bool(forKey: "autoEndOld"), s.pid > 1 {
      let pid = s.pid
      DispatchQueue.main.asyncAfter(deadline: .now() + 15) { kill(pid, SIGTERM) }  // after the new one has its prompt
    }
    withAnimation(Store.spring) {
      retired[s.id] = ""
      toasts.removeAll { $0.session == s.id }
    }
  }

  @discardableResult
  private func writeHandoff(_ s: Session) -> URL {
    let dir = hudDir.appendingPathComponent("handoff")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date()).prefix(16).replacingOccurrences(of: ":", with: "")
    let file = dir.appendingPathComponent("\(s.name)-\(stamp).md")
    try? handoffNote(s).write(to: file, atomically: true, encoding: .utf8)
    return file
  }

  /// Auto-handoff: write the note in the background as soon as a session turns heavy, so Fresh session is instant.
  private func prepareHandoff(_ s: Session) {
    queue.async {
      let f = self.writeHandoff(s)
      DispatchQueue.main.async { self.prepared[s.id] = (f, Date()) }
    }
  }

  /// Brings up the Cursor window for `cwd`, waits until it's really in front (so the tab lands in the right
  /// workspace), then opens the Claude tab. With `send`, presses Return in the new chat box.
  func openInCursor(_ cwd: String, _ query: [URLQueryItem], send: Bool = false) {
    NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: URL(fileURLWithPath: "/Applications/Cursor.app"),
                            configuration: NSWorkspace.OpenConfiguration())
    var c = URLComponents(string: "cursor://anthropic.claude-code/open")!
    if !query.isEmpty { c.queryItems = query }
    let url = c.url!, name = (cwd as NSString).lastPathComponent
    let trusted = AXIsProcessTrusted()
    var tries = 0
    func ready() -> Bool { cursorWindowTitle()?.contains(name) == true }
    func step() {
      tries += 1
      // Without Accessibility we can't see window titles: fall back to a fixed wait.
      guard (trusted && ready()) || tries > (trusted ? 30 : 12) else {
        return DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { step() }
      }
      NSWorkspace.shared.open(url)
      guard send, trusted else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
        guard ready() else { return }  // focus moved elsewhere: leave the prompt waiting rather than type into the wrong place
        for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down)?.post(tap: .cghidEventTap) }
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { step() }
  }

  func undoHandoff(_ s: Session) { withAnimation(Store.spring) { retired[s.id] = nil } }

  /// New session in a workspace (focuses its Cursor window), pre-filled with the default first prompt.
  func launch(_ cwd: String) {
    let first = prefs.string(forKey: "firstPrompt") ?? ""
    openInCursor(cwd, first.isEmpty ? [] : [URLQueryItem(name: "prompt", value: first)])
    close()
  }

  /// One nudge per wait when a session has been waiting on you longer than the idle setting.
  private func remindIdle() {
    let mins = prefs.double(forKey: "idleMinutes")
    guard mins > 0 else { return }
    for s in sessions.values where (s.phase == .done || s.phase == .permission) && retired[s.id] == nil {
      let waited = Date().timeIntervalSince(s.since)
      guard waited > mins * 60, reminded[s.id] != s.since else { continue }
      reminded[s.id] = s.since
      alert(s, "Waiting on you for \(span(waited))", sound: "Tink", pref: s.phase == .done ? "notifyDone" : "notifyPermission")
    }
  }

  /// Devices: every Mac running Claude HUD drops today's totals in iCloud Drive and reads the others'.
  private func syncDevices() {
    guard prefs.bool(forKey: "syncDevices") else { if !devices.isEmpty { devices = [] }; return }
    guard Date().timeIntervalSince(lastDeviceSync) > 60 else { return }
    lastDeviceSync = Date()
    let myID: String = prefs.string(forKey: "deviceID") ?? {
      let id = UUID().uuidString
      prefs.set(id, forKey: "deviceID")
      return id
    }()
    let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
    let mine: [String: Any] = ["name": Host.current().localizedName ?? "This Mac", "updated": Date().timeIntervalSince1970,
                               "day": day, "tokens": todayTokens, "cost": todayCost,
                               "live": sorted.filter { $0.phase != .ended && retired[$0.id] == nil }.count]
    queue.async {
      let fm = FileManager.default
      try? fm.createDirectory(at: deviceDir, withIntermediateDirectories: true)
      if let d = try? JSONSerialization.data(withJSONObject: mine) {
        try? d.write(to: deviceDir.appendingPathComponent("\(myID).json"), options: .atomic)
      }
      var list: [Device] = []
      for f in (try? fm.contentsOfDirectory(at: deviceDir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" {
        guard let d = try? Data(contentsOf: f), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
        let id = f.deletingPathExtension().lastPathComponent
        let today = (j["day"] as? Double) == day
        list.append(Device(id: id, name: j["name"] as? String ?? "Mac",
                           updated: Date(timeIntervalSince1970: j["updated"] as? Double ?? 0),
                           tokens: today ? j["tokens"] as? Int ?? 0 : 0, cost: today ? j["cost"] as? Double ?? 0 : 0,
                           live: j["live"] as? Int ?? 0, mine: id == myID))
      }
      list.sort { ($0.mine ? 0 : 1, -$0.cost) < ($1.mine ? 0 : 1, -$1.cost) }
      DispatchQueue.main.async { if list != self.devices { self.devices = list } }
    }
  }

  private func handoffNote(_ s: Session) -> String {
    var prompts: [String] = [], files: [String] = [], last = "", branch = ""
    let path = s.transcript.isEmpty ? "" : s.transcript
    for line in ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n") {
      guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            let m = j["message"] as? [String: Any] else { continue }
      if let b = j["gitBranch"] as? String, !b.isEmpty { branch = b }
      let parts = m["content"] as? [[String: Any]] ?? []
      if j["type"] as? String == "user", j["isMeta"] as? Bool != true {
        let text = (m["content"] as? String) ?? parts.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, !t.hasPrefix("<") { prompts.append(t) }
      } else if j["type"] as? String == "assistant" {
        for p in parts {
          if p["type"] as? String == "text", let t = p["text"] as? String { last = t }
          if p["type"] as? String == "tool_use", ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(p["name"] as? String ?? ""),
             let f = (p["input"] as? [String: Any])?["file_path"] as? String, !files.contains(f) { files.append(f) }
        }
      }
    }
    let cut = { (t: String, n: Int) in t.count > n ? String(t.prefix(n)) + "…" : t }
    return """
      # Handoff from "\(s.name)"

      - Workspace: \(s.cwd)
      - Branch: \(branch.isEmpty ? "unknown" : branch)
      - Previous session: \(s.id) ("\(s.name)")

      ## Original request
      \(cut(prompts.first ?? "(none found)", 1000))

      ## Recent requests (oldest first)
      \(prompts.suffix(6).map { "- " + cut($0.replacingOccurrences(of: "\n", with: " "), 300) }.joined(separator: "\n"))

      ## Files touched
      \(files.isEmpty ? "(none)" : files.suffix(30).map { "- " + $0 }.joined(separator: "\n"))

      ## Where it stopped (last reply)
      \(cut(last, 2500))
      """
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
    guard drawerOpen, replyTarget == nil, !searching else { return false }
    let list = visible
    let s = list.indices.contains(selected) ? list[selected] : nil
    switch (e.keyCode, e.charactersIgnoringModifiers ?? "") {
    case (53, _): close()
    case (_, "/"): focusSearch = true
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

  func glass(_ r: CGFloat, tint: Color) -> some View { modifier(Glass(r: r, tint: tint)) }
}

struct Glass: ViewModifier {
  let r: CGFloat, tint: Color
  @AppStorage("glass") private var dark = 0.85
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
    return content.background {
      ZStack {
        shape.fill(.black.opacity(0.3)).shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        shape.fill(.ultraThinMaterial)
        shape.fill(LinearGradient(colors: [Color(white: 0.09).opacity(dark * 0.92), Color(white: 0.02).opacity(min(1, dark * 1.06))],
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
    let heavy = store.heavy(s)
    let burn = store.burn[s.id] ?? 0
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
            .help("\(fmt(u.tokens)) tokens · \(money(u.cost)) at API prices (\(money(u.todayCost)) today)")
          ContextRing(tokens: u.context)
          if burn >= 50_000 {
            Text("+\(fmt(burn))/10m").font(.system(size: 9, weight: .semibold, design: .monospaced))
              .foregroundStyle(heavy != nil ? red : .white.opacity(0.35))
              .help("Tokens used in the last 10 minutes")
          }
        }
      }
      if let from = store.predecessor(of: s.id) {
        Label("continues \(from.name)", systemImage: "arrow.turn.down.right")
          .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(Color(red: 0.75, green: 0.65, blue: 1))
      }
      if !s.agents.isEmpty {
        HStack(spacing: 6) {
          Image(systemName: "person.2.wave.2.fill").font(.system(size: 9.5)).foregroundStyle(Theme.aurora.colors[0])
          Text("\(s.agents.count) agent\(s.agents.count == 1 ? "" : "s") · \(Set(s.agents.values).sorted().joined(separator: ", "))")
            .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
        }
      }
      if let heavy {
        VStack(alignment: .leading, spacing: 7) {
          HStack(spacing: 6) {
            Image(systemName: "flame.fill").foregroundStyle(red)
            Text(heavy).foregroundStyle(red)
          }
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          HStack(spacing: 6) {
            Pill(title: "Compact", icon: "arrow.down.right.and.arrow.up.left", tint: red) { store.jump(s, prompt: "/compact") }
              .help("Open the tab with /compact ready to send")
            Pill(title: "Fresh session", icon: "arrow.triangle.branch", tint: red, primary: true) { store.handoff(s) }
              .help("New tab in this workspace, seeded with a handoff note from this one")
          }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(red.opacity(0.08)))
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
      .strokeBorder(heavy != nil && s.phase != .permission ? red.opacity(0.55)
                    : s.phase.color.opacity(s.phase == .permission ? 0.5 : selected ? 0.45 : hover ? 0.22 : 0.07)))
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
  @AppStorage("theme") private var theme = "aurora"
  var body: some View {
    let pct = min(100, limit?.pct ?? 0)
    let colors: [Color] = pct > 85 ? [Color(red: 1, green: 0.4, blue: 0.5), Color(red: 1, green: 0.25, blue: 0.4)]
      : pct > 60 ? [Color(red: 1, green: 0.8, blue: 0.35), Phase.permission.color]
      : (Theme(rawValue: theme) ?? .aurora).colors
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
        Text(limit.map { "resets in \(span($0.resets.timeIntervalSinceNow)) · \(clock($0.resets))" } ?? "waiting for data")
          .foregroundStyle(.white.opacity(0.4))
        if let l = limit, let out = l.out {
          Text("out ≈ \(clock(out)) at this pace").foregroundStyle(Phase.permission.color.opacity(0.9))
        } else if let l = limit, l.paced {
          Text("lasts until reset at this pace").foregroundStyle(Phase.done.color.opacity(0.7))
        }
      }
      .font(.system(size: 9.5, weight: .medium, design: .rounded))
    }
  }
}

struct WorkspaceHeader: View {
  @ObservedObject var store: Store
  let cwd: String
  let sessions: [Session]
  @State private var hover = false
  var body: some View {
    let tokens = sessions.reduce(0) { $0 + store.usage($1).tokens }
    let cost = sessions.reduce(0.0) { $0 + store.usage($1).todayCost }
    let folded = store.collapsed.contains(cwd)
    HStack(spacing: 6) {
      Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.4))
        .rotationEffect(.degrees(folded ? 0 : 90))
      Text((cwd as NSString).lastPathComponent.uppercased())
        .font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(1.3).foregroundStyle(.white.opacity(0.55))
        .lineLimit(1).fixedSize()
      if folded {
        HStack(spacing: 3) { ForEach(sessions) { Circle().fill($0.phase.color).frame(width: 5, height: 5) } }
      } else {
        Text("\(sessions.count)").font(.system(size: 9.5, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.3))
      }
      Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
      if hover {
        Button { store.launch(cwd) } label: {
          Image(systemName: "plus").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white.opacity(0.7))
            .frame(width: 16, height: 16).background(Circle().fill(.white.opacity(0.1)))
        }
        .buttonStyle(Press()).help("New session in \((cwd as NSString).lastPathComponent)")
      }
      Text("\(money(cost)) · \(fmt(tokens))").font(.system(size: 9.5, weight: .semibold, design: .monospaced))
        .foregroundStyle(sessions.contains { store.heavy($0) != nil } ? red : .white.opacity(0.4))
        .help("Today at API prices · tokens across these sessions")
    }
    .padding(.horizontal, 4).padding(.vertical, 2)
    .contentShape(Rectangle())
    .onTapGesture { store.toggleCollapse(cwd) }
    .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    .help(cwd)
  }
}

struct Drawer: View {
  @ObservedObject var store: Store
  @AppStorage("theme") private var theme = "aurora"
  @AppStorage("groupByWorkspace") private var groupByWorkspace = true
  @AppStorage("idleMinutes") private var idleMinutes = 10.0
  @AppStorage("firstPrompt") private var firstPrompt = ""
  @AppStorage("autoEndOld") private var autoEndOld = true
  @AppStorage("autoSend") private var autoSend = true
  @State private var axTrusted = AXIsProcessTrusted()
  @AppStorage("syncDevices") private var syncDevices = true
  var body: some View {
    let list = store.filtered
    let vis = store.visible
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .center, spacing: 8) {
        StatusDot(phase: store.urgent ?? .ready)
        Text("CLAUDE").font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(3).foregroundStyle(.white.opacity(0.75))
        Text("\(list.filter { $0.phase != .ended }.count) live")
          .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.4))
        Menu {
          Section("New session in…") {
            ForEach(store.recent, id: \.self) { c in Button((c as NSString).lastPathComponent) { store.launch(c) } }
          }
        } label: {
          Image(systemName: "plus").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white.opacity(0.5))
            .frame(width: 22, height: 22).background(Circle().fill(.white.opacity(0.06)))
        }
        .menuStyle(.button).buttonStyle(Press()).menuIndicator(.hidden).fixedSize()
        .help("New session")
        Button { SettingsWindow.show(store) } label: {
          Image(systemName: "gearshape.fill").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.35))
            .frame(width: 22, height: 22).background(Circle().fill(.white.opacity(0.04)))
        }
        .buttonStyle(Press())
        .help("Settings")
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
          Text(money(store.todayCost)).font(.system(size: 16, weight: .semibold, design: .monospaced))
            .contentTransition(.numericText())
            .help("Today's usage priced at API rates (your plan isn't billed this way)")
          Text("\(fmt(store.todayTokens)) tokens today").font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.4))
        }
      }
      .contextMenu {
        Button("Settings…") { SettingsWindow.show(store) }
        Button("Quit Claude HUD") { NSApp.terminate(nil) }
      }

      HStack(spacing: 16) {
        LimitBar(title: "5-HOUR", limit: store.fiveHour)
        LimitBar(title: "WEEKLY", limit: store.week)
      }

      if !store.devices.isEmpty { DevicesStrip(store: store) }

      Rectangle().fill(LinearGradient(colors: [.clear, .white.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing))
        .frame(height: 1)

      if store.pinned || !store.query.isEmpty { SearchField(store: store) }

      if list.isEmpty {
        VStack(spacing: 6) {
          Image(systemName: store.query.isEmpty ? "sparkles" : "magnifyingglass").font(.system(size: 18)).foregroundStyle(.white.opacity(0.3))
          Text(store.query.isEmpty ? "No sessions yet" : "No session matches “\(store.query)”")
            .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
      } else {
        let grouped = groupByWorkspace && store.query.isEmpty && Set(list.map(\.cwd)).count > 1
        let folders = list.map(\.cwd).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let cards = VStack(spacing: 8) {
          if grouped {
            ForEach(folders, id: \.self) { c in
              let group = list.filter { $0.cwd == c }
              WorkspaceHeader(store: store, cwd: c, sessions: group).padding(.top, c == folders.first ? 0 : 6)
              if !store.collapsed.contains(c) {
                ForEach(group) { s in card(s, vis) }
              }
            }
          } else {
            ForEach(list) { s in card(s, vis) }
          }
        }
        ViewThatFits(in: .vertical) {
          cards
          ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) { cards }
              .defaultScrollAnchor(.top)
              .onChange(of: store.selected) { _, i in
                if vis.indices.contains(i) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(vis[i].id, anchor: .center) } }
              }
          }
        }
      }
      if store.pinned {
        Text("↑↓  ↩ open  A allow  D deny  R reply  / search")
          .font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.3))
          .frame(maxWidth: .infinity)
      }
    }
    .padding(16)
    .frame(width: 340)
    .glass(24, tint: store.urgent == .permission ? Phase.permission.color : (Theme(rawValue: theme) ?? .aurora).colors[1])
    .hitArea()
  }

  @ViewBuilder func card(_ s: Session, _ vis: [Session]) -> some View {
    if store.retired[s.id] != nil {
      RetiredCard(store: store, s: s)
    } else {
      let i = vis.firstIndex { $0.id == s.id } ?? 0
      SessionCard(store: store, s: s, index: i, selected: store.pinned && vis.indices.contains(store.selected) && vis[store.selected].id == s.id)
    }
  }
}

/// A session that was handed off to a fresh one: clearly retired, one tap to close it.
struct RetiredCard: View {
  @ObservedObject var store: Store
  let s: Session
  @State private var hover = false
  var body: some View {
    let next = store.successor(of: s.id)
    let violet = Color(red: 0.75, green: 0.65, blue: 1)
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: "archivebox.fill").font(.system(size: 11)).foregroundStyle(violet.opacity(0.8)).frame(width: 18)
        VStack(alignment: .leading, spacing: 2) {
          Text(s.name).font(.system(size: 13, weight: .semibold, design: .rounded)).strikethrough(color: .white.opacity(0.4))
            .foregroundStyle(.white.opacity(0.55)).lineLimit(1)
          Text(next.map { "Handed off → \($0.name)" } ?? "Handed off · waiting for the new session")
            .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(violet)
        }
        Spacer()
        Text(fmt(store.usage(s).tokens)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.35))
      }
      if hover {
        HStack(spacing: 6) {
          if let next { Pill(title: "Go to new", icon: "arrow.up.right", tint: violet) { store.jump(next) } }
          Pill(title: "Undo", icon: "arrow.uturn.backward") { store.undoHandoff(s) }
          Spacer()
          if s.phase != .ended { Pill(title: "Close old", icon: "power", tint: red, primary: true) { store.end(s) } }
        }
        .transition(.opacity)
      }
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(violet.opacity(hover ? 0.08 : 0.04)))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(violet.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    .contentShape(RoundedRectangle(cornerRadius: 16))
    .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
    .help("This session was continued in a fresh one — you don't need it anymore")
  }
}

struct SearchField: View {
  @ObservedObject var store: Store
  @FocusState private var focused: Bool
  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
      TextField("Search sessions  ( / )", text: $store.query)
        .textFieldStyle(.plain).font(.system(size: 12, design: .rounded))
        .focused($focused)
        .onSubmit { if let s = store.visible.first { store.jump(s) } }
        .onExitCommand { store.query = ""; focused = false }
      if !store.query.isEmpty {
        Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.35)) }
          .buttonStyle(.plain).accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 7)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.35)))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(focused ? 0.25 : 0.06)))
    .onChange(of: store.focusSearch) { _, v in if v { hudPanel?.makeKey(); focused = true; store.focusSearch = false } }
    .onChange(of: focused) { _, v in store.searching = v }
  }
}

struct DevicesStrip: View {
  @ObservedObject var store: Store
  var body: some View {
    let folded = store.collapsed.contains("#devices")
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 6) {
        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.4))
          .rotationEffect(.degrees(folded ? 0 : 90))
        Text("DEVICES").font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(1.4).foregroundStyle(.white.opacity(0.45))
        Text("\(store.devices.count)").font(.system(size: 9.5, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.3))
        Spacer()
        Text(money(store.devices.reduce(0) { $0 + $1.cost }) + " today").font(.system(size: 9.5, weight: .semibold, design: .monospaced))
          .foregroundStyle(.white.opacity(0.4))
      }
      .contentShape(Rectangle())
      .onTapGesture { store.toggleCollapse("#devices") }
      if !folded {
        ForEach(store.devices) { d in
          HStack(spacing: 8) {
            Image(systemName: "laptopcomputer").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            Circle().fill(d.online ? Phase.done.color : Color(white: 0.4)).frame(width: 5, height: 5)
            Text(d.name + (d.mine ? "  · this Mac" : "")).font(.system(size: 11, weight: .medium, design: .rounded)).lineLimit(1)
            if d.live > 0 { Text("\(d.live) live").font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.35)) }
            Spacer()
            Text("\(money(d.cost)) · \(fmt(d.tokens))").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
          }
          .help(d.online ? "Online" : "Last seen \(clock(d.updated))")
        }
      }
    }
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
            if t.heavy {
              Pill(title: "Fresh session", icon: "arrow.triangle.branch", tint: red, primary: true) { store.handoff(s) }
              Pill(title: "Compact", icon: "arrow.down.right.and.arrow.up.left", tint: red) { store.jump(s, prompt: "/compact") }
            } else {
              Pill(title: "Reply", icon: "arrowshape.turn.up.left.fill", tint: Phase.done.color, primary: s.phase == .done) {
                withAnimation(Store.spring) { store.replyTarget = s.id }
              }
              Pill(title: "Open", icon: "arrow.up.right") { store.jump(s) }
            }
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
  @AppStorage("edgeGlow") private var edgeGlow = true
  var body: some View {
    ZStack(alignment: .trailing) {
      Color.clear
      if store.drawerOpen {
        Drawer(store: store).padding(.trailing, 12).padding(.vertical, 18).transition(.edge)
      } else if edgeGlow || store.urgent == .permission {
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

// MARK: - Settings

enum SettingsWindow {
  static var window: NSWindow?
  static func show(_ store: Store) {
    store.close()
    if window == nil {
      let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 660),
                       styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
      w.title = "Claude HUD"
      w.titlebarAppearsTransparent = true
      w.appearance = NSAppearance(named: .darkAqua)
      w.isReleasedWhenClosed = false
      w.contentView = NSHostingView(rootView: SettingsView(store: store))
      w.center()
      window = w
    }
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }
}

struct Swatch: View {
  let theme: Theme
  let on: Bool
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      VStack(spacing: 5) {
        Circle().fill(LinearGradient(colors: theme.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
          .frame(width: 24, height: 24)
          .overlay(Circle().strokeBorder(Color.white.opacity(on ? 0.9 : 0), lineWidth: 2).padding(-4))
        Text(theme.rawValue.capitalized).font(.caption2).foregroundStyle(on ? Color.primary : Color.secondary)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(theme.rawValue) theme")
  }
}

struct SettingsView: View {
  @ObservedObject var store: Store
  @AppStorage("theme") private var theme = "aurora"
  @AppStorage("glass") private var glass = 0.85
  @AppStorage("edgeGlow") private var edgeGlow = true
  @AppStorage("edgeDelay") private var edgeDelay = 0.12
  @AppStorage("notifyPermission") private var notifyPermission = true
  @AppStorage("notifyDone") private var notifyDone = true
  @AppStorage("notifyEnded") private var notifyEnded = true
  @AppStorage("notifyUsage") private var notifyUsage = true
  @AppStorage("sounds") private var sounds = true
  @AppStorage("toastSeconds") private var toastSeconds = 9.0
  @AppStorage("meetingQuiet") private var meetingQuiet = true
  @AppStorage("answerInHUD") private var answerInHUD = true
  @AppStorage("hotkey") private var hotkey = 0
  @AppStorage("menuBar") private var menuBar = true
  @AppStorage("loginItem") private var loginItem = true
  @AppStorage("heavyBurn") private var heavyBurn = 1_000_000.0
  @AppStorage("groupByWorkspace") private var groupByWorkspace = true
  @AppStorage("idleMinutes") private var idleMinutes = 10.0
  @AppStorage("firstPrompt") private var firstPrompt = ""
  @AppStorage("autoEndOld") private var autoEndOld = true
  @AppStorage("autoSend") private var autoSend = true
  @State private var axTrusted = AXIsProcessTrusted()
  @AppStorage("syncDevices") private var syncDevices = true

  var body: some View {
    Form {
      Section("Appearance") {
        LabeledContent("Theme") {
          HStack(spacing: 14) {
            ForEach(Theme.allCases) { t in
              Swatch(theme: t, on: theme == t.rawValue) { withAnimation(.easeOut(duration: 0.2)) { theme = t.rawValue } }
            }
          }
        }
        LabeledContent("Glass") {
          HStack { Text("Clear").font(.caption); Slider(value: $glass, in: 0.5...1); Text("Dark").font(.caption) }
        }
        Toggle("Glow on the screen edge", isOn: $edgeGlow)
        LabeledContent("Edge hover delay") {
          HStack { Slider(value: $edgeDelay, in: 0...0.6); Text("\(Int(edgeDelay * 1000)) ms").font(.caption.monospacedDigit()).frame(width: 46) }
        }
      }
      Section("Notifications") {
        Toggle("Needs permission or input", isOn: $notifyPermission)
        Toggle("Finished — your turn", isOn: $notifyDone)
        Toggle("Session ended", isOn: $notifyEnded)
        Toggle("Usage alerts at 80% and 95%", isOn: $notifyUsage)
        Toggle("Sounds", isOn: $sounds)
        LabeledContent("Keep toasts for") {
          HStack { Slider(value: $toastSeconds, in: 4...30, step: 1); Text("\(Int(toastSeconds))s").font(.caption.monospacedDigit()).frame(width: 30) }
        }
        LabeledContent("Remind me when a session waits") {
          HStack {
            Slider(value: $idleMinutes, in: 0...60, step: 5)
            Text(idleMinutes == 0 ? "Off" : "\(Int(idleMinutes)) min").font(.caption.monospacedDigit()).frame(width: 46)
          }
        }
        Toggle("Do not disturb", isOn: $store.dnd)
        Toggle("Quiet during Zoom meetings", isOn: $meetingQuiet)
      }
      Section {
        Toggle("Answer permission prompts from the HUD", isOn: $answerInHUD)
      } header: { Text("Permissions") } footer: {
        Text(answerInHUD
             ? "Prompts go to the HUD first; Cursor shows its dialog once you pick “Cursor”."
             : "Prompts appear in Cursor as usual; the HUD only notifies you.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section {
        LabeledContent("Flag a session as heavy at") {
          HStack {
            Slider(value: $heavyBurn, in: 250_000...5_000_000, step: 250_000)
            Text("\(fmt(Int(heavyBurn)))/10m").font(.caption.monospacedDigit()).frame(width: 64)
          }
        }
        Toggle("Group sessions by workspace", isOn: $groupByWorkspace)
        Toggle("Fresh session: send the handoff automatically", isOn: $autoSend)
        Toggle("Fresh session: close the old session", isOn: $autoEndOld)
        if !axTrusted {
          HStack {
            Text("Auto-send and landing in the right workspace need Accessibility access.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Grant…") {
              AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            }
          }
        }
      } header: { Text("Optimization") } footer: {
        Text("Heavy sessions turn red (also at 350k+ context or 3+ parallel agents) with Compact and Fresh session actions.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section {
        Toggle("Share usage across my Macs (iCloud Drive)", isOn: $syncDevices)
      } header: { Text("Devices") } footer: {
        Text("Each Mac running Claude HUD writes today's tokens and cost to iCloud Drive › Claude HUD. Claude.ai web and mobile can't be split out — the limit bars include everything.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("General") {
        TextField("First prompt for new sessions", text: $firstPrompt, prompt: Text("optional — pre-filled when you press +"))
        Picker("Open drawer shortcut", selection: $hotkey) {
          ForEach(hotkeys.indices, id: \.self) { Text(hotkeys[$0].name).tag($0) }
          Text("Off").tag(hotkeys.count)
        }
        Toggle("Show usage in the menu bar", isOn: $menuBar)
        Toggle("Launch at login", isOn: $loginItem)
      }
      Section {
        HStack {
          Button("Quit Claude HUD", role: .destructive) { NSApp.terminate(nil) }
          Spacer()
          Text("Right-click the menu bar item for quick actions").font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in axTrusted = AXIsProcessTrusted() }
    .frame(width: 480, height: 660)
    .tint((Theme(rawValue: theme) ?? .aurora).colors[1])
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
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in hotKeyAction?(); return noErr }, 1, &spec, nil, nil)
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.store.key(e) == true ? nil : e }

    // Menu bar: live 5-hour · weekly usage; click toggles the drawer.
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.target = self
    statusItem.button?.action = #selector(statusClicked)
    statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    store.onLimits = { [weak self] in self?.updateStatus() }
    updateStatus()

    applyPrefs()
    NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
      self?.applyPrefs()
    }
  }

  private var applied: [String: Int] = [:]

  /// Applies settings that live outside SwiftUI. Only acts on values that changed.
  func applyPrefs() {
    func changed(_ k: String, _ v: Int) -> Bool { defer { applied[k] = v }; return applied[k] != v }
    let hk = prefs.integer(forKey: "hotkey")
    if changed("hotkey", hk) {
      if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
      if hotkeys.indices.contains(hk) {
        RegisterEventHotKey(UInt32(hotkeys[hk].code), UInt32(hotkeys[hk].mods), EventHotKeyID(signature: 0x4855_4421, id: 1),
                            GetApplicationEventTarget(), 0, &hotKeyRef)
      }
    }
    statusItem.isVisible = prefs.bool(forKey: "menuBar")
    let off = hudDir.appendingPathComponent("answer-off")  // perm.sh steps aside when this exists
    if prefs.bool(forKey: "answerInHUD") { try? FileManager.default.removeItem(at: off) }
    else { FileManager.default.createFile(atPath: off.path, contents: nil) }
    let login = prefs.bool(forKey: "loginItem") ? 1 : 0
    if changed("loginItem", login), applied.count > 1 || login == 0 {
      let app = Bundle.main.bundlePath
      let script = login == 1
        ? "tell application \"System Events\" to if not (exists login item \"ClaudeHUD\") then make login item at end with properties {path:\"\(app)\", hidden:true}"
        : "tell application \"System Events\" to delete (every login item whose name is \"ClaudeHUD\")"
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
      p.arguments = ["-e", script]
      try? p.run()
    }
  }

  @objc func statusClicked() {
    guard NSApp.currentEvent?.type == .rightMouseUp else { return toggle() }
    let m = NSMenu()
    m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
    m.addItem(withTitle: store.dnd ? "Turn off Do Not Disturb" : "Do Not Disturb", action: #selector(toggleDND), keyEquivalent: "").target = self
    m.addItem(.separator())
    m.addItem(withTitle: "Quit Claude HUD", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    statusItem.menu = m
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  @objc func openSettings() { SettingsWindow.show(store) }
  @objc func toggleDND() { store.dnd.toggle() }

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
    statusItem.button?.toolTip = "Claude usage — 5-hour · weekly. Click: drawer · right-click: menu"
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
    if !store.drawerOpen, let t = edgeSince, Date().timeIntervalSince(t) > prefs.double(forKey: "edgeDelay") {
      withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { store.drawerOpen = true }
    }
    guard store.drawerOpen, !store.pinned else { return }
    if overUI || atEdge || store.replyTarget != nil || store.searching { leftSince = nil; return }
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
