#!/bin/sh
# Statusline: saves the 5-hour / weekly rate limits for Claude HUD, prints a compact line.
j=$(cat)
L="$HOME/.claude/hud/limits.json"
echo "$j" | jq -ce '.rate_limits // empty' > "$L.tmp" 2>/dev/null && mv "$L.tmp" "$L" || rm -f "$L.tmp"
echo "$j" | jq -r '[.model.display_name, (.workspace.current_dir | split("/") | last),
  (.rate_limits.five_hour.used_percentage | if . then "5h \(floor)%" else empty end),
  (.rate_limits.seven_day.used_percentage | if . then "wk \(floor)%" else empty end)] | map(select(.)) | join(" · ")'
