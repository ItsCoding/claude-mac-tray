# Usage Limits & Timing — Design Spec

**Date:** 2026-06-22
**Status:** Approved
**Extends:** `2026-06-20-claude-mac-tray-design.md`

---

## Overview

Add "usage" progress bars to the menu-bar app, in the spirit of [claude-hud](https://github.com/jarrodwatts/claude-hud):

- A **Session (5-hour)** progress bar and a **Weekly (7-day)** progress bar.
- A compact **API time / wall time** readout aggregated across all currently-active sessions.

These render in both the minimal (collapsed) and expanded popover views.

Two operating modes, chosen automatically:

- **Anthropic mode** — when real subscriber rate-limit data is available, bars show the
  true `five_hour` / `seven_day` usage percentage and reset countdown.
- **Bedrock mode** — when rate-limit data is absent (the current Bedrock / API-key setup),
  bars show **USD cost over a rolling 5-hour / 7-day window divided by a user-configured
  USD budget**.

---

## Background: where the data comes from

Investigation of `~/.claude` on this machine established:

- **No rate-limit / reset metadata exists in local transcripts** (`*.jsonl`),
  `sessions/*.json`, or `stats-cache.json`. On Bedrock (`msg_bdrk_*` ids,
  `CLAUDE_CODE_USE_BEDROCK=1`) the CLI never receives Anthropic's rate-limit headers,
  so there is nothing to read.
- **No per-request API duration** is persisted in transcripts. (`durationMs` seen in
  transcripts belongs to hook events, not API calls.)

The real, authoritative source is **Claude Code's statusline stdin payload** — the JSON
Claude Code pipes to a configured `statusLine.command`. Per the official statusline docs
it contains:

| Field | Meaning |
|---|---|
| `cost.total_cost_usd` | Session cost USD (client-side estimate) |
| `cost.total_duration_ms` | Wall-clock time since session start |
| `cost.total_api_duration_ms` | Total time waiting on API responses |
| `rate_limits.five_hour.used_percentage` | 0–100, 5-hour window (Pro/Max only) |
| `rate_limits.five_hour.resets_at` | Unix epoch seconds, window reset |
| `rate_limits.seven_day.used_percentage` | 0–100, 7-day window (Pro/Max only) |
| `rate_limits.seven_day.resets_at` | Unix epoch seconds, window reset |
| `session_id` | Unique session identifier |

`rate_limits` appears **only for Claude.ai Pro/Max subscribers**, after the first API
response in a session; each window may be independently absent. It is never present on
Bedrock / API-key auth. This is exactly the constraint claude-hud documents ("API-key-only
users get no usage display because they lack rate limits"). claude-hud itself does **not**
scrape or call hidden APIs — it reads the stdin payload and an optional local snapshot file.

The menu-bar app runs *outside* Claude Code and cannot receive that stdin directly, so we
capture it with a statusline wrapper (Section 1).

---

## Section 1 — Capture: statusline wrapper

The app installs a small shell script and registers it as Claude Code's statusline command.

- **Script:** `claude-tray-statusline.sh`, bundled in the app and copied to
  `~/Library/Application Support/ClaudeTry/claude-tray-statusline.sh` on install.
- **Behaviour on each invocation:**
  1. Read the full stdin JSON.
  2. Write it verbatim to a per-session snapshot:
     `~/Library/Application Support/ClaudeTry/snapshots/<session_id>.json`
     (atomic write: temp file + rename), stamped with a wall-clock write time.
  3. **Chain** to any previously-configured statusline command, passing the same stdin
     through, and emit its stdout — so the wrapper composes with claude-hud or a user's
     own statusline instead of replacing it. If there was no prior command, print a minimal
     default line so the statusline is never blank.
- **Install** (`StatuslineInstaller`):
  - Read `~/.claude/settings.json`. Record the existing `statusLine` block (if any) into the
    app's own config so chaining and uninstall are possible.
  - Set `statusLine.type = "command"` and `statusLine.command` to the wrapper path.
  - Write `settings.json` back (preserving all other keys; pretty-printed).
- **Uninstall:** restore the recorded previous `statusLine` block (or remove the key if there
  was none) and delete the wrapper script.
- **Idempotent:** re-running install when already installed is a no-op (detected by the
  wrapper path already being the command).

### Snapshot freshness & active sessions

- A snapshot is "active" if its write timestamp is within `activeWindowSeconds` (default 300s).
- Stale snapshots beyond `snapshotRetentionSeconds` (default 24h) are pruned on read.

---

## Section 2 — LimitsModel: modes & computation

A new `LimitsModel` (plain struct/value type, computed by `UsageStore`) produces everything
the UI needs. It consumes (a) the decoded snapshots and (b) the existing message/cost data.

### Mode detection (automatic)

- If the freshest snapshot contains a `rate_limits` block with at least one window present
  → **Anthropic mode**.
- Otherwise → **Bedrock mode**.

Self-correcting: switching accounts changes snapshot contents and flips the mode on the next
poll. No manual setting in v1.

### Bar values

Each bar (`session` = 5h, `weekly` = 7d) resolves to a `BarState`:

```swift
struct BarState {
    let fraction: Double        // 0...1 (clamped), drives bar fill + color
    let primaryLabel: String    // "23%" (Anthropic) or "$12.40 / $50" (Bedrock)
    let detailLabel: String?    // "resets in 2h 14m" (Anthropic) or "5-hour window" (Bedrock)
    let isReal: Bool            // true in Anthropic mode
}
```

- **Anthropic mode:** `fraction = used_percentage / 100`; `primaryLabel = "<pct>%"`;
  `detailLabel` = countdown to `resets_at` ("resets in 2h 14m" / "resets in 3d 4h").
  Use the freshest snapshot that has the window. If only one window is present, the other bar
  falls back to Bedrock computation (and is marked `isReal = false`).
- **Bedrock mode:** compute USD cost over the rolling window using the existing
  `UsageStore.totalCost(in:)` with a `DateInterval` ending now:
  - session bar: `[now − 5h, now]`
  - weekly bar: `[now − 7d, now]`
  `fraction = cost / budget`; `primaryLabel = "$<cost> / $<budget>"`;
  `detailLabel` = the window name. Budgets come from settings (Section 3).

### Timing readout

Across **active** snapshots only:

- `apiMs = Σ cost.total_api_duration_ms`
- `wallMs = Σ cost.total_duration_ms`
- Rendered as `"API 2m 18s · Wall 31m"` using a compact duration formatter.
- If no active snapshots, the readout shows "No active sessions".

### Color thresholds

`fraction < 0.75` accent/indigo, `0.75–0.9` amber, `> 0.9` red. Shared helper so both bars
and any future menu-bar indicator agree.

---

## Section 3 — UI

### Limits section (`Views/LimitsSection.swift`)

Rendered in `DashboardView` in **both** the minimal and expanded layouts, placed directly
under the hero card.

- Two `LimitBar` rows (Session 5h, Weekly 7d): label on the left, a rounded progress bar,
  `primaryLabel` trailing, `detailLabel` as a caption beneath.
- A single timing line beneath the bars: "API … · Wall …".
- Minimal view shows the same two bars + timing line, compactly (smaller vertical padding).
- Empty/disabled state: if the statusline integration is **not installed**, show a slim
  inline prompt ("Connect live usage →") that opens Settings, instead of the bars.

### Settings popover (`Views/SettingsView.swift`)

A gear button is added to the `DashboardView` header (next to the title). It presents a small
settings popover/sheet containing:

- **Budgets** (Bedrock mode): two labelled `TextField`s with steppers — weekly USD budget
  (default `$50`) and session USD budget (default `$10`). Persisted to `UserDefaults`.
- **Statusline integration:** status text (Installed / Not installed) plus an
  **Install** or **Uninstall** button wired to `StatuslineInstaller`. Shows the resolved
  wrapper path and a one-line explanation that it captures live usage and chains to any
  existing statusline.
- Errors (e.g. settings.json unreadable) surface as an inline message; never crash.

Budgets are read through a small `Settings`/`AppConfig` type wrapping `UserDefaults` so views
and `LimitsModel` share one source of truth.

---

## Data Flow

1. Claude Code invokes `claude-tray-statusline.sh` on its normal statusline cadence.
2. The wrapper writes `<session_id>.json` snapshots and chains to the prior statusline.
3. `UsageStore.startPolling()` (existing 30s timer) additionally calls
   `SnapshotStore.reload()`, which decodes all snapshot files and prunes stale ones.
4. `UsageStore` exposes a computed `limits: LimitsModel` built from snapshots + message data.
5. SwiftUI re-renders via `@Observable`; `LimitsSection` reads `store.limits`.
6. Settings changes (budgets) update `UserDefaults`; `LimitsModel` recomputes on next access.

---

## New / changed files

```
ClaudeTry/ClaudeTry/
├── Data/
│   ├── UsageSnapshot.swift        # NEW: Codable payload model + SnapshotStore
│   ├── LimitsModel.swift          # NEW: mode detection, BarState, timing
│   ├── StatuslineInstaller.swift  # NEW: install/uninstall + settings.json editing
│   ├── AppConfig.swift            # NEW: UserDefaults-backed budgets/settings
│   └── UsageStore.swift           # CHANGED: own SnapshotStore, expose `limits`
├── Views/
│   ├── LimitsSection.swift        # NEW: bars + timing view (compact + full)
│   ├── SettingsView.swift         # NEW: budgets + install button
│   └── DashboardView.swift        # CHANGED: gear button + LimitsSection in both layouts
└── Resources/
    └── claude-tray-statusline.sh  # NEW: bundled wrapper script
```

(`AppConfig.swift` added to the file list for clarity; it backs the shared budget settings.)

---

## Error Handling

| Scenario | Handling |
|---|---|
| `rate_limits` absent in snapshot | Fall back to Bedrock (budget) computation for that window |
| Snapshot file malformed JSON | Skip that file, keep others; log once |
| Snapshot dir missing | Treated as "not installed"; show connect prompt |
| `settings.json` unreadable on install | Surface inline error in Settings; do not write |
| Prior statusline command present | Recorded and chained; restored on uninstall |
| No active sessions | Timing readout shows "No active sessions" |
| `resets_at` in the past | Countdown shows "resetting…"; fraction still rendered |
| Budget set to 0 / negative | Treated as unset; bar shows raw cost without a fraction fill |

---

## Testing

- **`UsageSnapshotTests`** — decode fixtures: full payload with `rate_limits`, payload
  without `rate_limits` (Bedrock), malformed file, missing fields, stale vs. active by
  timestamp.
- **`LimitsModelTests`** — mode detection (rate_limits present/absent/partial); Bedrock
  fraction = cost/budget with window math; budget = 0 edge case; timing aggregation across
  multiple active snapshots; reset countdown formatting (future, past, days vs. hours).
- **`StatuslineInstallerTests`** — install writes wrapper path into a temp settings.json,
  records prior command, uninstall restores it; idempotent re-install; chaining preserved.
- **Manual** — install integration, run a Claude Code session, confirm snapshots appear and
  bars/timing update within one poll; verify on Bedrock (budget bars) and, if available, a
  Pro/Max account (real bars).

---

## Out of scope (v1)

- Fetching real plan limits via any network/scraping path (not available locally; rejected).
- Menu-bar icon usage indicator (bars live in the popover only for v1).
- Per-conversation drill-down of timing (aggregate only).
- Manual mode override toggle (detection is automatic; revisit if needed).
