# OpenCode as a Third Usage Profile — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ClaudeTry reads OpenCode's local SQLite session store alongside Claude Code's JSONL transcripts, so Overview totals, the menu-bar badge, Projects, Conversations, Tools, Lines, Memory, and the Profile breakdown all include combined Claude Code + OpenCode usage.

**Architecture:** A new `OpenCodeParser` actor reads `~/.local/share/opencode/opencode.db` (SQLite, read-only, via `import SQLite3` — no new dependency) and produces the same `[Session]`/`[MemoryEvent]` shapes `JSONLParser` produces for Claude Code. `ClaudeMessage` gains two fields (`isOpenCode`, `precomputedCostUSD`) so the existing `ClaudeProfile`/`ModelPricing` machinery can tag and cost OpenCode messages correctly. `UsageStore` runs both parsers and concatenates results — every other tab/chart is unchanged.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, SQLite3 (system C module, zero-dependency).

**Spec:** `docs/superpowers/specs/2026-09-14-opencode-profile-design.md`

## Global Constraints

- OpenCode DB path is hardcoded: `~/.local/share/opencode/opencode.db` (no XDG override, matches the existing hardcoded `~/.claude/projects` path).
- Missing DB file → parser returns `([], [])`, never crashes.
- `OpenCodeParser` does a full re-query every `scan()` call — no incremental/disk cache (unlike `JSONLParser`).
- Tool names from OpenCode keep their native casing (`edit`, `bash`) — **not** aliased to Claude Code's PascalCase (`Edit`, `Bash`).
- Model names are NOT explicitly aliased with new code — `shortModelName()`'s existing substring matching already collapses OpenCode's Claude-family model ids into the same buckets.
- `ClaudeMessage`'s two new fields (`isOpenCode: Bool`, `precomputedCostUSD: Double?`) have **no default values** — every construction site must pass them explicitly. (Verified empirically: Swift's synthesized `Decodable` silently ignores JSON values for `let` properties that declare a default, always resetting them to the compile-time default on decode — a real footgun for a `Codable` struct like `ClaudeMessage` that round-trips through `JSONLParser`'s disk cache. Explicit, no-default fields avoid this entirely and match the existing `isBedrock` field's style.)
- This project uses Xcode 16 file-system-synchronized groups (`PBXFileSystemSynchronizedRootGroup`) for both `ClaudeTry/ClaudeTry` and `ClaudeTry/ClaudeTryTests` — new `.swift` files dropped into those folders are automatically part of the target. **No `.pbxproj` edits are needed anywhere in this plan.**
- Run all commands from the repo root: `/Users/alexander.quadt/git/claude-mac-tray`.
- Standard test/build command (reuse this exact invocation throughout, only changing `-only-testing:`):
  ```bash
  xcodebuild -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -configuration Debug \
    -derivedDataPath build -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    test -only-testing:ClaudeTryTests/<ClassName>
  ```

---

### Task 1: Fix the pre-existing broken test build

