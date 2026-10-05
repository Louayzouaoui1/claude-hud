# Updated by .github/workflows/release.yml on every release. Install with:
#   brew tap louayzouaoui1/claude-hud https://github.com/Louayzouaoui1/claude-hud
#   brew install --cask claude-hud
cask "claude-hud" do
  version "0.0.0"
  sha256 :no_check

  url "https://github.com/Louayzouaoui1/claude-hud/releases/download/v#{version}/ClaudeHUD-#{version}.zip"
  name "Claude HUD"
  desc "Heads-up display for every Claude Code session"
  homepage "https://github.com/Louayzouaoui1/claude-hud"

  depends_on macos: ">= :sonoma"
  depends_on formula: "jq"

  app "ClaudeHUD.app"

  postflight do
    # Ad-hoc signed (no Apple Developer ID yet), so clear quarantine or Gatekeeper blocks the launch.
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/ClaudeHUD.app"]
    system_command "#{appdir}/ClaudeHUD.app/Contents/Resources/setup-hooks.sh",
                   args: ["#{appdir}/ClaudeHUD.app/Contents/Resources"]
    system_command "/usr/bin/open", args: ["#{appdir}/ClaudeHUD.app"]
  end

  uninstall quit:       "com.louay.claudehud",
            login_item: "ClaudeHUD",
            script:     {
              executable: "#{appdir}/ClaudeHUD.app/Contents/Resources/setup-hooks.sh",
              args:       ["--remove"],
            }

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
