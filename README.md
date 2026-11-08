# CTF HUD

A lightweight, native macOS overlay for keeping track of CTF competition schedules and team standings.

CTF HUD lives in the menu bar and displays the information you need during a competition without requiring a browser tab to stay open. It is built with Swift, AppKit and SwiftUI.

## Features

- **Competition timeline:** Set a start time, any number of stages, and an end time.
- **Countdowns:** Show the next stage and competition end time. Optionally hide the next-stage countdown during the final stage.
- **Reminders:** Play sounds at 2 hours, 1 hour, 30 minutes, 15 minutes, 5 minutes and 1 minute before configured milestones.
- **Team standings:** Display overall rank, division rank, score, changes between updates and the last successful refresh time when the data source supports them.
- **Customizable overlay:** Move or lock the window, enable click-through, choose a compact layout and adjust background and text opacity independently. Individual HUD elements can be hidden.
- **Multiple data protocols:** Support for `HKCTF2026`, `CTFd` and `CustomJSON`, with configurable endpoints.
- **Languages:** English, Simplified Chinese, Traditional Chinese and Japanese, with an option to follow the macOS language.

The countdowns work offline. Standings and submission information appear only when the selected data source provides them.

## Requirements

- macOS 13 or later on Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`)

This repository currently provides source code and a local build script, rather than a notarized macOS release.

## Build and install


By homebrew:
```sh
brew install --cask chujiamo/tap/ctfhud
```

Clone or download the repository, then run:

```sh
zsh build_app.sh
```

The script offers a build profile selection in an interactive terminal. You can also choose a profile explicitly:

```sh
# Portable Apple Silicon build
zsh build_app.sh --profile standard

# Optimized for the M3 family (including M3 Max)
zsh build_app.sh --profile m3
```

Available profiles are `auto`, `standard`, `m1`, `m2`, `m3`, `m4` and `m5`.

CPU-specific profiles depend on the installed Swift/LLVM toolchain; newer targets may not be supported by older Xcode versions. They are build-time tuning options, not a guarantee of higher performance.

By default, the script installs the app to `/Applications/CTFHUD.app` **without launching it**. Open the app manually from Applications after installation.

To build without installing:

```sh
zsh build_app.sh --profile standard --build-only
```

To attempt all six build targets for distribution:

```sh
zsh build_app.sh --all --build-only
```

The outputs are kept under `build/<profile>/CTFHUD.app`. Unsupported profiles may fail independently.

## Getting started

1. Launch **CTF HUD** from Applications and open **Control Center** from the menu bar.
2. Create or edit a competition timeline with its start, stage and end times.
3. Configure which countdowns and information panels should be visible.
4. If you want live standings, select a data protocol, enter the endpoint and your team identifier, then refresh the feed.
5. Position the overlay and optionally enable click-through so it does not intercept mouse input.

Your competition settings are saved locally and retained between app launches.

## Scoreboard protocols

| Protocol | Data source | Notes |
| --- | --- | --- |
| `HKCTF2026` | HKCERT CTF 2026 leaderboard | Uses the event's `teams[]` format, including `team_id`, `rank` and `score`. |
| `CTFd` | Standard CTFd scoreboard API | Set the endpoint for your CTFd instance, typically `/api/v1/scoreboard`. |
| `CustomJSON` | User-defined JSON feed | Supports `teams[]`, `data[]` or `standings[]`, with optional submission data. |
| `off` | No scoreboard | Countdown-only mode. |

For HKCERT CTF 2026, the default public endpoint is:

```text
https://platform.ctf.hkcert.org/api/v1/leaderboard
```

**Important:** CTF HUD reads scores from the feed instead of adding together submission points. This matters for competitions with dynamic scoring, where a team's total can decrease as more teams solve a challenge. Score and rank changes are calculated from successive successful fetches.

Division rankings may be estimates when a feed does not supply an official division rank or complete grouping information. Likewise, `last_solve_at` is not a full submission history. The HUD will not invent missing submissions or standings.

The client is intended for public JSON feeds; it does not implement login sessions or authenticated private scoreboards. Remote endpoints must use HTTPS (except local loopback during development).

## Appearance and localization

The HUD supports a minimal mode, per-element visibility controls, separate background and text opacity settings, window-position persistence, click-through and a temporary position-adjustment mode.

Interface language can be changed in Control Center without restarting. Translation resources are stored in `locales/`; additional translations and corrections are welcome.

## Privacy

CTF HUD does not require an account. Team identifiers, competition timelines and interface preferences are stored locally, not bundled with the published source code.

Local competition settings are stored at:

```text
~/Library/Application Support/CTFHUD/config.json
```

Do not commit personal configuration files, API credentials or private competition data to a public repository. The included `.gitignore` and `release_check.sh` provide basic safeguards, but you should still review files before publishing.

## Development

The project is primarily organized into:

- `main.swift` — macOS menu-bar app, overlay and settings UI
- `Core.swift` — competition models, countdowns, feed parsing and score comparisons
- `Localization.swift` and `locales/` — translations and language selection
- `build_app.sh` — build profiles and local installation
- `Tests/` — core and window-lifecycle regression checks

Run the available checks with:

```sh
swiftc Core.swift Localization.swift Tests/CoreTests.swift -o /tmp/ctfhud-tests
/tmp/ctfhud-tests
python3 Tests/WindowLifecycleTests.py
zsh release_check.sh
```

Contributions, bug reports and additional scoreboard protocol adapters are welcome. When reporting a bug, include your macOS version, selected build profile, the steps to reproduce it and relevant logs **with private information removed**.

## License

A license has not been selected yet. Add a `LICENSE` file before publishing the project for reuse or accepting external contributions.

## Disclaimer

CTF HUD is an independent utility and is not affiliated with HKCERT, CTFd or any competition organizer. Availability and accuracy of live standings depend on the upstream event platform.
