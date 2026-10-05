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

