#!/bin/sh
# Hook for every session event: append one compact line for Claude HUD.
exec jq -c --argjson p "${CLAUDE_PID:-0}" '{s:.session_id, e:.hook_event_name, c:.cwd, t:.notification_type, m:.message,
  tp:.transcript_path, tn:.tool_name, ts:now, p:$p,
  x:((.tool_input // {}) | (.command // .file_path // .pattern // .url // .query // .description // "") | tostring | .[0:160])}' \
  >> "$HOME/.claude/hud/events.jsonl"
