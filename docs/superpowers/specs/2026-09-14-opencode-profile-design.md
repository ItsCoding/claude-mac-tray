# OpenCode as a Third Usage Profile — Design Spec

**Date:** 2026-09-14
**Status:** Approved

---

## Overview

ClaudeTry currently reads Claude Code's local JSONL transcripts (`~/.claude/projects/**/*.jsonl`) and tags each session with a `ClaudeProfile` (`Claude.ai` or `Bedrock`, detected from the message id prefix). This spec extends that same profile concept with a third source: **OpenCode** (github.com/sst/opencode), a separate coding CLI that stores its own session history locally in a SQLite database.

The goal is for ClaudeTry to show *combined* spend/token usage across both tools — Overview totals, the menu-bar badge, Projects, Conversations, Tools, Lines, and Memory tabs all include OpenCode sessions, and the existing "Profile" breakdown chart/row shows a third `OpenCode` bucket alongside `Claude.ai` / `Bedrock`.

## Data Source

OpenCode stores everything in a SQLite database, not JSONL:

- **Path:** `~/.local/share/opencode/opencode.db` (hardcoded default, matching how the existing Claude path `~/.claude/projects` is hardcoded — no env-var override).
- **`message` table:** one row per message, `data` column is a JSON blob:
  ```json
  {
    "role": "assistant",
    "cost": 0.7451031,
    "tokens": {"input": 24, "output": 2497, "reasoning": 0, "cache": {"read": 0, "write": 0}},
    "modelID": "claude-sonnet-5",
    "providerID": "anthropic",
    "path": {"cwd": "/Users/.../project", "root": "..."},
    "time": {"created": 1789372509107}
  }
  ```
  `cost` is already computed by OpenCode in USD — trust it verbatim, do not recompute via `ModelPricing` (OpenCode covers many providers/models — Azure, proxy aliases, etc. — that ClaudeTry's Claude-only pricing catalog has no data for).
- **`part` table:** one row per content block, `data` column is a JSON blob, joined to `message` via `message_id`. Tool calls look like:
  ```json
  {"type": "tool", "tool": "edit", "state": {"input": {"filePath": "...", "oldString": "...", "newString": "..."}, "metadata": {"diff": {"additions": 3, "deletions": 1}}}}
  ```
- User-role messages carry no `cost`/`tokens`/`modelID` and never carry tool-call parts — only assistant rows matter for extraction, matching how Claude Code's parser already effectively contributes nothing from user messages.
- Confirmed empirically: `import SQLite3` compiles and links in this project with **zero** Xcode project changes (system module auto-links `libsqlite3` via its module map). No new dependency, no `.pbxproj` edit.
- Missing DB file (OpenCode never installed/used) → parser returns empty results, same as today's "`~/.claude/` missing" empty state — no crash, no error surfaced.
- No incremental/disk caching for this parser (unlike `JSONLParser`'s mtime-based cache): the DB is small (183 sessions / ~3.7K messages / ~16K parts as observed) and indexed on `session_id`/`message_id`, so a full re-query every 30s poll is cheap. Mark with a `ponytail:` comment noting caching can be added later if this ever measurably slows down.

## Model Changes

- **`ClaudeMessage`** (`Data/Models.swift`): add two fields with defaults so existing construction sites are unaffected:
  ```swift
  let isOpenCode: Bool = false
  let precomputedCostUSD: Double? = nil
  ```
- **`JSONLParser`**: bump the disk-cache filename from `sessions_v3.json` to `sessions_v4.json` so any previously-cached JSON (missing the two new fields) is safely rebuilt rather than risking a decode mismatch.
- **`ClaudeProfile`** (`Data/Models.swift`): add `case opencode = "OpenCode"`.
- **`Session.profile`** (`Data/Models.swift`): check `isOpenCode` before `isBedrock`:
  ```swift
  var profile: ClaudeProfile {
      if messages.contains(where: { $0.isOpenCode }) { return .opencode }
      return messages.contains { $0.isBedrock } ? .bedrock : .anthropic
  }
  ```
- **`ChartStyle.ModelStyle`** (`Views/Shared/ChartStyle.swift`): add `"OpenCode"` to the `order` array and a matching case in `color(_:)` — use `.cyan` (indigo/teal/orange/green/pink/gray are already taken by Opus/Sonnet/Haiku/Bedrock/Fable/Synthetic).
- **`DashboardView.profileRow`** (`Views/DashboardView.swift`): replace the hardcoded `item.profile == .anthropic ? Color.indigo : Color.orange` ternary with `ModelStyle.color(item.profile.rawValue)`, since there are now 3 profiles, not 2, and the color should come from one shared source of truth.

## Cost Resolution — Single Choke Point

All cost computation currently flows through `ModelPricing`, which recomputes USD from `(model, TokenCount)` via a Claude-only LiteLLM-derived pricing catalog. OpenCode messages must instead use their own precomputed cost. Fixing this once, at the shared function, avoids patching every caller:

- New helper in `ModelPricing.swift`:
  ```swift
  static func cost(for message: ClaudeMessage) -> Double? {
      if message.isOpenCode { return message.precomputedCostUSD ?? 0 }
      let tc = TokenCount(input: message.inputTokens, output: message.outputTokens,
                          cacheRead: message.cacheReadTokens, cacheWrite: message.cacheWriteTokens)
      return cost(for: message.model ?? "", tokens: tc)
  }
  ```
- `ModelPricing.cost(for session:)` is rewritten to sum via that per-message helper instead of delegating to `PricingCatalog.cost(forSession:)` (which becomes dead code and is deleted). This single change correctly fixes five downstream callers at once: `UsageStore.profileBreakdown`, `cumulativeCost(for:)`, `cumulativeCost(in:)`, `busiestHour`, `projectBuckets`.
- Four remaining call sites in `UsageStore.swift` that currently build a `TokenCount` inline and call `ModelPricing.cost(for: model, tokens:)` directly on a message are swapped to `ModelPricing.cost(for: msg)`:
  - `totalCost(in:)`
  - `_modelBuckets` (the `cost[bucket]` accumulation)
  - `profileBuckets` (the `cost[bucket]` accumulation)
  - `last24hHourlyCost()`
- `cacheSavings(in:)` adds a guard to skip `isOpenCode` messages — there's no reliable per-token unit price to estimate "what cache-read tokens would have cost at full rate" for arbitrary OpenCode providers. This insight card stays Claude-Code-only; documented here as a deliberate, known limitation (not silently wrong).

## OpenCodeParser

New file `Data/OpenCodeParser.swift`, structured like `JSONLParser` (an `actor`, same `scan()` → `(sessions: [Session], memoryEvents: [MemoryEvent])` return shape) but backed by SQLite instead of file walking:

1. Open `~/.local/share/opencode/opencode.db` read-only via `sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)`. Missing/unreadable file → return `([], [])`.
2. `SELECT id, session_id, time_created, data FROM message ORDER BY session_id, time_created` — one query, all messages.
3. `SELECT message_id, data FROM part ORDER BY message_id` — one query, all parts. Group by `message_id` in Swift.
4. For each **assistant**-role message row:
   - Decode `data` JSON. Skip rows that fail to parse (defensive, matching Claude Code's malformed-line handling).
   - `timestamp` = `time.created` (ms epoch → `Date`).
   - `model` = `modelID`.
   - `inputTokens` = `tokens.input`, `outputTokens` = `tokens.output + tokens.reasoning` (reasoning tokens fold into output — there's no separate reasoning bucket elsewhere in the app and reasoning is billed like output), `cacheReadTokens` = `tokens.cache.read`, `cacheWriteTokens` = `tokens.cache.write`.
   - `precomputedCostUSD` = `cost`; `isOpenCode` = `true`; `isBedrock` = `false`.
   - `projectPath` = `path.cwd` (fallback to the session's directory if absent — mirrors Claude's `resolvedCwd ?? fallbackPath` pattern).
   - Tool calls: for every attached `part` with `type == "tool"`, build `ToolCall(name: tool, arguments: state.input as [String: String])`. Tool names keep OpenCode's native casing (`edit`, `write`, `bash`, ...) — **no aliasing to Claude Code's PascalCase names** (`Edit`, `Write`, `Bash`); they'll appear as separate bars in the Tools chart. This is a deliberate scope line, not an oversight — model names get aliased (next section), tool names don't.
   - Lines added/removed:
     - `tool == "edit"`: prefer `state.metadata.diff.additions` / `.deletions` (OpenCode already computes an exact diff — more accurate than Claude Code's own newline-counting heuristic). Fall back to counting `\n` in `oldString`/`newString` if diff metadata is absent.
     - `tool == "write"`: count `\n` in `content` as `linesAdded` (no removals for a fresh write) — mirrors Claude Code's `("Write", "content")` handling.
   - Memory events: for any tool call whose `input.filePath` contains `/memory/`, emit a `MemoryEvent` with the same Read → `.read`, first-write → `.create`, subsequent-write → `.write` classification Claude Code sessions already get (tool-name check adjusted for OpenCode's lowercase `"read"`).
5. Group the resulting `[ClaudeMessage]` by `session_id` into `Session` structs: `startTime`/`endTime` from `messages.first`/`.last` timestamps (skip sessions with zero assistant messages, mirroring `JSONLParser`'s `guard !parsed.messages.isEmpty`), `id = UUID()` (not required to be stable across polls — the whole `sessions` array is rebuilt from scratch every scan already).

## Model-Name Aliasing (Cost/Tokens-by-model charts)

No new mapping table needed. `shortModelName()` (`Data/Models.swift`) already does substring matching (`model.contains("sonnet")`, `.contains("opus")`, `.contains("haiku")`, `.contains("fable")`). OpenCode's Anthropic-provider model IDs (`"claude-sonnet-5"`, `"claude-opus-5"`) already collapse into the same `"Sonnet"` / `"Opus"` bars used by native Claude Code usage, so the two tools' spend on the *same underlying model* shows as one combined bar. Non-Claude models (`"gpt-5.6-luna"`, `"gpt-5-nano"`, ...) have no Claude alias and show under their own raw model-id string — there's no equivalent to map them to, this is expected, not a gap.

## UsageStore Wiring

`UsageStore.refreshAsync()` (`Data/UsageStore.swift`) runs both parsers and concatenates results before sorting:

```swift
private func refreshAsync() async {
    let claudeRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    let openCodeDB = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/opencode.db")
    async let claude = parser.scan(rootURL: claudeRoot)
    async let opencode = openCodeParser.scan(dbPath: openCodeDB)
    let (c, o) = await (claude, opencode)
    sessions = (c.sessions + o.sessions).sorted { $0.startTime > $1.startTime }
    // memoryEvents likewise concatenated
    snapshots.reload()
    isLoaded = true
}
```

## Explicitly Out of Scope

- **Tool-name aliasing** between OpenCode's lowercase tool names and Claude Code's PascalCase names — they show as distinct bars in the Tools chart.
- **Cache-savings estimate** for OpenCode sessions — no reliable per-token unit price to estimate against; that insight card stays Claude-Code-only.
- **Sub-agent/parent-session collapsing** for OpenCode's `session.parent_id` — child sessions are counted as their own `Session` rows; they roll up into the right project automatically since they share the same `directory`/`path.cwd`, no special-casing needed.
- **XDG env-var override** for the OpenCode DB path — hardcoded default only, matching the existing Claude path's simplicity.

## Testing

- **`OpenCodeParserTests`** (new) — fixture SQLite DB (or an in-memory DB built with `CREATE TABLE`/`INSERT` in the test) covering: normal assistant message with cost/tokens, user message (excluded), missing DB file (empty result), edit tool with diff metadata, edit tool without diff metadata (fallback line counting), write tool, memory-path detection, malformed JSON row (skipped).
- **`ModelPricingTests`** — extend to cover `cost(for message:)` honoring `precomputedCostUSD` when `isOpenCode`, and `cost(for session:)` summing correctly for a mixed Claude Code + OpenCode session set.
- **`UsageStoreTests`** — extend `profileBreakdown`/`profileBuckets` tests to cover a 3-profile scenario (Claude.ai + Bedrock + OpenCode present simultaneously).
- **Manual** — with the real `~/.local/share/opencode/opencode.db` present, verify Overview total cost increases to include OpenCode spend, Profile row shows 3 entries with distinct colors, Projects tab shows combined per-directory totals, Tools tab shows OpenCode's lowercase tool names as separate bars from Claude Code's PascalCase ones.
