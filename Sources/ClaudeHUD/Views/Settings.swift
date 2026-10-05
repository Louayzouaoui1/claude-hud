import AppKit
import SwiftUI

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
             ? "Prompts go to the HUD first; \(editor.name) shows its dialog once you pick “\(editor.name)”."
             : "Prompts appear in \(editor.name) as usual; the HUD only notifies you.")
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
        Text("Each Mac running Claude HUD writes today's tokens and cost to iCloud Drive › Claude HUD. Remote-control and claude.ai/code sessions on your account are listed too, and usage that grows while this Mac is idle shows as “Elsewhere”. Anthropic doesn't expose a list of signed-in devices.")
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