The test target currently fails to *compile* at HEAD — unrelated to this feature, but it blocks running any tests (including this plan's TDD cycles), so it must be fixed first. `ClaudeMessage` has `linesAdded`/`linesRemoved` fields (added in a prior commit) that two test files never picked up.

**Files:**
- Modify: `ClaudeTry/ClaudeTryTests/ModelTests.swift`
- Modify: `ClaudeTry/ClaudeTryTests/UsageStoreTests.swift`

**Interfaces:**
- Consumes: `ClaudeMessage`'s current (pre-this-plan) memberwise init — `init(timestamp:role:model:inputTokens:outputTokens:cacheReadTokens:cacheWriteTokens:toolCalls:projectPath:isBedrock:linesAdded:linesRemoved:)`.
- Produces: a compiling `ClaudeTryTests` target — every later task in this plan depends on this.

- [ ] **Step 1: Confirm the current failure**

Run:
```bash
cd /Users/alexander.quadt/git/claude-mac-tray
xcodebuild -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  build-for-testing 2>&1 | grep "error:"
```
Expected output (4 errors, all "missing arguments for parameters 'linesAdded', 'linesRemoved' in call"):
```
.../ModelTests.swift:7:26: error: missing arguments for parameters 'linesAdded', 'linesRemoved' in call
.../ModelTests.swift:10:26: error: missing arguments for parameters 'linesAdded', 'linesRemoved' in call
.../ModelTests.swift:23:26: error: missing arguments for parameters 'linesAdded', 'linesRemoved' in call
.../ModelTests.swift:26:26: error: missing arguments for parameters 'linesAdded', 'linesRemoved' in call
```
(`UsageStoreTests.swift` has the same bug in its own `msg()` helper — fix it too even if it doesn't show in this particular error batch.)

- [ ] **Step 2: Fix `ModelTests.swift`**

In `ClaudeTry/ClaudeTryTests/ModelTests.swift`, all four `ClaudeMessage(...)` calls are missing `linesAdded`/`linesRemoved`. Replace the file's two test functions with:

```swift
import XCTest
@testable import ClaudeTry

final class ModelTests: XCTestCase {
    func test_session_totalInputTokens_sumsAllMessages() {
        let messages = [
            ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-sonnet-4-6",
                          inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0,
                          toolCalls: [], projectPath: "/test/project", isBedrock: false,
                          linesAdded: 0, linesRemoved: 0),
            ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-sonnet-4-6",
                          inputTokens: 200, outputTokens: 80, cacheReadTokens: 10, cacheWriteTokens: 5,
                          toolCalls: [], projectPath: "/test/project", isBedrock: false,
                          linesAdded: 0, linesRemoved: 0)
        ]
        let session = Session(id: UUID(), projectPath: "/test/project",
                              startTime: messages[0].timestamp, endTime: messages[1].timestamp,
                              messages: messages)
        XCTAssertEqual(session.totalInputTokens, 300)
        XCTAssertEqual(session.totalOutputTokens, 130)
    }

    func test_session_modelBreakdown_groupsByModel() {
        let messages = [
            ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-sonnet-4-6",
                          inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0,
                          toolCalls: [], projectPath: "/test", isBedrock: false,
                          linesAdded: 0, linesRemoved: 0),
            ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-opus-4-8",
                          inputTokens: 200, outputTokens: 80, cacheReadTokens: 0, cacheWriteTokens: 0,
                          toolCalls: [], projectPath: "/test", isBedrock: false,
                          linesAdded: 0, linesRemoved: 0)
        ]
        let session = Session(id: UUID(), projectPath: "/test",
                              startTime: messages[0].timestamp, endTime: messages[1].timestamp,
                              messages: messages)
        XCTAssertEqual(session.modelBreakdown["claude-sonnet-4-6"]?.input, 100)
        XCTAssertEqual(session.modelBreakdown["claude-opus-4-8"]?.input, 200)
    }
}
```

- [ ] **Step 3: Fix `UsageStoreTests.swift`**

In `ClaudeTry/ClaudeTryTests/UsageStoreTests.swift`, the `msg()` helper inside `makeSessions()` is missing the same two arguments. Change:

```swift
        func msg(_ tokens: Int, _ model: String, _ date: Date, _ toolName: String? = nil) -> ClaudeMessage {
            let tc = toolName.map { [ToolCall(name: $0, arguments: [:])] } ?? []
            return ClaudeMessage(timestamp: date, role: "assistant", model: model,
                                  inputTokens: tokens, outputTokens: 0,
                                  cacheReadTokens: 0, cacheWriteTokens: 0,
                                  toolCalls: tc, projectPath: "/p", isBedrock: false)
        }
```

to:

```swift
        func msg(_ tokens: Int, _ model: String, _ date: Date, _ toolName: String? = nil) -> ClaudeMessage {
            let tc = toolName.map { [ToolCall(name: $0, arguments: [:])] } ?? []
            return ClaudeMessage(timestamp: date, role: "assistant", model: model,
                                  inputTokens: tokens, outputTokens: 0,
                                  cacheReadTokens: 0, cacheWriteTokens: 0,
                                  toolCalls: tc, projectPath: "/p", isBedrock: false,
                                  linesAdded: 0, linesRemoved: 0)
        }
```

- [ ] **Step 4: Verify the build succeeds and existing tests pass**

Run:
```bash
xcodebuild -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  test 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **` with no failures.

- [ ] **Step 5: Commit**

```bash
git add ClaudeTry/ClaudeTryTests/ModelTests.swift ClaudeTry/ClaudeTryTests/UsageStoreTests.swift
git commit -m "fix: add missing linesAdded/linesRemoved args in test ClaudeMessage constructors"
```

---

### Task 2: `ClaudeMessage`/`ClaudeProfile`/`Session.profile` model changes

**Files:**
- Modify: `ClaudeTry/ClaudeTry/Data/Models.swift`
- Modify: `ClaudeTry/ClaudeTry/Data/JSONLParser.swift`
- Modify: `ClaudeTry/ClaudeTryTests/ModelTests.swift`
- Modify: `ClaudeTry/ClaudeTryTests/UsageStoreTests.swift`
- Test: `ClaudeTry/ClaudeTryTests/ModelTests.swift` (new test)

**Interfaces:**
- Consumes: nothing new.
- Produces: `ClaudeMessage.isOpenCode: Bool`, `ClaudeMessage.precomputedCostUSD: Double?`, `ClaudeProfile.opencode`, `Session.profile` recognizing `.opencode`. Task 3 (`ModelPricing`) and Tasks 5/6 (`OpenCodeParser`) both construct `ClaudeMessage` using these two new parameters.

- [ ] **Step 1: Write the failing test**

Add to `ClaudeTry/ClaudeTryTests/ModelTests.swift` (inside the `ModelTests` class, after `test_session_modelBreakdown_groupsByModel`):

```swift
    func test_session_profile_opencodeMessage_returnsOpenCodeProfile() {
        let message = ClaudeMessage(timestamp: Date(), role: "assistant", model: "gpt-5.6-luna",
                                     inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0,
                                     toolCalls: [], projectPath: "/test", isBedrock: false,
                                     linesAdded: 0, linesRemoved: 0,
                                     isOpenCode: true, precomputedCostUSD: 1.23)
        let session = Session(id: UUID(), projectPath: "/test",
                              startTime: message.timestamp, endTime: message.timestamp,
                              messages: [message])
        XCTAssertEqual(session.profile, .opencode)
    }

    func test_session_profile_bedrockMessage_stillReturnsBedrock_whenNotOpenCode() {
        let message = ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-sonnet-4-6",
                                     inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0,
                                     toolCalls: [], projectPath: "/test", isBedrock: true,
                                     linesAdded: 0, linesRemoved: 0,
                                     isOpenCode: false, precomputedCostUSD: nil)
        let session = Session(id: UUID(), projectPath: "/test",
                              startTime: message.timestamp, endTime: message.timestamp,
                              messages: [message])
        XCTAssertEqual(session.profile, .bedrock)
    }
```

Also add `isOpenCode: false, precomputedCostUSD: nil` to the four pre-existing `ClaudeMessage(...)` calls in this same file (they will fail to compile otherwise once Step 2 removes the default-free init ambiguity — there is no default, so every call site must be updated). The two existing test methods become:

```swift
    func test_session_totalInputTokens_sumsAllMessages() {
        let messages = [
            ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-sonnet-4-6",
                          inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0,
                          toolCalls: [], projectPath: "/test/project", isBedrock: false,
                          linesAdded: 0, linesRemoved: 0, isOpenCode: false, precomputedCostUSD: nil),
            ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-sonnet-4-6",
                          inputTokens: 200, outputTokens: 80, cacheReadTokens: 10, cacheWriteTokens: 5,
                          toolCalls: [], projectPath: "/test/project", isBedrock: false,
                          linesAdded: 0, linesRemoved: 0, isOpenCode: false, precomputedCostUSD: nil)
        ]
        let session = Session(id: UUID(), projectPath: "/test/project",
                              startTime: messages[0].timestamp, endTime: messages[1].timestamp,
                              messages: messages)
        XCTAssertEqual(session.totalInputTokens, 300)
        XCTAssertEqual(session.totalOutputTokens, 130)
    }

    func test_session_modelBreakdown_groupsByModel() {
        let messages = [
            ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-sonnet-4-6",
                          inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0,
                          toolCalls: [], projectPath: "/test", isBedrock: false,
                          linesAdded: 0, linesRemoved: 0, isOpenCode: false, precomputedCostUSD: nil),
            ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-opus-4-8",
                          inputTokens: 200, outputTokens: 80, cacheReadTokens: 0, cacheWriteTokens: 0,
                          toolCalls: [], projectPath: "/test", isBedrock: false,
                          linesAdded: 0, linesRemoved: 0, isOpenCode: false, precomputedCostUSD: nil)
        ]
        let session = Session(id: UUID(), projectPath: "/test",
                              startTime: messages[0].timestamp, endTime: messages[1].timestamp,
                              messages: messages)
        XCTAssertEqual(session.modelBreakdown["claude-sonnet-4-6"]?.input, 100)
        XCTAssertEqual(session.modelBreakdown["claude-opus-4-8"]?.input, 200)
    }
```

And in `ClaudeTry/ClaudeTryTests/UsageStoreTests.swift`, update the `msg()` helper again:

```swift
        func msg(_ tokens: Int, _ model: String, _ date: Date, _ toolName: String? = nil) -> ClaudeMessage {
            let tc = toolName.map { [ToolCall(name: $0, arguments: [:])] } ?? []
            return ClaudeMessage(timestamp: date, role: "assistant", model: model,
                                  inputTokens: tokens, outputTokens: 0,
                                  cacheReadTokens: 0, cacheWriteTokens: 0,
                                  toolCalls: tc, projectPath: "/p", isBedrock: false,
                                  linesAdded: 0, linesRemoved: 0,
                                  isOpenCode: false, precomputedCostUSD: nil)
        }
```

- [ ] **Step 2: Run the test to verify it fails to compile**

```bash
xcodebuild -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  test -only-testing:ClaudeTryTests/ModelTests 2>&1 | grep "error:"
```
Expected: compile errors — `isOpenCode`/`precomputedCostUSD` are extra arguments `ClaudeMessage`'s current init doesn't accept, and `ClaudeProfile` has no `.opencode` case yet.

- [ ] **Step 3: Implement the model changes**

In `ClaudeTry/ClaudeTry/Data/Models.swift`, change the `ClaudeProfile` enum:

```swift
enum ClaudeProfile: String, CaseIterable {
    case anthropic = "Claude.ai"
    case bedrock   = "Bedrock"
    case opencode  = "OpenCode"
}
```

Change the `ClaudeMessage` struct to add the two new fields (append them at the end so `JSONLParser.swift`'s existing labeled-argument call in Task 2 Step 3b just needs two more trailing lines, not a reorder):

```swift
struct ClaudeMessage: Codable {
    let timestamp: Date
    let role: String
    let model: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let toolCalls: [ToolCall]
    let projectPath: String
    /// Bedrock message IDs start with "msg_bdrk_"; nil means unknown (treated as Claude.ai).
    let isBedrock: Bool
    let linesAdded: Int
    let linesRemoved: Int
    /// True for messages sourced from OpenCode's SQLite store rather than
    /// Claude Code's JSONL transcripts. Drives `Session.profile` and tells
    /// `ModelPricing` to trust `precomputedCostUSD` instead of recomputing
    /// from `model` (OpenCode covers providers/models Claude's pricing
    /// catalog has no data for). No default value — see plan's Global
    /// Constraints on why Codable defaults are a footgun here.
    let isOpenCode: Bool
    /// USD cost OpenCode itself computed for this message. Only meaningful
    /// when `isOpenCode` is true; nil for Claude Code messages.
    let precomputedCostUSD: Double?
}
```

Change `Session.profile`:

```swift
    var profile: ClaudeProfile {
        if messages.contains(where: { $0.isOpenCode }) { return .opencode }
        return messages.contains { $0.isBedrock } ? .bedrock : .anthropic
    }
```

In `ClaudeTry/ClaudeTry/Data/JSONLParser.swift`, the `ClaudeMessage(...)` construction (in `parseFile`, currently ending with `linesAdded: msgLinesAdded, linesRemoved: msgLinesRemoved`) gains two trailing arguments:

```swift
            messages.append(ClaudeMessage(
                timestamp: timestamp,
                role: role,
                model: model,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                toolCalls: toolCalls,
                projectPath: resolvedCwd ?? fallbackPath,
                isBedrock: isBedrock,
                linesAdded: msgLinesAdded,
                linesRemoved: msgLinesRemoved,
                isOpenCode: false,
                precomputedCostUSD: nil
            ))
```

Also bump the disk cache filename so old cached JSON (missing the two new keys) is safely rebuilt rather than relying on the whole-dictionary decode failure path:

```swift
        return dir.appendingPathComponent("sessions_v4.json")
```
(was `sessions_v3.json`).

- [ ] **Step 4: Run the test to verify it passes**

```bash
xcodebuild -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  test -only-testing:ClaudeTryTests/ModelTests -only-testing:ClaudeTryTests/UsageStoreTests -only-testing:ClaudeTryTests/JSONLParserTests 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ClaudeTry/ClaudeTry/Data/Models.swift ClaudeTry/ClaudeTry/Data/JSONLParser.swift \
        ClaudeTry/ClaudeTryTests/ModelTests.swift ClaudeTry/ClaudeTryTests/UsageStoreTests.swift
git commit -m "feat: add OpenCode profile tagging to ClaudeMessage/ClaudeProfile/Session"
```

---

### Task 3: Cost resolution — single choke point for OpenCode's precomputed cost

**Files:**
- Modify: `ClaudeTry/ClaudeTry/Data/ModelPricing.swift`
- Modify: `ClaudeTry/ClaudeTry/Data/Pricing.swift`
- Modify: `ClaudeTry/ClaudeTry/Data/UsageStore.swift`
- Test: `ClaudeTry/ClaudeTryTests/ModelPricingTests.swift`

**Interfaces:**
- Consumes: `ClaudeMessage.isOpenCode`/`.precomputedCostUSD` (Task 2).
- Produces: `ModelPricing.cost(for message: ClaudeMessage) -> Double?`. Tasks 5/6 (`OpenCodeParser`) don't call this directly, but every `UsageStore` query that later includes OpenCode sessions (Task 7) relies on this being correct.

- [ ] **Step 1: Write the failing tests**

Add to `ClaudeTry/ClaudeTryTests/ModelPricingTests.swift` (inside the `ModelPricingTests` class):

```swift
    func test_cost_openCodeMessage_usesPrecomputedCost_ignoresModelCatalog() {
        let msg = ClaudeMessage(timestamp: Date(), role: "assistant", model: "gpt-5.6-luna",
                                 inputTokens: 1_000_000, outputTokens: 1_000_000,
                                 cacheReadTokens: 0, cacheWriteTokens: 0,
                                 toolCalls: [], projectPath: "/p", isBedrock: false,
                                 linesAdded: 0, linesRemoved: 0,
                                 isOpenCode: true, precomputedCostUSD: 4.2)
        // "gpt-5.6-luna" has no entry in the Claude-only pricing catalog, so a
        // catalog-based lookup would return nil/0 — the precomputed value must win.
        XCTAssertEqual(ModelPricing.cost(for: msg), 4.2)
    }

    func test_cost_openCodeMessage_missingPrecomputedCost_defaultsToZero() {
        let msg = ClaudeMessage(timestamp: Date(), role: "assistant", model: "gpt-5.6-luna",
                                 inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0,
                                 toolCalls: [], projectPath: "/p", isBedrock: false,
                                 linesAdded: 0, linesRemoved: 0,
                                 isOpenCode: true, precomputedCostUSD: nil)
        XCTAssertEqual(ModelPricing.cost(for: msg), 0)
    }

    func test_cost_claudeCodeMessage_usesModelCatalog_ignoresPrecomputedCost() {
        let tokens = TokenCount(input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0)
        let msg = ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-sonnet-4-6",
                                 inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
                                 toolCalls: [], projectPath: "/p", isBedrock: false,
                                 linesAdded: 0, linesRemoved: 0,
                                 isOpenCode: false, precomputedCostUSD: 999) // must be ignored
        XCTAssertEqual(ModelPricing.cost(for: msg)!, ModelPricing.cost(for: "claude-sonnet-4-6", tokens: tokens)!, accuracy: 0.001)
        XCTAssertEqual(ModelPricing.cost(for: msg)!, 3.0, accuracy: 0.001)
    }

    func test_cost_session_sumsAcrossClaudeAndOpenCodeMessages() {
        let now = Date()
        let claudeMsg = ClaudeMessage(timestamp: now, role: "assistant", model: "claude-sonnet-4-6",
                                       inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
                                       toolCalls: [], projectPath: "/p", isBedrock: false,
                                       linesAdded: 0, linesRemoved: 0,
                                       isOpenCode: false, precomputedCostUSD: nil) // costs $3.0
        let openCodeMsg = ClaudeMessage(timestamp: now, role: "assistant", model: "gpt-5.6-luna",
                                         inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
                                         toolCalls: [], projectPath: "/p", isBedrock: false,
                                         linesAdded: 0, linesRemoved: 0,
                                         isOpenCode: true, precomputedCostUSD: 2.5)
        let session = Session(id: UUID(), projectPath: "/p", startTime: now, endTime: now,
                              messages: [claudeMsg, openCodeMsg])
        XCTAssertEqual(ModelPricing.cost(for: session)!, 5.5, accuracy: 0.001)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  test -only-testing:ClaudeTryTests/ModelPricingTests 2>&1 | grep "error:\|does not have a member"
```
Expected: compile error — `ModelPricing.cost(for message:)` doesn't exist yet.

- [ ] **Step 3: Implement the cost resolution helper**

In `ClaudeTry/ClaudeTry/Data/ModelPricing.swift`, add the new helper and rewrite `cost(for session:)` to sum through it:

```swift
import Foundation

/// Thin facade over the live `PricingCatalog`. Seeded synchronously from the
/// disk cache / embedded snapshot, then upgraded once the remote LiteLLM table
/// is fetched. All access happens on the main actor (views + UsageStore).
@MainActor
enum ModelPricing {
    /// Current pricing data. Replaced wholesale when the remote fetch succeeds.
    static var catalog: PricingCatalog = PricingLoader.loadCachedOrEmbedded()

    /// Pull the latest LiteLLM table and swap it in. No-op on network failure.
    static func refreshFromRemote() async {
        if let remote = await PricingLoader.fetchRemote() {
            catalog = remote
        }
    }

    /// USD cost for a model + token bundle. `nil` only for genuinely unknown models.
    static func cost(for modelID: String, tokens: TokenCount) -> Double? {
        catalog.cost(forModel: modelID, tokens: tokens)
    }

    /// USD cost for a single message. OpenCode messages carry their own
    /// precomputed cost (OpenCode covers providers/models this Claude-only
    /// catalog has no pricing data for) and always win over a catalog lookup.
    static func cost(for message: ClaudeMessage) -> Double? {
        if message.isOpenCode { return message.precomputedCostUSD ?? 0 }
        let tokens = TokenCount(input: message.inputTokens, output: message.outputTokens,
                                cacheRead: message.cacheReadTokens, cacheWrite: message.cacheWriteTokens)
        return cost(for: message.model ?? "", tokens: tokens)
    }

    /// USD cost for a whole session — sums per-message cost so mixed
    /// Claude Code + OpenCode sessions total correctly.
    static func cost(for session: Session) -> Double? {
        session.messages.reduce(0.0) { $0 + (cost(for: $1) ?? 0) }
    }
}
```

In `ClaudeTry/ClaudeTry/Data/Pricing.swift`, delete the now-dead `cost(forSession:)` method from `PricingCatalog` (nothing calls it anymore):

```swift
struct PricingCatalog {
    let entries: [String: PricingEntry]

    /// Cost in USD for a single model + token bundle.
    /// Returns 0 for Claude Code's `<synthetic>` messages (they are free),
    /// and `nil` for genuinely unknown models so callers can show "—".
    func cost(forModel modelID: String, tokens: TokenCount) -> Double? {
        if modelID == "<synthetic>" || modelID.isEmpty { return 0 }
        guard let e = entry(for: modelID) else { return nil }
        return Double(tokens.input)      * e.inputPerToken
             + Double(tokens.output)     * e.outputPerToken
             + Double(tokens.cacheRead)  * e.cacheReadPerToken
             + Double(tokens.cacheWrite) * e.cacheCreationPerToken
    }

    private func entry(for modelID: String) -> PricingEntry? {
        if let exact = entries[modelID] { return exact }
        // LiteLLM sometimes prefixes provider, e.g. "anthropic/claude-...".
        if let slash = modelID.split(separator: "/").last.map(String.init),
           let e = entries[slash] { return e }
        // Fall back to the longest catalog key contained in the model id.
        return entries
            .filter { modelID.contains($0.key) }
            .max(by: { $0.key.count < $1.key.count })?
            .value
    }
}
```

Now fix the four direct per-message cost call sites in `ClaudeTry/ClaudeTry/Data/UsageStore.swift` that currently build a `TokenCount` inline and call `ModelPricing.cost(for: model, tokens:)` on a specific message — swap each to `ModelPricing.cost(for: msg)` (or whatever the message variable is named at that site):

In `totalCost(in:)`, change:
```swift
    func totalCost(in interval: DateInterval) -> Double? {
        messages(in: interval).reduce(0.0) { acc, m in
            let tc = TokenCount(input: m.inputTokens, output: m.outputTokens,
                                cacheRead: m.cacheReadTokens, cacheWrite: m.cacheWriteTokens)
            return acc + (ModelPricing.cost(for: m.model ?? "", tokens: tc) ?? 0)
        }
    }
```
to:
```swift
    func totalCost(in interval: DateInterval) -> Double? {
        messages(in: interval).reduce(0.0) { acc, m in
            acc + (ModelPricing.cost(for: m) ?? 0)
        }
    }
```

In `_modelBuckets`, change:
```swift
                var byCost = cost[bucket] ?? [:]
                byCost[short, default: 0] += ModelPricing.cost(for: raw, tokens: tc) ?? 0
                cost[bucket] = byCost
```
to:
```swift
                var byCost = cost[bucket] ?? [:]
                byCost[short, default: 0] += ModelPricing.cost(for: msg) ?? 0
                cost[bucket] = byCost
```

In `profileBuckets`, change:
```swift
                var byCost = cost[bucket] ?? [:]
                byCost[name, default: 0] += ModelPricing.cost(for: msg.model ?? "", tokens: tc) ?? 0
                cost[bucket] = byCost
```
to:
```swift
                var byCost = cost[bucket] ?? [:]
                byCost[name, default: 0] += ModelPricing.cost(for: msg) ?? 0
                cost[bucket] = byCost
```

In `last24hHourlyCost()`, change:
```swift
        for msg in messages(in: interval) {
            let bucket = cal.dateInterval(of: .hour, for: msg.timestamp)?.start ?? msg.timestamp
            let tc = TokenCount(input: msg.inputTokens, output: msg.outputTokens,
                                cacheRead: msg.cacheReadTokens, cacheWrite: msg.cacheWriteTokens)
            byHour[bucket, default: 0] += ModelPricing.cost(for: msg.model ?? "", tokens: tc) ?? 0
        }
```
to:
```swift
        for msg in messages(in: interval) {
            let bucket = cal.dateInterval(of: .hour, for: msg.timestamp)?.start ?? msg.timestamp
            byHour[bucket, default: 0] += ModelPricing.cost(for: msg) ?? 0
        }
```

Finally, guard `cacheSavings(in:)` to skip OpenCode messages — there's no reliable per-token unit price to estimate "what cache-read tokens would have cost at full rate" for arbitrary OpenCode providers:
```swift
    func cacheSavings(in interval: DateInterval) -> Double {
        var saved = 0.0
        for session in filteredSessions(in: interval) {
            for msg in session.messages where msg.cacheReadTokens > 0 && !msg.isOpenCode {
                guard let model = msg.model else { continue }
                let full = ModelPricing.cost(for: model, tokens: TokenCount(input: msg.cacheReadTokens, output: 0, cacheRead: 0, cacheWrite: 0)) ?? 0
                let actual = ModelPricing.cost(for: model, tokens: TokenCount(input: 0, output: 0, cacheRead: msg.cacheReadTokens, cacheWrite: 0)) ?? 0
                saved += full - actual
            }
        }
        return saved
    }
```
(only the `for` line's `where` clause changes — added `&& !msg.isOpenCode`.)

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  test -only-testing:ClaudeTryTests/ModelPricingTests -only-testing:ClaudeTryTests/UsageStoreTests 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ClaudeTry/ClaudeTry/Data/ModelPricing.swift ClaudeTry/ClaudeTry/Data/Pricing.swift \
        ClaudeTry/ClaudeTry/Data/UsageStore.swift ClaudeTry/ClaudeTryTests/ModelPricingTests.swift
git commit -m "refactor: centralize per-message cost resolution to honor OpenCode's precomputed cost"
```

---

### Task 4: Give the "OpenCode" profile its own chart color

With `ClaudeProfile.opencode` added (Task 2), the Profile breakdown row can now show 3 entries simultaneously. `ChartStyle.ModelStyle` doesn't know about `"OpenCode"` yet (falls through to gray, same as "unknown"), and `DashboardView.profileRow` hardcodes a two-way color ternary that would render both `.bedrock` and `.opencode` as the same color.

**Files:**
- Modify: `ClaudeTry/ClaudeTry/Views/Shared/ChartStyle.swift`
- Modify: `ClaudeTry/ClaudeTry/Views/DashboardView.swift`
- Create: `ClaudeTry/ClaudeTryTests/ChartStyleTests.swift`

**Interfaces:**
- Consumes: `ClaudeProfile.opencode.rawValue == "OpenCode"` (Task 2).
- Produces: nothing new consumed by later tasks — this is UI polish, independently reviewable.

- [ ] **Step 1: Write the failing test**

Create `ClaudeTry/ClaudeTryTests/ChartStyleTests.swift`:

```swift
import XCTest
@testable import ClaudeTry

final class ChartStyleTests: XCTestCase {
    func test_order_includesOpenCode() {
        XCTAssertTrue(ModelStyle.order.contains("OpenCode"))
    }

    func test_color_openCodeAndBedrock_areDistinct() {
        XCTAssertNotEqual(ModelStyle.color("OpenCode"), ModelStyle.color("Bedrock"))
        XCTAssertNotEqual(ModelStyle.color("OpenCode"), ModelStyle.color("Claude.ai"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  test -only-testing:ClaudeTryTests/ChartStyleTests 2>&1 | tail -20
```
Expected: `test_order_includesOpenCode` fails (not yet in `order`); `test_color_openCodeAndBedrock_areDistinct` fails too (both currently fall through to `.gray`).

- [ ] **Step 3: Implement**

In `ClaudeTry/ClaudeTry/Views/Shared/ChartStyle.swift`, update `ModelStyle`:

```swift
enum ModelStyle {
    /// Stable legend/stack order (most expensive → cheapest, then synthetic, then profiles).
    static let order = ["Opus", "Sonnet", "Haiku", "Fable", "Synthetic", "Claude.ai", "Bedrock", "OpenCode", "Added", "Removed"]

    static func color(_ model: String) -> Color {
        switch model {
        case "Opus":      return .indigo
        case "Sonnet":    return .teal
        case "Haiku":     return .orange
        case "Fable":     return .pink
        case "Synthetic": return .gray
        case "Claude.ai": return .indigo
        case "Bedrock":   return .green
        case "OpenCode":  return .cyan
        case "Added":     return .green
        case "Removed":   return .red
        default:          return .gray
        }
    }
    // ... rest of the file (palette, scale(for:)) is unchanged.
```

In `ClaudeTry/ClaudeTry/Views/DashboardView.swift`, `profileRow` currently hardcodes a two-way ternary. Change:
```swift
                    Circle()
                        .fill(item.profile == .anthropic ? Color.indigo : Color.orange)
                        .frame(width: 6, height: 6)
```
to:
```swift
                    Circle()
                        .fill(ModelStyle.color(item.profile.rawValue))
                        .frame(width: 6, height: 6)
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
xcodebuild -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  test -only-testing:ClaudeTryTests/ChartStyleTests 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ClaudeTry/ClaudeTry/Views/Shared/ChartStyle.swift ClaudeTry/ClaudeTry/Views/DashboardView.swift \
        ClaudeTry/ClaudeTryTests/ChartStyleTests.swift
git commit -m "feat: give the OpenCode profile its own chart color"
```

---

### Task 5: `OpenCodeParser` core — SQLite reading, message extraction, session grouping

Builds the actor that reads OpenCode's `message` table and turns assistant-role rows into `Session`s with correct cost/tokens/model/timestamp/project — no tool calls, lines, or memory events yet (that's Task 6). This alone is a working, testable deliverable: it's enough for the Profile breakdown, Overview totals, and Projects tab to include OpenCode spend.

**Files:**
- Create: `ClaudeTry/ClaudeTry/Data/OpenCodeParser.swift`
- Create: `ClaudeTry/ClaudeTryTests/OpenCodeParserTests.swift`

**Interfaces:**
- Consumes: `ClaudeMessage`/`Session`/`MemoryEvent` (existing), `isOpenCode`/`precomputedCostUSD` (Task 2).
- Produces: `actor OpenCodeParser { func scan(dbPath: URL) async -> (sessions: [Session], memoryEvents: [MemoryEvent]) }`. Task 6 extends this same file/method. Task 7 (`UsageStore`) calls `scan(dbPath:)`.

- [ ] **Step 1: Write the failing tests**

Create `ClaudeTry/ClaudeTryTests/OpenCodeParserTests.swift`:

```swift
import XCTest
import SQLite3
@testable import ClaudeTry

final class OpenCodeParserTests: XCTestCase {
    var parser: OpenCodeParser!
    var dbURL: URL!

    override func setUp() {
        super.setUp()
        parser = OpenCodeParser()
        dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("ocp-\(UUID().uuidString).db")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dbURL)
        super.tearDown()
    }

    /// Creates a throwaway SQLite DB with the same `message`/`part` schema
    /// OpenCodeParser reads, and inserts the given rows. Test data is fully
    /// controlled (no untrusted input), so plain string-interpolated SQL is
    /// fine here — no need for prepared/bound statements in a test fixture.
    private func makeDB(messages: [(id: String, sessionID: String, data: String)],
                         parts: [(messageID: String, data: String)] = []) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
            CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, data TEXT);
            """, nil, nil, nil), SQLITE_OK)
        for (i, m) in messages.enumerated() {
            let escaped = m.data.replacingOccurrences(of: "'", with: "''")
            let sql = "INSERT INTO message (id, session_id, time_created, data) VALUES ('\(m.id)', '\(m.sessionID)', \(i), '\(escaped)');"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
        for (i, p) in parts.enumerated() {
            let escaped = p.data.replacingOccurrences(of: "'", with: "''")
            let sql = "INSERT INTO part (id, message_id, data) VALUES ('prt_\(i)', '\(p.messageID)', '\(escaped)');"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
    }

    func test_scan_assistantMessage_extractsCostTokensModel() async {
        makeDB(messages: [(
            id: "msg_1", sessionID: "ses_1",
            data: #"{"role":"assistant","cost":0.75,"tokens":{"input":100,"output":200,"reasoning":10,"cache":{"read":5,"write":2}},"modelID":"claude-sonnet-5","providerID":"anthropic","path":{"cwd":"/Users/x/proj"},"time":{"created":1700000000000}}"#
        )])
        let result = await parser.scan(dbPath: dbURL)
        XCTAssertEqual(result.sessions.count, 1)
        let session = result.sessions[0]
        XCTAssertEqual(session.messages.count, 1)
        let msg = session.messages[0]
        XCTAssertEqual(msg.inputTokens, 100)
        XCTAssertEqual(msg.outputTokens, 210, "reasoning tokens fold into output")
        XCTAssertEqual(msg.cacheReadTokens, 5)
        XCTAssertEqual(msg.cacheWriteTokens, 2)
        XCTAssertEqual(msg.model, "claude-sonnet-5")
        XCTAssertEqual(msg.projectPath, "/Users/x/proj")
        XCTAssertTrue(msg.isOpenCode)
        XCTAssertEqual(msg.precomputedCostUSD, 0.75)
    }

    func test_scan_userMessage_excluded() async {
        makeDB(messages: [(id: "msg_1", sessionID: "ses_1", data: #"{"role":"user"}"#)])
        let result = await parser.scan(dbPath: dbURL)
        XCTAssertTrue(result.sessions.isEmpty)
    }

    func test_scan_missingDB_returnsEmpty() async {
        // dbURL was never created by makeDB — the file doesn't exist.
        let result = await parser.scan(dbPath: dbURL)
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertTrue(result.memoryEvents.isEmpty)
    }

    func test_scan_malformedJSON_skipsRowWithoutCrashing() async {
        makeDB(messages: [(id: "msg_1", sessionID: "ses_1", data: "{not valid json")])
        let result = await parser.scan(dbPath: dbURL)
        XCTAssertTrue(result.sessions.isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  test -only-testing:ClaudeTryTests/OpenCodeParserTests 2>&1 | grep "error:\|cannot find"
```
Expected: `error: cannot find type 'OpenCodeParser' in scope`.

- [ ] **Step 3: Implement `OpenCodeParser` (core, no tool calls yet)**

Create `ClaudeTry/ClaudeTry/Data/OpenCodeParser.swift`:

```swift
import Foundation
import SQLite3

/// Reads OpenCode's local SQLite session store and produces the same
/// `[Session]`/`[MemoryEvent]` shapes `JSONLParser` produces for Claude Code,
/// so every existing `UsageStore` query/chart picks up OpenCode usage with no
/// further changes. Re-queries the whole DB on every `scan()` call — no
/// incremental cache like `JSONLParser`'s mtime cache — because the `message`/
/// `part` tables are small (thousands of rows) and indexed by session/message
/// id, so a full read is cheap.
/// ponytail: if this ever measurably slows the 30s poll down (very large
/// OpenCode history), add an mtime/rowid-based incremental cache like
/// JSONLParser's.
actor OpenCodeParser {
    private struct RawMessage {
        let id: String
        let sessionID: String
        let timestamp: Date
        let model: String?
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheWriteTokens: Int
        let cost: Double
        let projectPath: String
    }

    func scan(dbPath: URL) async -> (sessions: [Session], memoryEvents: [MemoryEvent]) {
        guard FileManager.default.fileExists(atPath: dbPath.path) else { return ([], []) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return ([], [])
        }
        defer { sqlite3_close(db) }

        let rawMessages = readMessages(db)

        var messagesBySession: [String: [ClaudeMessage]] = [:]
        for raw in rawMessages {
            let message = ClaudeMessage(
                timestamp: raw.timestamp, role: "assistant", model: raw.model,
                inputTokens: raw.inputTokens, outputTokens: raw.outputTokens,
                cacheReadTokens: raw.cacheReadTokens, cacheWriteTokens: raw.cacheWriteTokens,
                toolCalls: [], projectPath: raw.projectPath,
                isBedrock: false, linesAdded: 0, linesRemoved: 0,
                isOpenCode: true, precomputedCostUSD: raw.cost
            )
            messagesBySession[raw.sessionID, default: []].append(message)
        }

        let sessions: [Session] = messagesBySession.values.compactMap { msgs in
            guard let start = msgs.map(\.timestamp).min(), let end = msgs.map(\.timestamp).max() else { return nil }
            return Session(id: UUID(), projectPath: msgs[0].projectPath, startTime: start, endTime: end, messages: msgs)
        }

        return (sessions, [])
    }

    private func readMessages(_ db: OpaquePointer) -> [RawMessage] {
        let sql = "SELECT id, session_id, time_created, data FROM message ORDER BY session_id, time_created"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        var result: [RawMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0), let sidC = sqlite3_column_text(stmt, 1),
                  let dataC = sqlite3_column_text(stmt, 3) else { continue }
            let fallbackCreated = sqlite3_column_int64(stmt, 2)
            guard let json = decodeJSON(String(cString: dataC)),
                  json["role"] as? String == "assistant" else { continue }

            let tokens = json["tokens"] as? [String: Any]
            let cache = tokens?["cache"] as? [String: Any]
            let reasoning = tokens?["reasoning"] as? Int ?? 0
            let createdMs = (json["time"] as? [String: Any])?["created"] as? Double ?? Double(fallbackCreated)
            let cwd = (json["path"] as? [String: Any])?["cwd"] as? String

            result.append(RawMessage(
                id: String(cString: idC), sessionID: String(cString: sidC),
                timestamp: Date(timeIntervalSince1970: createdMs / 1000),
                model: json["modelID"] as? String,
                inputTokens: tokens?["input"] as? Int ?? 0,
                outputTokens: (tokens?["output"] as? Int ?? 0) + reasoning,
                cacheReadTokens: cache?["read"] as? Int ?? 0,
                cacheWriteTokens: cache?["write"] as? Int ?? 0,
                cost: json["cost"] as? Double ?? 0,
                projectPath: cwd ?? "unknown"
            ))
        }
        return result
    }

    private func decodeJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  test -only-testing:ClaudeTryTests/OpenCodeParserTests 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ClaudeTry/ClaudeTry/Data/OpenCodeParser.swift ClaudeTry/ClaudeTryTests/OpenCodeParserTests.swift
git commit -m "feat: add OpenCodeParser core (SQLite message extraction, no tool calls yet)"
```

---

### Task 6: `OpenCodeParser` — tool calls, lines added/removed, memory events

Extends Task 5's `scan()` to also read the `part` table, populating `ToolCall`s, `linesAdded`/`linesRemoved`, and `MemoryEvent`s — giving OpenCode sessions full parity with Claude Code sessions in the Tools/Lines/Memory tabs.

**Files:**
- Modify: `ClaudeTry/ClaudeTry/Data/OpenCodeParser.swift`
- Modify: `ClaudeTry/ClaudeTryTests/OpenCodeParserTests.swift`

**Interfaces:**
- Consumes: `OpenCodeParser.scan(dbPath:)` (Task 5) — same signature, richer output.
- Produces: same `scan(dbPath:)` signature; Task 7 (`UsageStore`) is unaffected by this task's internal changes.

- [ ] **Step 1: Write the failing tests**

Append to `ClaudeTry/ClaudeTryTests/OpenCodeParserTests.swift` (inside the `OpenCodeParserTests` class, after `test_scan_malformedJSON_skipsRowWithoutCrashing`):

```swift
    private let baseAssistantData = #"{"role":"assistant","cost":0.1,"tokens":{"input":10,"output":10,"reasoning":0,"cache":{"read":0,"write":0}},"modelID":"claude-sonnet-5","path":{"cwd":"/p"},"time":{"created":1700000000000}}"#

    func test_scan_editWithDiffMetadata_usesExactLineCounts() async {
        makeDB(
            messages: [(id: "msg_1", sessionID: "ses_1", data: baseAssistantData)],
            parts: [(messageID: "msg_1", data: #"{"type":"tool","tool":"edit","state":{"input":{"filePath":"/a.txt","oldString":"x","newString":"y"},"metadata":{"diff":{"additions":3,"deletions":1}}}}"#)]
        )
        let result = await parser.scan(dbPath: dbURL)
        let session = result.sessions[0]
        XCTAssertEqual(session.linesAdded, 3, "must use diff metadata, not oldString/newString line counts (1 each)")
        XCTAssertEqual(session.linesRemoved, 1)
    }

    func test_scan_editWithoutDiffMetadata_fallsBackToCountingStrings() async {
        makeDB(
            messages: [(id: "msg_1", sessionID: "ses_1", data: baseAssistantData)],
            parts: [(messageID: "msg_1", data: #"{"type":"tool","tool":"edit","state":{"input":{"filePath":"/a.txt","oldString":"line1\nline2","newString":"line1\nline2\nline3"}}}"#)]
        )
        let result = await parser.scan(dbPath: dbURL)
        let session = result.sessions[0]
        XCTAssertEqual(session.linesRemoved, 2)
        XCTAssertEqual(session.linesAdded, 3)
    }

    func test_scan_writeTool_countsContentLinesAsAdded() async {
        makeDB(
            messages: [(id: "msg_1", sessionID: "ses_1", data: baseAssistantData)],
            parts: [(messageID: "msg_1", data: #"{"type":"tool","tool":"write","state":{"input":{"filePath":"/new.txt","content":"a\nb\nc"}}}"#)]
        )
        let result = await parser.scan(dbPath: dbURL)
        let session = result.sessions[0]
        XCTAssertEqual(session.linesAdded, 3)
        XCTAssertEqual(session.linesRemoved, 0)
    }

    func test_scan_toolCall_isRecordedWithNativeToolName() async {
        makeDB(
            messages: [(id: "msg_1", sessionID: "ses_1", data: baseAssistantData)],
            parts: [(messageID: "msg_1", data: #"{"type":"tool","tool":"bash","state":{"input":{"command":"ls"}}}"#)]
        )
        let result = await parser.scan(dbPath: dbURL)
        XCTAssertEqual(result.sessions[0].toolCallCounts["bash"], 1, "OpenCode's native lowercase tool name, not aliased to Claude Code's casing")
    }

    func test_scan_memoryPathInFilePath_extractsReadEvent() async {
        makeDB(
            messages: [(id: "msg_1", sessionID: "ses_1", data: baseAssistantData)],
            parts: [(messageID: "msg_1", data: #"{"type":"tool","tool":"read","state":{"input":{"filePath":"/p/memory/notes.md"}}}"#)]
        )
        let result = await parser.scan(dbPath: dbURL)
        XCTAssertEqual(result.memoryEvents.count, 1)
        XCTAssertEqual(result.memoryEvents[0].operation, .read)
        XCTAssertTrue(result.memoryEvents[0].memoryFilePath.contains("notes.md"))
    }

    func test_scan_memoryPathFirstWriteThenSecondWrite_createThenWrite() async {
        makeDB(
            messages: [
                (id: "msg_1", sessionID: "ses_1", data: baseAssistantData),
                (id: "msg_2", sessionID: "ses_1", data: baseAssistantData),
            ],
            parts: [
                (messageID: "msg_1", data: #"{"type":"tool","tool":"write","state":{"input":{"filePath":"/p/memory/notes.md","content":"v1"}}}"#),
                (messageID: "msg_2", data: #"{"type":"tool","tool":"write","state":{"input":{"filePath":"/p/memory/notes.md","content":"v2"}}}"#),
            ]
        )
        let result = await parser.scan(dbPath: dbURL)
        XCTAssertEqual(result.memoryEvents.count, 2)
        XCTAssertEqual(result.memoryEvents[0].operation, .create)
        XCTAssertEqual(result.memoryEvents[1].operation, .write)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  test -only-testing:ClaudeTryTests/OpenCodeParserTests 2>&1 | tail -40
```
Expected: the new tests fail (all `toolCallCounts`/`linesAdded`/`linesRemoved`/`memoryEvents` are 0/empty since `scan()` doesn't read `part` rows yet). The four Task 5 tests still pass.

- [ ] **Step 3: Implement tool call / lines / memory extraction**

Replace the full contents of `ClaudeTry/ClaudeTry/Data/OpenCodeParser.swift` with:

```swift
import Foundation
import SQLite3

/// Reads OpenCode's local SQLite session store and produces the same
/// `[Session]`/`[MemoryEvent]` shapes `JSONLParser` produces for Claude Code,
/// so every existing `UsageStore` query/chart picks up OpenCode usage with no
/// further changes. Re-queries the whole DB on every `scan()` call — no
/// incremental cache like `JSONLParser`'s mtime cache — because the `message`/
/// `part` tables are small (thousands of rows) and indexed by session/message
/// id, so a full read is cheap.
/// ponytail: if this ever measurably slows the 30s poll down (very large
/// OpenCode history), add an mtime/rowid-based incremental cache like
/// JSONLParser's.
actor OpenCodeParser {
    private struct RawMessage {
        let id: String
        let sessionID: String
        let timestamp: Date
        let model: String?
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheWriteTokens: Int
        let cost: Double
        let projectPath: String
    }

    /// One `part` row of type "tool". `args` mirrors the shape `JSONLParser`
    /// builds for Claude Code tool calls — every string-valued input field,
    /// keyed by OpenCode's own field names (e.g. "filePath", not "file_path").
    private struct RawPart {
        let tool: String
        var args: [String: String]
        let diffAdditions: Int?
        let diffDeletions: Int?
    }

    func scan(dbPath: URL) async -> (sessions: [Session], memoryEvents: [MemoryEvent]) {
        guard FileManager.default.fileExists(atPath: dbPath.path) else { return ([], []) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return ([], [])
        }
        defer { sqlite3_close(db) }

        let rawMessages = readMessages(db)
        let partsByMessage = readParts(db)

        var messagesBySession: [String: [ClaudeMessage]] = [:]
        var memoryEvents: [MemoryEvent] = []
        var seenMemoryPaths = Set<String>()

        for raw in rawMessages {
            var toolCalls: [ToolCall] = []
            var linesAdded = 0
            var linesRemoved = 0

            for part in partsByMessage[raw.id] ?? [] {
                var args = part.args

                // Strip large text fields out of `args` after using them for
                // line counting — mirrors JSONLParser's handling of Claude
                // Code's Edit/Write tool calls, avoids stuffing whole file
                // diffs into every ToolCall.arguments dict.
                switch part.tool {
                case "edit":
                    if let add = part.diffAdditions, let del = part.diffDeletions {
                        linesAdded += add
                        linesRemoved += del
                    } else {
                        if let old = args["oldString"] { linesRemoved += old.components(separatedBy: "\n").count }
                        if let new = args["newString"] { linesAdded += new.components(separatedBy: "\n").count }
                    }
                    args["oldString"] = nil
                    args["newString"] = nil
                case "write":
                    if let content = args["content"] { linesAdded += content.components(separatedBy: "\n").count }
                    args["content"] = nil
                default:
                    break
                }
                toolCalls.append(ToolCall(name: part.tool, arguments: args))

                if let path = part.args["filePath"], path.contains("/memory/") {
                    let isRead = part.tool == "read"
                    let isFirstSeen = !seenMemoryPaths.contains(path)
                    if !isRead { seenMemoryPaths.insert(path) }
                    let op: MemoryOperation = isRead ? .read : (isFirstSeen ? .create : .write)
                    memoryEvents.append(MemoryEvent(id: UUID(), timestamp: raw.timestamp,
                                                     projectPath: raw.projectPath, memoryFilePath: path, operation: op))
                }
            }

            let message = ClaudeMessage(
                timestamp: raw.timestamp, role: "assistant", model: raw.model,
                inputTokens: raw.inputTokens, outputTokens: raw.outputTokens,
                cacheReadTokens: raw.cacheReadTokens, cacheWriteTokens: raw.cacheWriteTokens,
                toolCalls: toolCalls, projectPath: raw.projectPath,
                isBedrock: false, linesAdded: linesAdded, linesRemoved: linesRemoved,
                isOpenCode: true, precomputedCostUSD: raw.cost
            )
            messagesBySession[raw.sessionID, default: []].append(message)
        }

        let sessions: [Session] = messagesBySession.values.compactMap { msgs in
            guard let start = msgs.map(\.timestamp).min(), let end = msgs.map(\.timestamp).max() else { return nil }
            return Session(id: UUID(), projectPath: msgs[0].projectPath, startTime: start, endTime: end, messages: msgs)
        }

        return (sessions, memoryEvents)
    }

    private func readMessages(_ db: OpaquePointer) -> [RawMessage] {
        let sql = "SELECT id, session_id, time_created, data FROM message ORDER BY session_id, time_created"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        var result: [RawMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0), let sidC = sqlite3_column_text(stmt, 1),
                  let dataC = sqlite3_column_text(stmt, 3) else { continue }
            let fallbackCreated = sqlite3_column_int64(stmt, 2)
            guard let json = decodeJSON(String(cString: dataC)),
                  json["role"] as? String == "assistant" else { continue }

            let tokens = json["tokens"] as? [String: Any]
            let cache = tokens?["cache"] as? [String: Any]
            let reasoning = tokens?["reasoning"] as? Int ?? 0
            let createdMs = (json["time"] as? [String: Any])?["created"] as? Double ?? Double(fallbackCreated)
            let cwd = (json["path"] as? [String: Any])?["cwd"] as? String

            result.append(RawMessage(
                id: String(cString: idC), sessionID: String(cString: sidC),
                timestamp: Date(timeIntervalSince1970: createdMs / 1000),
                model: json["modelID"] as? String,
                inputTokens: tokens?["input"] as? Int ?? 0,
                outputTokens: (tokens?["output"] as? Int ?? 0) + reasoning,
                cacheReadTokens: cache?["read"] as? Int ?? 0,
                cacheWriteTokens: cache?["write"] as? Int ?? 0,
                cost: json["cost"] as? Double ?? 0,
                projectPath: cwd ?? "unknown"
            ))
        }
        return result
    }

    private func readParts(_ db: OpaquePointer) -> [String: [RawPart]] {
        let sql = "SELECT message_id, data FROM part ORDER BY message_id"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [:] }
        defer { sqlite3_finalize(stmt) }

        var result: [String: [RawPart]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let midC = sqlite3_column_text(stmt, 0), let dataC = sqlite3_column_text(stmt, 1) else { continue }
            guard let json = decodeJSON(String(cString: dataC)),
                  json["type"] as? String == "tool",
                  let tool = json["tool"] as? String,
                  let state = json["state"] as? [String: Any]
            else { continue }

            var args: [String: String] = [:]
            if let input = state["input"] as? [String: Any] {
                for (k, v) in input { args[k] = "\(v)" }
            }
            let diff = (state["metadata"] as? [String: Any])?["diff"] as? [String: Any]

            let messageID = String(cString: midC)
            result[messageID, default: []].append(RawPart(
                tool: tool, args: args,
                diffAdditions: diff?["additions"] as? Int,
                diffDeletions: diff?["deletions"] as? Int
            ))
        }
        return result
    }

    private func decodeJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  test -only-testing:ClaudeTryTests/OpenCodeParserTests 2>&1 | tail -40
```
Expected: `** TEST SUCCEEDED **`, all 10 `OpenCodeParserTests` pass.

- [ ] **Step 5: Commit**

```bash
git add ClaudeTry/ClaudeTry/Data/OpenCodeParser.swift ClaudeTry/ClaudeTryTests/OpenCodeParserTests.swift
git commit -m "feat: extract tool calls, lines added/removed, and memory events in OpenCodeParser"
```

---

### Task 7: Wire `OpenCodeParser` into `UsageStore`

**Note on scope:** while exploring the codebase for this task, I found `UsageStore.refreshAsync()` already **discards** `JSONLParser`'s `memoryEvents` output today — there is no `memoryEvents` property on `UsageStore` and no "Memory" tab in `DashboardView` (its `Activity` enum only has Cost/Tokens/Profile/Tools/Projects/Lines). The Memory tab described in the original 2026-06-20 spec was apparently never built. This plan does not add one — that's a separate, pre-existing gap unrelated to OpenCode. Task 6's memory-event extraction is still correct and tested groundwork (mirrors exactly what `JSONLParser` already produces and equally discards), ready for whenever a Memory tab is built. This task mirrors that same existing discard behavior for OpenCode's memory events rather than inventing new `UsageStore` surface area no UI consumes.

**Files:**
- Modify: `ClaudeTry/ClaudeTry/Data/UsageStore.swift`

**Interfaces:**
- Consumes: `OpenCodeParser.scan(dbPath:)` (Tasks 5/6), `JSONLParser.scan(rootURL:)` (existing).
- Produces: `UsageStore.sessions` now includes OpenCode sessions. No new public API — every existing `UsageStore` method (already covered by Tasks 2–4's tests) automatically reflects combined usage.

This task is pure wiring (concatenate two arrays, no branching/logic of its own) with all its real logic already covered by Tasks 3, 5, and 6's unit tests — see Task 8 for the end-to-end manual verification against the real `~/.local/share/opencode/opencode.db` that proves the wiring itself is correct. No new automated test is added here, consistent with how the equivalent Claude-JSONL wiring in `refreshAsync()` has never had a dedicated `UsageStore`-level test either (it's exercised by running the app, not by unit tests that hit the real filesystem).

- [ ] **Step 1: Implement the wiring**

In `ClaudeTry/ClaudeTry/Data/UsageStore.swift`, add the parser as a stored property next to the existing one:

```swift
    private let parser = JSONLParser()
    private let openCodeParser = OpenCodeParser()
```

Then change `refreshAsync()`:

```swift
    private func refreshAsync() async {
        let claudeRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let openCodeDB = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
        async let claudeResult = parser.scan(rootURL: claudeRoot)
        async let openCodeResult = openCodeParser.scan(dbPath: openCodeDB)
        let (claude, opencode) = await (claudeResult, openCodeResult)
        sessions = (claude.sessions + opencode.sessions).sorted { $0.startTime > $1.startTime }
        snapshots.reload()
        isLoaded = true
    }
```

- [ ] **Step 2: Run the full test suite to verify nothing regressed**

```bash
xcodebuild -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  test 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add ClaudeTry/ClaudeTry/Data/UsageStore.swift
git commit -m "feat: merge OpenCode sessions into UsageStore alongside Claude Code"
```

---

### Task 8: End-to-end manual verification against the real OpenCode database

**Files:** none (verification only).

**Interfaces:** none — this task consumes the fully-wired app from Task 7.

- [ ] **Step 1: Full test suite, one last time**

```bash
cd /Users/alexander.quadt/git/claude-mac-tray
xcodebuild -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  test 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 2: Build and install the app**

```bash
make
```
Expected: `✅ ClaudeTry installed to /Applications/ClaudeTry.app and set to launch at login.`

- [ ] **Step 3: Verify combined totals in the Overview tab**

Open the ClaudeTry menu-bar icon. In the Overview tab, switch the range picker to "All". Confirm the total cost shown is higher than Claude Code's JSONL-only total was before this change (cross-check: `sqlite3 ~/.local/share/opencode/opencode.db "SELECT ROUND(SUM(cost),2) FROM session;"` gives OpenCode's own session-table total as a rough sanity bound — the app's message-level sum may differ slightly since it sums per-message rather than per-session-aggregate, which is expected and was noted during design).

- [ ] **Step 4: Verify the Profile breakdown shows 3 entries**

Still in Overview, confirm the Profile row now shows `Claude.ai`, and `OpenCode` (and `Bedrock` too, if any Bedrock-sourced Claude Code sessions exist), each with a distinct dot color and its own `$` figure and session count.

- [ ] **Step 5: Verify the Profile activity chart**

Switch the Activity segmented control to "Profile". Confirm the stacked bar chart renders an `OpenCode` series distinguishable by color from `Claude.ai`/`Bedrock`.

- [ ] **Step 6: Verify Projects tab shows combined per-directory totals**

Switch to the Projects tab. Pick a project directory you know you've used with both Claude Code and OpenCode (e.g. this repo, `claude-mac-tray`, given this feature was built with OpenCode inside this very repo). Confirm its total cost/session count reflects both tools' usage.

- [ ] **Step 7: Verify Tools tab shows OpenCode's native tool-name casing**

Switch the Activity control to "Tools". Confirm lowercase OpenCode tool names (e.g. `bash`, `read`, `edit`) appear as separate bars from any PascalCase Claude Code tool names (e.g. `Bash`, `Read`, `Edit`) — this is the deliberate, documented scope limitation from the design spec, not a bug.

- [ ] **Step 8: Verify graceful handling when OpenCode isn't installed**

```bash
mv ~/.local/share/opencode/opencode.db /tmp/opencode.db.bak
```
Relaunch the app (`make restart`). Confirm it launches without crashing and shows Claude-Code-only totals (Profile row should disappear or show only 1 entry, since `profileBreakdown` returns `nil` when only one profile is present). Restore the file:
```bash
mv /tmp/opencode.db.bak ~/.local/share/opencode/opencode.db
make restart
```

- [ ] **Step 9: Final commit (if any manual-verification fixes were needed)**

If Steps 3–8 surfaced any bugs, fix them, re-run the full test suite (Step 1), and commit with a message describing the specific fix. If everything passed as-is, there's nothing to commit for this task.

---

## Plan Self-Review Notes

- **Spec coverage:** every section of `docs/superpowers/specs/2026-09-14-opencode-profile-design.md` maps to a task — data source/SQLite reading (Tasks 5–6), model changes (Task 2), cost resolution choke point (Task 3), chart color (Task 4), tool/lines/memory extraction (Task 6), model-name aliasing (verified as zero-new-code in Task 5's test using `"claude-sonnet-5"`, which `shortModelName()` already collapses — no dedicated task needed), UsageStore wiring (Task 7), manual testing (Task 8).
- **Deviation from the spec worth flagging:** the spec's Model Changes section said `ClaudeMessage`'s two new fields would have default values "so existing construction sites are unaffected." Empirical testing during plan-writing (see Global Constraints) showed Swift's synthesized `Decodable` silently ignores JSON-provided values for `let` properties with a default value, always resetting them to the compile-time default — a correctness footgun for a `Codable` struct. The plan uses explicit, no-default fields instead (matching `isBedrock`'s existing style), which is why Task 1 (fixing pre-existing broken tests) and Task 2 both touch the same construction call sites — this is intentional, not duplicated work.
- **Discovered pre-existing gap:** the app has no "Memory" tab (see Task 7's note) — Task 6's memory-event extraction is still built and tested since it mirrors Claude Code's own (also-unused) extraction and was explicitly requested, but nothing new is wired into `UsageStore` for it, matching existing behavior.

