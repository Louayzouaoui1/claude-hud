import AppKit
import Carbon
import SwiftUI
import HUDCore

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
  var tokenSamples: [String: [(t: Date, n: Int)]] = [:]
  var heavyWarned = Set<String>()
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
  @Published var remote: [Remote] = []
  /// Share of the current 5-hour window that grew while this Mac used nothing: claude.ai, phone, other computers.
  @Published var elsewhere = 0.0
  var lastPace: (p: Double, local: Int, resets: Date)?
  var pendingHandoff: (old: String, cwd: String, at: Date)?
  var prepared: [String: (file: URL, at: Date)] = [:]
  var reminded: [String: Date] = [:]
  var lastDeviceSync = Date.distantPast
  var onLimits: (() -> Void)?
  var hoveredToast: UUID?
  var hitRects: [CGRect] = []
  var offset: UInt64 = 0
  var passthrough: [String: Date] = [:]
  var limitsMod = Date.distantPast
  var samples: [String: [(t: Date, p: Double)]] = [:]
  var warned = Set<String>()
  let counter = TokenCounter()
  let queue = DispatchQueue(label: "hud", qos: .utility)
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

  @Published var dismissedTips: Set<String> = []

  /// Concrete ways to use fewer tokens, worst first. Sessions already flagged heavy get their own banner instead.
  var tips: [Tip] {
    var t: [Tip] = []
    for s in sessions.values where s.phase != .ended && retired[s.id] == nil && heavy(s) == nil {
      let u = usage(s)
      if u.context >= 120_000, s.phase != .working {
        t.append(Tip(id: "ctx" + s.id, icon: "text.append",
                     text: "\(s.name) re-sends \(fmt(u.context)) of context with every message. Compact it, or start a fresh session for the next task.",
                     action: ("Compact", s, "/compact"), weight: u.context))
      }
      if u.recache >= 150_000 {
        t.append(Tip(id: "cache" + s.id, icon: "clock.arrow.circlepath",
                     text: "\(s.name) paid full price for \(fmt(u.recache)) tokens today because its cache expired during breaks (5 min). Compact before stepping away, and end sessions you're done with.",
                     action: ("Compact", s, "/compact"), weight: u.recache))
      }
      let m = u.model.lowercased(), save = 1 - price("sonnet-5").o / price(m).o
      if m.contains("opus") || m.contains("fable"), u.today >= 500_000, save >= 0.3 {
        t.append(Tip(id: "model" + s.id, icon: "cpu",
                     text: "\(s.name) runs on \(m.contains("fable") ? "Fable" : "Opus"). Sonnet costs \(Int(save * 100))% less and handles routine edits, tests and renames well.",
                     action: ("Use Sonnet", s, "/model sonnet"), weight: Int(Double(u.today) * save)))
      }
    }
    let sub = usage.filter { $0.key.contains("/subagents/") }.values.reduce(0) { $0 + $1.today }
    if todayTokens >= 1_000_000, Double(sub) >= 0.4 * Double(todayTokens) {
      t.append(Tip(id: "agents", icon: "person.2.wave.2",
                   text: "Subagents used \(sub * 100 / todayTokens)% of today's tokens. Ask for fewer parallel agents, or name the files to look at instead of a broad search.", weight: sub))
    }
    t.sort { $0.weight > $1.weight }
    if let out = fiveHour?.out {
      t.insert(Tip(id: "pace", icon: "gauge.with.dots.needle.67percent",
                   text: "At this pace you hit the 5-hour limit at \(clock(out)). Pause the sessions you aren't watching, or move routine work to Sonnet."), at: 0)
    }
    return Array(t.filter { !dismissedTips.contains($0.id) }.prefix(3))
  }

  /// Token growth per session over the last 10 minutes; warns once when a session turns heavy.
  func updateBurn() {
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
  func readRegistry() {
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
  func tick() {
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

}
