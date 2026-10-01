#!/bin/sh
# Builds ClaudeHUD.app into ~/Applications, wires the Claude Code hooks, starts it, and adds it as a login item.
set -e
cd "$(dirname "$0")"
APP=~/Applications/ClaudeHUD.app

mkdir -p "$APP/Contents/MacOS" ~/.claude/hud
swiftc -O main.swift -o "$APP/Contents/MacOS/ClaudeHUD"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.louay.claudehud</string>
  <key>CFBundleName</key><string>Claude HUD</string>
  <key>CFBundleExecutable</key><string>ClaudeHUD</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign -s - -f "$APP" >/dev/null 2>&1 || true

# Hooks: merge into ~/.claude/settings.json without touching existing ones (idempotent).
CMD="jq -c '{s:.session_id,e:.hook_event_name,c:.cwd,t:.notification_type,m:.message,ts:now}' >> ~/.claude/hud/events.jsonl"
S=~/.claude/settings.json
cp "$S" "$S.bak-claudehud"
jq --arg cmd "$CMD" '
  reduce ("SessionStart","UserPromptSubmit","PostToolUse","Notification","Stop","SessionEnd") as $e (.;
    if any(.hooks[$e][]?.hooks[]?; .command == $cmd) then .
    else .hooks[$e] += [{hooks: [{type: "command", command: $cmd}]}] end)
' "$S.bak-claudehud" > "$S"

pkill -x ClaudeHUD || true
open "$APP"
osascript -e "tell application \"System Events\" to if not (exists login item \"ClaudeHUD\") then make login item at end with properties {path:\"$HOME/Applications/ClaudeHUD.app\", hidden:true}" >/dev/null || echo "(could not add login item — add ClaudeHUD in System Settings › Login Items)"
echo "Claude HUD installed."
