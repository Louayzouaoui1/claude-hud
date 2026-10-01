#!/bin/sh
# Builds ClaudeHUD.app into ~/Applications, wires the Claude Code hooks + statusline, starts it,
# and adds it as a login item. Safe to re-run.
set -e
cd "$(dirname "$0")"
APP=~/Applications/ClaudeHUD.app
D=~/.claude/hud

mkdir -p "$APP/Contents/MacOS" "$D/req" "$D/ans"
swiftc -swift-version 5 -O main.swift -o "$APP/Contents/MacOS/ClaudeHUD"
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
cp event.sh perm.sh statusline.sh "$D/"

# Hooks: drop any previous Claude HUD entries, then add the current ones. Other hooks are untouched.
EV='CLAUDE_PID=$PPID ~/.claude/hud/event.sh'
PERM='CLAUDE_PID=$PPID ~/.claude/hud/perm.sh'
S=~/.claude/settings.json
cp "$S" "$S.bak-claudehud"
jq --arg ev "$EV" --arg perm "$PERM" '
  .hooks |= with_entries(.value |= map(select(all(.hooks[]?; (.command // "") | contains("claude/hud/") | not))))
  | reduce ("SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","Notification","Stop","SessionEnd","SubagentStart","SubagentStop") as $e (.;
      .hooks[$e] += [{hooks: [{type: "command", command: $ev}]}])
  | .hooks.PermissionRequest += [{hooks: [{type: "command", command: $perm, timeout: 600}]}]
  | if .statusLine then . else .statusLine = {type: "command", command: "~/.claude/hud/statusline.sh"} end
' "$S.bak-claudehud" > "$S"

pkill -x ClaudeHUD || true
sleep 0.3
open "$APP"
osascript -e "tell application \"System Events\" to if not (exists login item \"ClaudeHUD\") then make login item at end with properties {path:\"$HOME/Applications/ClaudeHUD.app\", hidden:true}" >/dev/null 2>&1 || true
echo "Claude HUD installed."
