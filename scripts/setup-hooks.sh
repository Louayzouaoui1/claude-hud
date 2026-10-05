#!/bin/sh
# Wires Claude HUD into Claude Code: copies the hook scripts to ~/.claude/hud and adds them to
# ~/.claude/settings.json (other hooks are left alone). Safe to re-run.
#   setup-hooks.sh <dir with the hook scripts>   install / update
#   setup-hooks.sh --remove                      take the hooks and status line back out
set -e
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"  # jq, when run from a Homebrew cask
D=~/.claude/hud
S=~/.claude/settings.json
mkdir -p ~/.claude
[ -f "$S" ] || echo '{}' > "$S"
cp "$S" "$S.bak-claudehud"
# Drop every previous Claude HUD entry, keep everything else.
STRIP='.hooks |= ((. // {}) | with_entries(.value |= map(select(all(.hooks[]?; (.command // "") | contains("claude/hud/") | not))))
  | with_entries(select(.value | length > 0)))
  | if (.statusLine.command // "" | contains("claude/hud/")) then del(.statusLine) else . end'

if [ "$1" = "--remove" ]; then
  jq "$STRIP" "$S.bak-claudehud" > "$S"
  echo "Claude HUD hooks removed."
  exit 0
fi

SRC=${1:?usage: setup-hooks.sh <hooks dir> | --remove}
mkdir -p "$D/req" "$D/ans"
cp "$SRC/event.sh" "$SRC/perm.sh" "$SRC/statusline.sh" "$D/"
chmod +x "$D"/*.sh
EV='CLAUDE_PID=$PPID ~/.claude/hud/event.sh'
PERM='CLAUDE_PID=$PPID ~/.claude/hud/perm.sh'
jq --arg ev "$EV" --arg perm "$PERM" "$STRIP"'
  | reduce ("SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","Notification","Stop","SessionEnd","SubagentStart","SubagentStop") as $e (.;
      .hooks[$e] += [{hooks: [{type: "command", command: $ev}]}])
  | .hooks.PermissionRequest += [{hooks: [{type: "command", command: $perm, timeout: 600}]}]
  | if .statusLine then . else .statusLine = {type: "command", command: "~/.claude/hud/statusline.sh"} end
' "$S.bak-claudehud" > "$S"
echo "Claude HUD hooks installed."
