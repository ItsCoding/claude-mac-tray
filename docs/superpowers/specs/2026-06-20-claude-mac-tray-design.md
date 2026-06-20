# Claude Mac Tray — Design Spec

**Date:** 2026-06-20  
**Status:** Approved

---

## Overview

A native macOS menu bar (tray) app written in Swift that provides a rich analytics dashboard for Claude Code usage. The app parses Claude Code's local JSONL session transcripts and presents token usage, costs, conversation history, project breakdowns, model mix, tool call analytics, and memory activity — all in a native SwiftUI popover panel.

**Target platform:** macOS 14+ (Sonoma)  
**Data source:** `~/.claude/projects/**/*.jsonl` (local, no network required)  
**Distribution:** Direct install (no App Sandbox, no Mac App Store)

---

## Architecture

### App Shell

- `NSApplicationDelegate` app with `LSUIElement = YES` (no Dock icon)
- `NSStatusItem` in the menu bar; left-click toggles an `NSPopover`
- The popover contains a SwiftUI root view via `NSHostingController`
- Popover size: fixed width (~560pt), variable height up to screen height

### Data Layer

```
JSONLParser (background actor)
    └── walks ~/.claude/projects/**/
    └── parses *.jsonl files (incremental: skip unchanged files by mtime/size)
    └── produces [Session], [ProjectSummary], [MemoryEvent]

UsageStore (@Observable, @MainActor)
    └── holds [Session], [ProjectSummary], [MemoryEvent]
    └── exposes computed properties for each tab
    └── owns a Timer (30s interval) that triggers JSONLParser re-scan
    └── pricing table: static [modelID: (inputCost, outputCost)]
```

### Key Types

```swift
struct ClaudeMessage {
    let timestamp: Date
    let role: String          // "user" | "assistant"
    let model: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let toolCalls: [ToolCall]
    let projectPath: String   // derived from directory path
}

struct ToolCall {
    let name: String          // "Bash", "Read", "Edit", "Agent", etc.
    let arguments: [String: String]  // string-valued args; path arg used for memory detection
}

struct TokenCount {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
}

struct Session {
    let id: UUID
    let projectPath: String
    let startTime: Date
    let endTime: Date
    let messages: [ClaudeMessage]
    // Computed:
    var totalInputTokens: Int
    var totalOutputTokens: Int
    var totalCost: Double?    // nil if any message has unknown model
    var modelBreakdown: [String: TokenCount]  // keyed by model ID
    var toolCallCounts: [String: Int]
}

struct ProjectSummary {
    let path: String
    let name: String          // last path component
    let sessions: [Session]
    // Computed aggregates across all sessions
}

enum MemoryOperation { case read, write, create }

struct MemoryEvent {
    let timestamp: Date
    let projectPath: String
    let memoryFilePath: String
    let operation: MemoryOperation
}
```

---

## UI Structure

### Menu Bar Icon

- Displays today's accumulated cost (e.g., `$0.42`) or session count as a subtitle badge
- Updates on each poll cycle

### Popover — TabView (5 tabs)

#### 1. Overview
- Segmented control: Today / This Week / This Month / All Time
- Top stats row: Total Tokens, Total Cost, Sessions, Active Projects
- Sparkline chart: daily token usage for the selected period
- Most active project for the period

#### 2. Usage Charts
- Time period picker (same segmented control)
- **Token chart:** daily stacked bar chart by model (Sonnet/Opus/Haiku)
- **Cost chart:** daily line chart, total cost over time
- **Input vs Output:** stacked proportion chart

#### 3. Conversations
- Scrollable list of sessions, newest first
- Each row: project name, date, model badge, token count, cost
- Expandable row: tool call breakdown (name → count), per-model token split
- Filter by project or model via search/picker

#### 4. Projects
- List of projects sorted by total cost descending (toggle: by sessions, by last active)
- Each row: project name, total cost, session count, most-used model, last active date
- Expandable: monthly cost sparkline for that project

#### 5. Memory
- Total memory writes / reads / creates (all time)
- Growth chart: cumulative memory file count over time
- Per-project memory counts table
- Most-accessed memory files (top 10 by read count)
- Most-written memory files (top 10 by write count)

---

## Data Flow

1. On app launch and every 30 seconds, `UsageStore` calls `JSONLParser.scan()`
2. `JSONLParser` walks `~/.claude/projects/` recursively, collecting `.jsonl` file paths
3. For each file, checks mtime against cached value — skips if unchanged
4. Parses changed files line by line into `[ClaudeMessage]`; skips malformed lines with a warning log
5. Groups messages into `Session` objects (one `.jsonl` file = one session; a single file may contain multiple turns but is treated as a single logical session)
6. Builds `[ProjectSummary]` by grouping sessions by project directory
7. Extracts `[MemoryEvent]` from tool calls where the `path` argument string contains `/memory/`; `Read` → `.read`, `Write`/`Edit` → `.write`, first-ever write to a path → `.create`
8. Writes results back to `UsageStore` on `@MainActor`
9. SwiftUI views re-render automatically via `@Observable`

### Pricing Table

Static dictionary in `ModelPricing.swift`, keyed by model ID substring (e.g., `"claude-sonnet-4"`, `"claude-opus-4"`, `"claude-haiku-4-5"`). Each entry has four rates in USD per million tokens: `inputCost`, `outputCost`, `cacheReadCost`, `cacheWriteCost`. Cache read tokens are typically ~10% of input price; cache write tokens are ~125% of input price — these are tracked separately so cost calculations are accurate. Unknown models show cost as `nil` displayed as "—".

---

## Error Handling

| Scenario | Handling |
|---|---|
| Malformed JSONL line | Skip line, log warning, continue parsing |
| Unknown model ID | Cost shown as "—", tokens still counted |
| File disappears mid-scan | Catch error, skip file, keep prior cached data |
| `~/.claude/` missing | Overview shows "No data found" empty state |
| Memory directory absent | Memory tab shows "No memory activity" empty state |
| Large history (slow parse) | Incremental parsing (mtime check) limits re-work per cycle |

---

## Testing

- **`JSONLParserTests`** — fixture `.jsonl` files covering: normal messages, malformed lines, unknown models, cache token fields, empty files, multi-session files
- **`UsageStoreTests`** — daily bucketing, cost rollup, model breakdown, memory event extraction
- **Manual** — run app, verify popover opens/closes, charts render, poll updates work

---

## File Structure (proposed)

```
claude-mac-tray/
├── ClaudeTray/
│   ├── App/
│   │   ├── ClaudeTrayApp.swift        # NSApplicationDelegate + NSStatusItem setup
│   │   └── AppDelegate.swift
│   ├── Data/
│   │   ├── JSONLParser.swift          # background actor, JSONL parsing
│   │   ├── UsageStore.swift           # @Observable store + Timer
│   │   ├── ModelPricing.swift         # static pricing table
│   │   └── Models.swift               # ClaudeMessage, Session, etc.
│   ├── Views/
│   │   ├── PopoverRootView.swift      # TabView root
│   │   ├── OverviewTab.swift
│   │   ├── UsageChartsTab.swift
│   │   ├── ConversationsTab.swift
│   │   ├── ProjectsTab.swift
│   │   └── MemoryTab.swift
│   └── Resources/
│       └── Assets.xcassets
├── ClaudeTrayTests/
│   ├── JSONLParserTests.swift
│   ├── UsageStoreTests.swift
│   └── Fixtures/
│       └── *.jsonl
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-06-20-claude-mac-tray-design.md
```
