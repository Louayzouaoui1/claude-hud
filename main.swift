// Claude HUD — an edge drawer + toasts for Claude Code sessions running in Cursor.
// Fed by hooks (see install.sh): events.jsonl = session state, req/ + ans/ = permission
// requests answered from here, limits.json = rate limits saved by the statusline.
import AppKit
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

struct Request: Equatable { let id: String, tool: String, detail: String }

struct Session: Identifiable {
  let id: String
  var cwd: String
  var phase: Phase
  var since: Date
  var pid: Int32 = 0
  var transcript = ""
  var request: Request?
  var name: String { (cwd as NSString).lastPathComponent }
}

struct Usage { var tokens = 0, today = 0, context = 0, lastText = "" }
struct Limit { let pct: Double, resets: Date }

struct Toast: Identifiable, Equatable {
  let id = UUID()
  let session: String
  let text: String
  let created = Date()
}

func fmt(_ n: Int) -> String {
  n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.0fk", Double(n) / 1e3) : "\(n)"
}

/// The Claude process's own working directory = the Cursor workspace (a hook's cwd follows `cd`).
func processCwd(_ pid: Int32) -> String? {
  var info = proc_vnodepathinfo()
  let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
  guard pid > 1, proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
  return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
}

func until(_ d: Date) -> String {
  let s = max(0, Int(d.timeIntervalSinceNow)), h = s / 3600, m = s % 3600 / 60
  return h >= 24 ? "\(h / 24)d \(h % 24)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
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
  @Published var replyTarget: String?
  @Published var fiveHour: Limit?
  @Published var week: Limit?
  var hoveredToast: UUID?
  var hitRects: [CGRect] = []
  private var offset: UInt64 = 0
  private var passthrough: [String: Date] = [:]
  private let counter = TokenCounter()
  private let queue = DispatchQueue(label: "tokens", qos: .utility)
  static let spring = Animation.spring(response: 0.5, dampingFraction: 0.84)

  init() {
    let fm = FileManager.default
    for d in [reqDir, ansDir] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
    for f in (try? fm.contentsOfDirectory(at: ansDir, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: f) }
    readEvents(alert: false)  // rebuild state from history quietly
    if offset > 2_000_000 { try? Data().write(to: eventsURL); offset = 0 }
    refreshUsage()
    Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
      withAnimation(Store.spring) { self?.tick() }
    }
    Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refreshUsage() }
  }

  var sorted: [Session] {
    sessions.values.sorted { ($0.phase.rawValue, $1.since) < ($1.phase.rawValue, $0.since) }
  }
  var urgent: Phase? { sorted.first?.phase }
  var todayTokens: Int { usage.values.reduce(0) { $0 + $1.today } }
  func usage(_ s: Session) -> Usage {
    usage[s.transcript] ?? usage.first { $0.key.hasSuffix("/\(s.id).jsonl") }?.value ?? Usage()
  }

  private func tick() {
    readEvents(alert: true)
    readRequests()
    let now = Date()
    for (id, s) in sessions where s.phase != .ended && s.pid > 1 && kill(s.pid, 0) != 0 {
      sessions[id]?.phase = .ended
      sessions[id]?.since = now
    }
    sessions = sessions.filter {
      let age = now.timeIntervalSince($0.value.since)
      return $0.value.phase == .ended ? age < 60 : age < 8 * 3600
    }
    toasts.removeAll { t in
      guard let s = sessions[t.session] else { return true }
      if s.phase == .permission { return false }
      return t.id != hoveredToast && replyTarget != t.session && now.timeIntervalSince(t.created) > 9
    }
  }

  private func refreshUsage() {
    if let d = try? Data(contentsOf: limitsURL), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
      func lim(_ k: String) -> Limit? {
        guard let o = j[k] as? [String: Any], let p = o["used_percentage"] as? Double else { return nil }
        let r = Date(timeIntervalSince1970: o["resets_at"] as? Double ?? 0)
        return Limit(pct: r < Date() ? 0 : p, resets: r)
      }
      fiveHour = lim("five_hour")
      week = lim("seven_day")
    }
    queue.async { [counter] in
      let u = counter.scan()
      DispatchQueue.main.async { self.usage = u }
    }
  }

  // MARK: events.jsonl

  private func readEvents(alert: Bool) {
    guard let h = try? FileHandle(forReadingFrom: eventsURL) else { return }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    if size < offset { offset = 0 }
    try? h.seek(toOffset: offset)
    guard let data = try? h.readToEnd(), let nl = data.lastIndex(of: 10) else { return }
    offset += UInt64(nl - data.startIndex + 1)  // a half-written line waits for next time
    for line in data[..<nl].split(separator: 10) {
      if let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { apply(j, alert: alert) }
    }
  }

  private func apply(_ j: [String: Any], alert doAlert: Bool) {
    guard let id = j["s"] as? String, let ev = j["e"] as? String else { return }
    let type = j["t"] as? String ?? "", msg = j["m"] as? String ?? ""
    let next: Phase
    switch ev {
    case "SessionStart": next = .ready
    case "UserPromptSubmit", "PostToolUse": next = .working
    case "Stop": next = .done
    case "SessionEnd": next = .ended
    case "Notification" where ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog"].contains(type):
      next = .permission
    default: return
    }
    let ts = (j["ts"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
    let prev = sessions[id]?.phase
    var s = sessions[id] ?? Session(id: id, cwd: j["c"] as? String ?? "?", phase: next, since: ts)
    if let p = j["p"] as? Int, p > 1, s.pid != Int32(p) {
      s.pid = Int32(p)
      if let c = processCwd(s.pid) { s.cwd = c }
    }
    if let tp = j["tp"] as? String, !tp.isEmpty { s.transcript = tp }
    let keep = (prev == .working && next == .working) || (s.request != nil && (next == .working || next == .permission))
    if !keep { s.phase = next; s.since = ts }
    sessions[id] = s
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

  private func readRequests() {
    let fm = FileManager.default
    var live = Set<String>()
    for f in (try? fm.contentsOfDirectory(at: reqDir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" {
      let rid = f.deletingPathExtension().lastPathComponent
      guard let d = try? Data(contentsOf: f), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let sid = j["session_id"] as? String else { continue }
      let pid = Int32(j["pid"] as? Int ?? 0)
      if pid > 1, kill(pid, 0) != 0 { try? fm.removeItem(at: f); continue }
      live.insert(rid)
      if sessions[sid]?.request != nil { continue }  // one at a time per session
      let tool = j["tool_name"] as? String ?? "Tool"
      let input = j["tool_input"] as? [String: Any] ?? [:]
      let detail = ["command", "file_path", "url", "pattern", "query", "description", "prompt"]
        .lazy.compactMap { input[$0] as? String }.first
        ?? (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
      var s = sessions[sid] ?? Session(id: sid, cwd: j["cwd"] as? String ?? "?", phase: .permission, since: Date())
      s.request = Request(id: rid, tool: tool, detail: detail)
      s.phase = .permission
      s.since = Date()
      if s.pid < 2 { s.pid = pid; s.cwd = processCwd(pid) ?? s.cwd }
      if s.transcript.isEmpty { s.transcript = j["transcript_path"] as? String ?? "" }
      sessions[sid] = s
      alert(s, "", sound: "Glass")
    }
    for (id, s) in sessions where s.request.map({ !live.contains($0.id) }) ?? false {
      sessions[id]?.request = nil
      if s.phase == .permission { sessions[id]?.phase = .working }
    }
  }

  enum Answer { case allow, deny, cursor }

  func answer(_ s: Session, _ a: Answer) {
    guard let r = s.request else { return jump(s) }
    let decision = a == .allow ? #"{"behavior":"allow"}"# : #"{"behavior":"deny","message":"Denied from Claude HUD"}"#
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
    NSSound(named: sound)?.play()
    toasts.removeAll { $0.session == s.id }
    toasts.append(Toast(session: s.id, text: text))
    if toasts.count > 4, let i = toasts.firstIndex(where: { sessions[$0.session]?.phase != .permission }) {
      toasts.remove(at: i)
    }
  }

  func dismiss(_ t: Toast) { withAnimation(Store.spring) { toasts.removeAll { $0.id == t.id } } }

  /// Focus the Cursor window holding the session's folder, then its exact chat tab (optionally pre-filling a reply).
  func jump(_ s: Session, prompt: String? = nil) {
    NSWorkspace.shared.open([URL(fileURLWithPath: s.cwd)],
                            withApplicationAt: URL(fileURLWithPath: "/Applications/Cursor.app"),
                            configuration: NSWorkspace.OpenConfiguration())
    var c = URLComponents(string: "cursor://anthropic.claude-code/open")!
    c.queryItems = [URLQueryItem(name: "session", value: s.id)]
    if let p = prompt, !p.isEmpty { c.queryItems?.append(URLQueryItem(name: "prompt", value: p)) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSWorkspace.shared.open(c.url!) }
    withAnimation(Store.spring) {
      drawerOpen = false
      replyTarget = nil
      toasts.removeAll { $0.session == s.id }
    }
  }

  func end(_ s: Session) {
    if s.pid > 1 { kill(s.pid, SIGTERM) }
    withAnimation(Store.spring) {
      sessions[s.id]?.phase = .ended
      sessions[s.id]?.since = Date()
    }
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
        shape.fill(.ultraThinMaterial)
        shape.fill(LinearGradient(colors: [Color(white: 0.09).opacity(0.78), Color(white: 0.02).opacity(0.9)],
                                  startPoint: .top, endPoint: .bottom))
        shape.fill(RadialGradient(colors: [tint.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 280))
      }
    }
    .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.04), tint.opacity(0.4)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
    .shadow(color: .black.opacity(0.5), radius: 28, y: 14)
  }
}

/// Slide in from the screen edge, sharpening out of a blur.
struct EdgeSlide: ViewModifier {
  let x: CGFloat, blur: CGFloat, scale: CGFloat
  func body(content: Content) -> some View {
    content.scaleEffect(scale, anchor: .trailing).blur(radius: blur).offset(x: x).opacity(x == 0 ? 1 : 0)
  }
}

extension AnyTransition {
  static let edge = AnyTransition.asymmetric(
    insertion: .modifier(active: EdgeSlide(x: 380, blur: 14, scale: 0.92), identity: EdgeSlide(x: 0, blur: 0, scale: 1)),
    removal: .modifier(active: EdgeSlide(x: 380, blur: 8, scale: 0.97), identity: EdgeSlide(x: 0, blur: 0, scale: 1)))
}

struct StatusDot: View {
  let phase: Phase
  @State private var on = false
  var body: some View {
    ZStack {
      if phase == .working {
        Circle().trim(from: 0, to: 0.68)
          .stroke(phase.color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
          .frame(width: 15, height: 15)
          .rotationEffect(.degrees(on ? 360 : 0))
          .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: on)
      }
      if phase == .permission {
        Circle().stroke(phase.color, lineWidth: 1.5).frame(width: 8, height: 8)
          .scaleEffect(on ? 2.6 : 1).opacity(on ? 0 : 0.9)
          .animation(.easeOut(duration: 1.3).repeatForever(autoreverses: false), value: on)
      }
      Circle().fill(phase.color).frame(width: 7, height: 7).shadow(color: phase.color.opacity(0.9), radius: 5)
    }
    .frame(width: 18, height: 18)
    .onAppear { on = true }
    .id(phase)
  }
}

struct Pill: View {
  let title: String
  var icon: String?
  var tint: Color = .white
  var primary = false
  let action: () -> Void
  @State private var hover = false
  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        if let icon { Image(systemName: icon).font(.system(size: 9.5, weight: .bold)) }
        Text(title)
      }
      .font(.system(size: 11.5, weight: .semibold, design: .rounded))
      .foregroundStyle(primary ? Color.black.opacity(0.85) : tint.opacity(hover ? 1 : 0.85))
      .padding(.horizontal, 11).padding(.vertical, 6)
      .background(Capsule().fill(primary ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(hover ? 0.16 : 0.08))))
      .overlay(Capsule().strokeBorder(.white.opacity(primary ? 0.3 : 0.08)))
      .shadow(color: primary ? tint.opacity(hover ? 0.6 : 0.35) : .clear, radius: 8)
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
        Pill(title: "Deny", icon: "xmark", tint: Color(red: 1, green: 0.45, blue: 0.5)) { store.answer(s, .deny) }
        Spacer()
        Pill(title: "In Cursor", icon: "arrow.up.right") { store.answer(s, .cursor) }
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
  @State private var hover = false
  @State private var shown = false
  @State private var confirmEnd = false

  var body: some View {
    let u = store.usage(s)
    let replying = store.replyTarget == s.id
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        StatusDot(phase: s.phase)
        VStack(alignment: .leading, spacing: 2) {
          Text(s.name).font(.system(size: 13.5, weight: .semibold, design: .rounded)).lineLimit(1)
          HStack(spacing: 5) {
            Text(s.phase.label).foregroundStyle(s.phase.color)
            Text("·")
            Text(s.since, style: .timer).monospacedDigit()
          }
          .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.45))
        }
        Spacer(minLength: 6)
        VStack(alignment: .trailing, spacing: 2) {
          Text(fmt(u.tokens)).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
          Text("\(fmt(u.context)) ctx").font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.38))
        }
        .help("Tokens this session (input + cache writes + output) · current context size")
      }
      if let r = s.request {
        RequestBlock(store: store, s: s, r: r)
      } else if s.phase == .done, !u.lastText.isEmpty {
        Text(u.lastText).font(.system(size: 11.5, design: .rounded)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
      }
      if (hover || replying) && s.request == nil {
        HStack(spacing: 6) {
          Pill(title: "Open", icon: "arrow.up.right") { store.jump(s) }
          if s.phase != .ended {
            Pill(title: "Reply", icon: "arrowshape.turn.up.left.fill", tint: Phase.done.color) {
              withAnimation(Store.spring) { store.replyTarget = replying ? nil : s.id }
            }
          }
          Spacer()
          if s.phase != .ended {
            Pill(title: confirmEnd ? "End session?" : "End", icon: "power", tint: Color(red: 1, green: 0.45, blue: 0.5)) {
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
    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(hover ? 0.075 : 0.04)))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
      .strokeBorder(s.phase.color.opacity(s.phase == .permission ? 0.5 : hover ? 0.22 : 0.07)))
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
            .shadow(color: colors[1].opacity(0.7), radius: 6)
        }
      }
      .frame(height: 5)
      Text(limit.map { "resets in \(until($0.resets))" } ?? "waiting for data")
        .font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.35))
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
          ForEach(Array(list.enumerated()), id: \.element.id) { i, s in SessionCard(store: store, s: s, index: i) }
        }
        ViewThatFits(in: .vertical) {
          cards
          ScrollView(showsIndicators: false) { cards }
        }
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
        Button { store.dismiss(t) } label: {
          Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.5))
            .frame(width: 20, height: 20).background(Circle().fill(.white.opacity(0.07)))
        }
        .buttonStyle(Press())
        .accessibilityLabel("Dismiss")
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
    .overlay(alignment: .leading) {
      Capsule().fill(s.phase.color).frame(width: 3).padding(.vertical, 16)
        .shadow(color: s.phase.color, radius: 6).offset(x: 1)
    }
    .contentShape(Rectangle())
    .onTapGesture { store.jump(s) }
    .onHover { store.hoveredToast = $0 ? t.id : nil }
    .hitArea()
  }
}

