# Contributing

Thanks for helping out! Issues and pull requests are welcome.

## Build and run

You need macOS 14+, the Xcode command-line tools and `jq`. The Mac app lives in `macos/`, the Windows port in `windows/` (see its README).

```sh
cd macos
swift build          # quick compile check
./install.sh         # build, install, wire the hooks, restart the app
```

## Layout

```
macos/Sources/ClaudeHUD/
  main.swift            app startup
  App.swift             panel, hotkey, menu-bar item, settings wiring
  Config.swift          paths, preferences, themes, hotkeys
  Model.swift           sessions, usage, limits, devices
  System.swift          host-app detection, processes, formatting
  TokenCounter.swift    token and cost counting from transcripts
  Store/                state (Store.swift) plus usage, events, permissions and actions
  Views/                drawer, cards, toasts, settings, shared primitives
macos/hooks/            event.sh, perm.sh, statusline.sh: Claude Code hooks that feed the app
macos/scripts/bundle.sh builds macos/dist/ClaudeHUD.app (universal)
macos/scripts/setup-hooks.sh  wires the hooks into ~/.claude/settings.json (or --remove)
windows/                native Windows port (C#), tested by .github/workflows/windows.yml
Casks/claude-hud.rb     Homebrew cask, bumped automatically on release
```

The hook scripts talk to the app through files in `~/.claude/hud/`.

## Releases

Every push to `main` that touches `macos/` or `windows/` runs `.github/workflows/release.yml`. It builds a universal Mac app and the Windows zip, publishes it as release `v1.1.<run>` and updates the cask, so `brew upgrade` picks it up.

## Pull requests

- Keep each PR to one change and explain *why* in the description.
- Keep the app dependency-free: no packages and no new processes left running in the background.
- Watch CPU use. An idle HUD should stay around 1–2% (check in Activity Monitor).
- If you change the UI, attach a screenshot or short clip, and use demo data rather than your real prompts.
- Say which editor or terminal you tested with (Cursor, VS Code, Terminal, iTerm, JetBrains, …).

## Marketing assets

`docs/` is rendered from `marketing/scene.html` with `node marketing/render.mjs stills|video`. This needs Google Chrome and ffmpeg, and nothing else to install.

## Questions and ideas

Use [Discussions](../../discussions) for questions and ideas, and Issues for bugs and concrete feature requests.
