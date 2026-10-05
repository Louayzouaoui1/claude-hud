#!/bin/sh
# PermissionRequest hook: let Claude HUD answer the prompt. Prints nothing (= the normal
# dialog in Cursor) if the HUD isn't running, the user picks "In Cursor", or ~10 min pass.
D="$HOME/.claude/hud"
pgrep -qx ClaudeHUD || exit 0
[ -f "$D/answer-off" ] && exit 0
id=$(uuidgen)
mkdir -p "$D/req" "$D/ans"
jq -c --argjson pid "${CLAUDE_PID:-0}" '. + {pid: $pid}' > "$D/req/$id.tmp" && mv "$D/req/$id.tmp" "$D/req/$id.json"
trap 'rm -f "$D/req/$id.json"' EXIT
n=0
while [ $n -lt 2300 ]; do
  if [ -f "$D/ans/$id" ]; then cat "$D/ans/$id"; rm -f "$D/ans/$id"; exit 0; fi
  sleep 0.25; n=$((n + 1))
done
