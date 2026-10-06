import AppKit
import SwiftUI
import HUDCore

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

/// The Claude process's own working directory = the Cursor workspace (a hook's cwd follows `cd`).
func processCwd(_ pid: Int32) -> String? {
  var info = proc_vnodepathinfo()
  let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
  guard pid > 1, proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
  return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
}

