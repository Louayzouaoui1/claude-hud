# Contributing

Thanks for helping out! Issues and pull requests are welcome.

## Build and run

You need macOS 14+, the Xcode command-line tools and `jq`.

```sh
swiftc -swift-version 5 -O main.swift -o /tmp/ClaudeHUD   # quick compile check
./install.sh                                              # build, install, wire the hooks, restart the app
```

The whole app is `main.swift`. The three hook scripts (`event.sh`, `perm.sh`, `statusline.sh`) feed it through files in `~/.claude/hud/`.

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
