# ClaudeTry

A macOS menu bar app that shows live Claude Code usage analytics — costs, tokens, and project breakdowns — right from your status bar.

![macOS](https://img.shields.io/badge/macOS-13%2B-black) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-blue)

## Features

- **Overview tab** — total cost, tokens in/out, and session count at a glance
- **Charts tab** — daily usage trends over time
- **Projects tab** — cost and token breakdown per Claude Code project
- **Live pricing** — costs calculated from LiteLLM's pricing data, so new models price correctly automatically
- **Animated menu bar icon** — pulses when Claude is actively working
- **Runs at login** — installs as a LaunchAgent so it's always there

## How it works

ClaudeTry reads the JSONL session files Claude Code writes to `~/.claude/projects/` and aggregates them locally. No data leaves your machine.

## Install

**Requirements:** macOS 13+, Xcode 15+ (for building)

```bash
git clone https://github.com/ItsCoding/claude-mac-tray
cd claude-mac-tray
make
```

`make` builds the app, copies it to `/Applications`, and registers a LaunchAgent so it starts at login.

### Other commands

```bash
make build      # build only (outputs to ./build)
make install    # build + copy to /Applications
make autostart  # register launch-at-login LaunchAgent
make restart    # relaunch the installed app
make uninstall  # remove app + LaunchAgent
make clean      # delete build artifacts
```

## Usage

Click the Claude icon in your menu bar to open the popover. Switch tabs to explore costs by day, model, or project.

## License

MIT
