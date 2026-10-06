import AppKit
import Carbon
import SwiftUI
import HUDCore

extension Store {
  // MARK: actions

  func alert(_ s: Session, _ text: String, sound: String, pref: String, heavy: Bool = false) {
    guard !quiet, prefs.bool(forKey: pref), retired[s.id] == nil else { return }  // muted: state still updates, the edge still glows
    if prefs.bool(forKey: "sounds") { NSSound(named: sound)?.play() }
    var t = toasts.filter { $0.session != s.id }
    t.append(Toast(session: s.id, text: text, heavy: heavy))
    if t.count > 4, let i = t.firstIndex(where: { sessions[$0.session]?.phase != .permission }) { t.remove(at: i) }
    withAnimation(Store.spring) { toasts = t }
  }

  func notice(_ title: String, _ text: String) {
    guard !quiet, prefs.bool(forKey: "notifyUsage") else { return }
    if prefs.bool(forKey: "sounds") { NSSound(named: "Submarine")?.play() }
    withAnimation(Store.spring) { toasts.append(Toast(session: "", text: text, title: title)) }
  }

  /// The editor a session runs in, when it's one we can deep-link into (else the running editor).
  func host(_ s: Session) -> Editor {
    let b = hostApp(s.pid)?.bundleIdentifier
    return editors.first { $0.bundle == b } ?? editor
  }

  /// Sessions in an app without a deep link (terminal, JetBrains, …): bring that app forward and put any
  /// text on the clipboard. Returns false when the session's app is a supported editor (or unknown).
  func reach(_ s: Session, _ text: String?, fresh: Bool = false) -> Bool {
    guard let app = hostApp(s.pid), !editors.contains(where: { $0.bundle == app.bundleIdentifier }) else { return false }
    app.activate()
    if let text, !text.isEmpty {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      let where_ = app.localizedName ?? "the terminal"
      withAnimation(Store.spring) {
        toasts.append(Toast(session: "", text: fresh ? "Start a new claude session in \(where_) and paste (⌘V)." : "Paste it into \(s.name) in \(where_) (⌘V).",
                            title: fresh ? "Handoff copied" : "Reply copied"))
      }
    }
    return true
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
    if !reach(s, prompt) { openInCursor(s.cwd, q, in: host(s)) }
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
    let manual = reach(s, prompt, fresh: true)
    if !manual { openInCursor(s.cwd, [URLQueryItem(name: "prompt", value: prompt)], send: prefs.bool(forKey: "autoSend"), in: host(s)) }
    close()
    pendingHandoff = (s.id, s.cwd, Date())
    if !manual, prefs.bool(forKey: "autoEndOld"), s.pid > 1 {  // pasted by hand: the user ends the old one
      let pid = s.pid
      DispatchQueue.main.asyncAfter(deadline: .now() + 15) { kill(pid, SIGTERM) }  // after the new one has its prompt
    }
    withAnimation(Store.spring) {
      retired[s.id] = ""
      toasts.removeAll { $0.session == s.id }
    }
  }

  @discardableResult
  func writeHandoff(_ s: Session) -> URL {
    let dir = hudDir.appendingPathComponent("handoff")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date()).prefix(16).replacingOccurrences(of: ":", with: "")
    let file = dir.appendingPathComponent("\(s.name)-\(stamp).md")
    try? handoffNote(s).write(to: file, atomically: true, encoding: .utf8)
    return file
  }

  /// Auto-handoff: write the note in the background as soon as a session turns heavy, so Fresh session is instant.
  func prepareHandoff(_ s: Session) {
    queue.async {
      let f = self.writeHandoff(s)
      DispatchQueue.main.async { self.prepared[s.id] = (f, Date()) }
    }
  }

  /// Brings up the Cursor window for `cwd`, waits until it's really in front (so the tab lands in the right
  /// workspace), then opens the Claude tab. With `send`, presses Return in the new chat box.
  func openInCursor(_ cwd: String, _ query: [URLQueryItem], send: Bool = false, in ed: Editor = editor) {
    if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ed.bundle) {
      NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    var c = URLComponents(string: "\(ed.scheme)://anthropic.claude-code/open")!
    if !query.isEmpty { c.queryItems = query }
    let url = c.url!, name = (cwd as NSString).lastPathComponent
    let trusted = AXIsProcessTrusted()
    var tries = 0
    func ready() -> Bool { cursorWindowTitle(ed.bundle)?.contains(name) == true }
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
  func remindIdle() {
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
  func syncDevices() {
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

  func handoffNote(_ s: Session) -> String {
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
