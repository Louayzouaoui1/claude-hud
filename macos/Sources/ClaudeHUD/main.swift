// Claude HUD — an edge drawer + toasts for Claude Code sessions running in any IDE or terminal.
// Fed by hooks (see hooks/): events.jsonl = session state, req/ + ans/ = permission
// requests answered from here, limits.json = 5-hour / weekly usage.
import AppKit

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // no Dock icon
app.run()
