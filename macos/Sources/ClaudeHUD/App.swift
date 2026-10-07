import AppKit
import Carbon
import SwiftUI
import HUDCore

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

