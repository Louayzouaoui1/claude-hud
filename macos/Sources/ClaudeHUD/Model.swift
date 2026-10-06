import AppKit
import SwiftUI

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

struct Usage: Equatable {
  var tokens = 0, today = 0, context = 0, lastText = "", cost = 0.0, todayCost = 0.0
  var model = ""   // last model that answered
  var recache = 0  // today's tokens written to cache again because it expired (breaks, resumes)
}

/// A way to spend fewer tokens, shown in the drawer's Tips section.
struct Tip: Identifiable {
  let id: String, icon: String, text: String
  var action: (title: String, session: Session, prompt: String)?
  var weight = 0  // tokens at stake, for ordering
}

struct Device: Identifiable, Equatable {
  let id: String, name: String, updated: Date, tokens: Int, cost: Double, live: Int
  var mine = false
  var online: Bool { Date().timeIntervalSince(updated) < 180 }
}

/// A Claude Code session on your account that lives elsewhere (remote control from another machine, or claude.ai/code).
struct Remote: Identifiable, Equatable {
  let id: String, title: String, connected: Bool, working: Bool, model: String, branch: String, last: Date
}

let deviceDir = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Claude HUD/devices")

/// Editors whose Claude Code extension answers `<scheme>://anthropic.claude-code/open`.
