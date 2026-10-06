# Claude HUD for Windows

A native Windows port of Claude HUD: a heads-up display at the right edge of your screen for every [Claude Code](https://claude.com/claude-code) session you run. It shows what each session is doing, what it costs, how close you are to your limits, and which session needs you next. You can answer from the HUD without switching windows.

Runs natively on **x64, ARM64 and x86** Windows 10/11. It is one small `.exe` plus a hook helper, built with the C# compiler that ships with Windows, so there's nothing to download first.

## Install

Double-click **`Install Claude HUD.cmd`**, or run:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

That's the whole setup. The installer:

1. builds the app if needed (takes a few seconds, no SDK needed),
2. copies it to `%LOCALAPPDATA%\Programs\ClaudeHUD`,
3. wires the hooks and status line into `~/.claude/settings.json` (backup: `settings.json.bak-claudehud`; your other hooks and an existing status line are kept),
4. adds a Start menu shortcut and an entry in **Settings › Apps** for uninstalling,
5. starts the HUD, which also starts at sign-in.

Restart any Claude Code sessions that were already open so they report to the HUD. If the hooks ever go missing or get out of date (another tool rewrote `settings.json`, say), the app repairs them on its next start.

## Use it

- **Hover the right edge of the screen**, press **Ctrl+Alt+Space**, or click the tray icon to open the drawer.
- **Toasts** slide in when a session finishes, needs permission, or Claude asks you a question.
- **Permission prompts:** choose **Allow**, **Always** or **Deny**, or send it back to your editor.
- **Questions** (`AskUserQuestion`): pick an option with one click, tick several for multi-select, or type your own answer under *Other*.
- **Errors from Anthropic** (payment due, access disabled for your organization, signed out, usage limit, overload) pop up in red with the fix, such as an *Open billing* button. When the next real reply arrives you get a green *Payment went through / Claude is answering again*.
- **Keyboard** (with the drawer opened by the shortcut): `↑ ↓` move, `Enter` open, `A` allow, `D` deny, `R` reply, `/` search, `Esc` close.
- **Tray icon:** a ring showing the 5-hour usage (turns red with a "!" when Anthropic is refusing requests). Right-click for Settings, Do Not Disturb and Quit.

Everything in the macOS version is here: costs at API prices, context rings, rate-limit forecasts, usage detected elsewhere, heavy-session warnings with *Compact* / *Fresh session* handoffs, save-token tips, workspace grouping, search, idle reminders, quiet during Zoom meetings, four themes, and device totals. Device totals sync through iCloud Drive (shared with your Macs) or OneDrive.

### Works in any IDE or terminal

| | Status, toasts, costs, limits, answers | Open | Reply / Compact / Fresh session |
|---|---|---|---|
| **VS Code, Cursor, VS Code Insiders** | ✅ | ✅ exact chat tab | ✅ typed into the tab for you |
| **Windows Terminal, PowerShell, JetBrains, …** | ✅ | ✅ brings that window forward | ✅ copied to the clipboard, Ctrl+V to paste |

## How it works

```
Claude Code ──hooks──▶ hud-hook.exe event ──▶ ~/.claude/hud/events.jsonl ──▶ ClaudeHUD.exe (WPF)
            ──PermissionRequest──▶ hud-hook.exe perm ──▶ req/<id>.json ◀── answer ── ans/<id>
            ──status line──▶ hud-hook.exe statusline ──▶ limits.json (5-hour / weekly)
transcripts (~/.claude/projects) ──▶ tokens, cost, and errors Anthropic returned
```

`hud-hook.exe` replaces the bash + `jq` hooks of the macOS version, so the hooks run the same from Git Bash, cmd or PowerShell. Hook commands use forward slashes and no spaces, so no shell needs quoting. A hook never blocks Claude Code: on any problem it exits quietly and Claude shows its normal dialog.

## Privacy

Everything stays on your PC. There's no server and no telemetry. For live limits and remote sessions, the HUD reads your existing Claude Code login (`~/.claude/.credentials.json`) and calls the same Anthropic endpoints Claude Code uses; you can turn this off in Settings (the status line hook still provides limits). Device sync writes only daily token and cost totals to your own iCloud Drive or OneDrive.

## Build and test

```powershell
.\build.ps1                         # dist\ClaudeHUD.exe + dist\hud-hook.exe (AnyCPU: x64, ARM64, x86)
.\build.ps1 -Platform x64 -Out dist-x64
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1               # 60 end-to-end checks
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1 -Build dist-x64
```

The tests run against a throwaway fake home (`CLAUDE_HUD_HOME`), so your real `~/.claude`, registry and editor are never touched. They drive the real UI through Windows UI Automation and the mouse. Coverage includes hooks fed garbage, empty input, 1.5 MB inputs and 40 parallel calls, safe `settings.json` edits (including invalid JSON and BOMs), every answer type, questions, killed hooks, ended sessions, account errors with recovery, edge hover, single instance, self-repair, and idle CPU and memory.

The `windows` workflow (`.github/workflows/windows.yml`) builds and runs these tests on `windows-latest` for every pull request, for both the AnyCPU and x86 builds. Each run uploads the built `.exe` files, and a failing run also uploads a screenshot and the HUD's logs.

## Uninstall

**Settings › Apps › Claude HUD › Uninstall**, or:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\ClaudeHUD\uninstall.ps1"
```

It removes the app, its hooks (your own hooks and status line stay), the shortcut, the sign-in entry and its settings.

---

Claude HUD is an independent project and isn't affiliated with or endorsed by Anthropic. "Claude" is a trademark of Anthropic. Costs are shown at API list prices for comparison only; subscription plans aren't billed this way.
