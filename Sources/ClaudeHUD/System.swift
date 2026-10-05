import AppKit
import SwiftUI

// Host apps, processes and formatting.
struct Editor { let name: String, bundle: String, scheme: String }
let editors = [Editor(name: "Cursor", bundle: "com.todesktop.230313mzl4w4u92", scheme: "cursor"),
               Editor(name: "VS Code", bundle: "com.microsoft.VSCode", scheme: "vscode"),
               Editor(name: "VS Code Insiders", bundle: "com.microsoft.VSCodeInsiders", scheme: "vscode-insiders")]
/// The running editor (first match wins), else the first one installed.
var editor: Editor {
  editors.first { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundle).isEmpty }
    ?? editors.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundle) != nil } ?? editors[0]
}

/// The app a session runs in (IDE, terminal, …): the first regular app up the Claude process's parent chain.
func hostApp(_ pid: Int32) -> NSRunningApplication? {
  var p = pid
  for _ in 0..<32 where p > 1 {
    if let a = NSRunningApplication(processIdentifier: p), a.activationPolicy == .regular { return a }
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, p]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    p = info.kp_eproc.e_ppid
  }
  return nil
}

/// Title of the editor's focused window, when it is frontmost (needs Accessibility).
func cursorWindowTitle(_ bundle: String = editor.bundle) -> String? {
  guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
        app.bundleIdentifier == bundle else { return nil }
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