// MARK: - Root

struct EdgeHandle: View {
  let phase: Phase?
  @State private var breathe = false
  var body: some View {
    let c = phase?.color ?? .white.opacity(0.35)
    Capsule().fill(c.gradient)
      .frame(width: 4, height: phase == .permission ? 90 : 64)
      .shadow(color: c.opacity(breathe ? 0.95 : 0.4), radius: breathe ? 10 : 5)
      .opacity(phase == nil ? 0.45 : 1)
      .animation(.easeInOut(duration: phase == .permission ? 0.7 : 1.8).repeatForever(), value: breathe)
      .onAppear { breathe = true }
  }
}

struct Root: View {
  @ObservedObject var store: Store
  var body: some View {
    ZStack(alignment: .trailing) {
      Color.clear
      if store.drawerOpen {
        Drawer(store: store).padding(.trailing, 12).transition(.edge)
      } else {
        EdgeHandle(phase: store.urgent).padding(.trailing, 1).transition(.opacity)
      }
    }
    .overlay(alignment: .topTrailing) {
      if !store.drawerOpen {
        VStack(alignment: .trailing, spacing: 10) {
          ForEach(store.toasts) { t in
            if let s = store.sessions[t.session] { ToastCard(store: store, t: t, s: s).transition(.edge) }
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
    Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.track() }
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
    guard store.drawerOpen else { return }
    if overUI || atEdge || store.replyTarget != nil { leftSince = nil; return }
    leftSince = leftSince ?? Date()
    if Date().timeIntervalSince(leftSince!) > 0.4 {
      withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { store.drawerOpen = false }
    }
  }

  func windowDidResignKey(_ n: Notification) {
    withAnimation(Store.spring) { store.replyTarget = nil }
  }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // no Dock icon
app.run()
