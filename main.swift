// Claude HUD — a floating always-on-top panel listing Claude Code sessions.
// Fed by Claude Code hooks appending one JSON line per event to ~/.claude/hud/events.jsonl.
import AppKit
import SwiftUI

let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/hud/events.jsonl")

enum Phase: Int {
  case permission, done, working, ready, ended  // sort order: most urgent first
  var color: Color { [.orange, .green, .blue, .gray, .secondary][rawValue] }
  var label: String { ["needs permission", "your turn", "working…", "ready", "ended"][rawValue] }
}

struct Session: Identifiable {
  let id: String
  var cwd: String
  var phase: Phase
  var since: Date
  var name: String { (cwd as NSString).lastPathComponent }
}

final class Store: ObservableObject {
  @Published var sessions: [String: Session] = [:]
  private var offset: UInt64 = 0

  init() {
    read(alert: false)  // rebuild state from history quietly
    if offset > 2_000_000 { try? Data().write(to: log); offset = 0 }
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.read(alert: true) }
  }

  var sorted: [Session] {
    sessions.values.sorted { ($0.phase.rawValue, $1.since) < ($1.phase.rawValue, $0.since) }
  }

  func read(alert: Bool) {
    guard let h = try? FileHandle(forReadingFrom: log) else { return }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    if size < offset { offset = 0 }  // truncated
    try? h.seek(toOffset: offset)
    guard let data = try? h.readToEnd(), let lastNL = data.lastIndex(of: 10) else { return }
    offset += UInt64(lastNL - data.startIndex + 1)  // keep a half-written line for next time
    for line in data[..<lastNL].split(separator: 10) {
      if let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { apply(j, alert: alert) }
    }
    let now = Date()
    sessions = sessions.filter {
      let age = now.timeIntervalSince($0.value.since)
      return $0.value.phase == .ended ? age < 90 : age < 8 * 3600
    }
  }

  private func apply(_ j: [String: Any], alert: Bool) {
    guard let id = j["s"] as? String, let ev = j["e"] as? String else { return }
    let type = j["t"] as? String ?? ""
    let msg = j["m"] as? String ?? ""
    let next: Phase
    switch ev {
    case "SessionStart": next = .ready
    case "UserPromptSubmit", "PostToolUse": next = .working
    case "Stop": next = .done
    case "SessionEnd": next = .ended
    case "Notification" where type != "idle_prompt" && !(type.isEmpty && msg.contains("waiting for your input")):
      next = .permission
    default: return
    }
    let ts = (j["ts"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
    let prev = sessions[id]
    if prev?.phase == next, next == .working { return }  // keep "working since" stable
    let s = Session(id: id, cwd: prev?.cwd ?? j["c"] as? String ?? "?", phase: next, since: ts)
    sessions[id] = s
    guard alert, prev?.phase != next else { return }
    switch next {
    case .permission: notify(s, msg.isEmpty ? "Needs your permission" : msg, sound: "Glass")
    case .done: notify(s, "Finished — your turn", sound: "Hero")
    case .ended: notify(s, "Session ended", sound: "Pop")
    default: break
    }
  }

  private func notify(_ s: Session, _ body: String, sound: String) {
    NSSound(named: sound)?.play()
    let esc = { (x: String) in x.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"Claude · \(esc(s.name))\""]
    try? p.run()
  }

  func open(_ s: Session) {
    NSWorkspace.shared.open([URL(fileURLWithPath: s.cwd)],
                            withApplicationAt: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
                            configuration: NSWorkspace.OpenConfiguration())
  }
}

struct Dot: View {
  let phase: Phase
  var body: some View {
    Circle().fill(phase.color).frame(width: 8, height: 8)
      .phaseAnimator(phase == .permission || phase == .working ? [1.0, 0.35] : [1.0]) { v, p in
        v.opacity(p).scaleEffect(phase == .permission ? 2 - p : 1)
      } animation: { _ in .easeInOut(duration: 0.8) }
  }
}

struct HUD: View {
  @ObservedObject var store: Store
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if store.sessions.isEmpty {
        Text("Claude · no sessions").font(.caption).foregroundStyle(.secondary)
      }
      ForEach(store.sorted) { s in
        HStack(spacing: 8) {
          Dot(phase: s.phase)
          Text(s.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
          Spacer(minLength: 8)
          Text(s.phase.label).font(.system(size: 11)).foregroundStyle(s.phase.color)
          Text(s.since, style: .timer).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            .frame(width: 38, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.open(s) }
        .help(s.cwd)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
      }
    }
    .animation(.spring(duration: 0.35), value: store.sorted.map { "\($0.id)\($0.phase)" })
    .padding(.horizontal, 12).padding(.vertical, 9)
    .frame(width: 290, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
    .contextMenu {
      Button("Clear finished") { store.sessions = store.sessions.filter { $0.value.phase.rawValue >= Phase.working.rawValue && $0.value.phase != .ended } }
      Button("Quit Claude HUD") { NSApp.terminate(nil) }
    }
  }
}

final class Panel: NSPanel {
  override var canBecomeKey: Bool { false }
}

final class App: NSObject, NSApplicationDelegate {
  var panel: Panel!
  let store = Store()

  func applicationDidFinishLaunching(_ n: Notification) {
    let host = NSHostingController(rootView: HUD(store: store))
    host.sizingOptions = .preferredContentSize
    panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.contentViewController = host
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.isMovableByWindowBackground = true
    panel.backgroundColor = .clear
    panel.hasShadow = true
    if !panel.setFrameUsingName("ClaudeHUD"), let v = NSScreen.main?.visibleFrame {
      panel.setFrameTopLeftPoint(NSPoint(x: v.maxX - 310, y: v.maxY - 10))  // top-right; grows downward
    }
    panel.setFrameAutosaveName("ClaudeHUD")
    panel.orderFrontRegardless()
  }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // no Dock icon
app.run()
