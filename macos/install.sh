#!/bin/sh
# Builds ClaudeHUD.app into ~/Applications, wires the Claude Code hooks + status line, starts it,
# and adds it as a login item. Safe to re-run. (Homebrew users: see the README instead.)
set -e
cd "$(dirname "$0")"
scripts/bundle.sh "$(git describe --tags --always 2>/dev/null || echo dev)"
APP=~/Applications/ClaudeHUD.app
pkill -x ClaudeHUD || true
mkdir -p ~/Applications
rm -rf "$APP" && cp -R dist/ClaudeHUD.app "$APP"
scripts/setup-hooks.sh hooks
sleep 0.3
open "$APP"
osascript -e "tell application \"System Events\" to if not (exists login item \"ClaudeHUD\") then make login item at end with properties {path:\"$APP\", hidden:true}" >/dev/null 2>&1 || true
echo "Claude HUD installed."
