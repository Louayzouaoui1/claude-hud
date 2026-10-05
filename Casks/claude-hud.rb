# Updated by .github/workflows/release.yml on every release. Install with:
#   brew tap louayzouaoui1/claude-hud https://github.com/Louayzouaoui1/claude-hud
#   brew install --cask claude-hud
cask "claude-hud" do
  version "1.1.1"
  sha256 "c6a7fd3420200bbbd67f684f59e0afbd5ab41a02143a47ba5314d40108225c68"

  url "https://github.com/Louayzouaoui1/claude-hud/releases/download/v#{version}/ClaudeHUD-#{version}.zip"
  name "Claude HUD"
  desc "Heads-up display for every Claude Code session"
  homepage "https://github.com/Louayzouaoui1/claude-hud"

  depends_on formula: "jq"
  depends_on macos: :sonoma

  app "ClaudeHUD.app"

  postflight_steps do
    # Ad-hoc signed (no Apple Developer ID yet), so clear quarantine or Gatekeeper blocks the launch.
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/ClaudeHUD.app"], must_succeed: false
    run "ClaudeHUD.app/Contents/Resources/setup-hooks.sh",
        base:           :appdir,
        args:           ["{{appdir}}/ClaudeHUD.app/Contents/Resources"],
        writable_paths: [".claude"],
        writable_base:  :home
    run "/usr/bin/open", args: ["{{appdir}}/ClaudeHUD.app"], must_succeed: false
  end

  uninstall_preflight_steps do
    run "ClaudeHUD.app/Contents/Resources/setup-hooks.sh",
        base:           :appdir,
        args:           ["--remove"],
        writable_paths: [".claude"],
        writable_base:  :home,
        must_succeed:   false
  end

  uninstall quit:       "com.louay.claudehud",
            login_item: "ClaudeHUD"

  zap trash: [
    "~/.claude/hud",
    "~/.claude/settings.json.bak-claudehud",
    "~/Library/Preferences/com.louay.claudehud.plist",
  ]

  caveats <<~EOS
    Claude HUD needs Accessibility access to land in the right editor window:
      System Settings → Privacy & Security → Accessibility → enable Claude HUD.
    The app is ad-hoc signed, so macOS may ask for this again after an update.
  EOS
end
