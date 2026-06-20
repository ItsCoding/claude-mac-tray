# Claude Mac Tray Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS 14+ menu bar app in Swift that parses Claude Code JSONL transcripts and displays a rich analytics dashboard in a SwiftUI popover.

**Architecture:** An `NSApplicationDelegate` app (no Dock icon) with an `NSStatusItem` tray icon that toggles an `NSPopover` containing a SwiftUI `TabView`. A background actor `JSONLParser` incrementally parses `~/.claude/projects/**/*.jsonl` every 30 seconds, writing parsed state into an `@Observable` `UsageStore` that drives all views.

**Tech Stack:** Swift 5.9+, SwiftUI, Swift Charts, AppKit (`NSStatusItem`, `NSPopover`), XCTest

## Global Constraints

- macOS 14+ deployment target (Sonoma)
- No App Sandbox (requires `com.apple.security.app-sandbox = NO` in entitlements)
- No external Swift package dependencies — stdlib + Apple frameworks only
- `LSUIElement = YES` in Info.plist (no Dock icon)
- All JSONL parsing off the main thread (background actor)
- Cost shown as "—" (not $0) when model is unknown
- Polling interval: 30 seconds

---

## File Map

| File | Responsibility |
|---|---|
| `ClaudeTray/App/AppDelegate.swift` | NSStatusItem setup, NSPopover wiring, app lifecycle |
| `ClaudeTray/App/ClaudeTrayApp.swift` | `@main` entry point, delegates to AppDelegate |
| `ClaudeTray/Data/Models.swift` | All value types: ClaudeMessage, ToolCall, TokenCount, Session, ProjectSummary, MemoryEvent, MemoryOperation, TimePeriod |
| `ClaudeTray/Data/ModelPricing.swift` | Static pricing table, cost calculation helpers |
| `ClaudeTray/Data/JSONLParser.swift` | Background actor: file scanning, JSONL parsing, incremental mtime tracking |
| `ClaudeTray/Data/UsageStore.swift` | @Observable store: holds parsed data, owns Timer, exposes computed views |
| `ClaudeTray/Views/PopoverRootView.swift` | TabView root with 5 tabs |
| `ClaudeTray/Views/OverviewTab.swift` | Today/Week/Month/All Time stats + sparkline |
| `ClaudeTray/Views/UsageChartsTab.swift` | Stacked bar, line, proportion charts |
| `ClaudeTray/Views/ConversationsTab.swift` | Session list with expandable rows |
| `ClaudeTray/Views/ProjectsTab.swift` | Per-project cost rollup list |
| `ClaudeTray/Views/MemoryTab.swift` | Memory stats, growth chart, top files |
| `ClaudeTray/Views/Shared/StatCard.swift` | Reusable stat card component |
| `ClaudeTray/Views/Shared/PeriodPicker.swift` | Reusable Today/Week/Month/All Time segmented control |
| `ClaudeTrayTests/JSONLParserTests.swift` | Unit tests for parser |
| `ClaudeTrayTests/UsageStoreTests.swift` | Unit tests for store computed properties |
| `ClaudeTrayTests/Fixtures/` | .jsonl fixture files |

---

### Task 1: Xcode Project Scaffold

**Files:**
- Create: `ClaudeTray.xcodeproj` (via Xcode)
- Create: `ClaudeTray/App/ClaudeTrayApp.swift`
- Create: `ClaudeTray/App/AppDelegate.swift`
- Create: `ClaudeTray/Info.plist`
- Create: `ClaudeTray/ClaudeTray.entitlements`

**Interfaces:**
- Produces: buildable app target + test target, `AppDelegate` class

- [ ] **Step 1: Create Xcode project**

In Xcode: File → New → Project → macOS → App.
- Product Name: `ClaudeTray`
- Bundle ID: `com.yourname.claudetray`
- Interface: SwiftUI
- Language: Swift
- Uncheck "Include Tests" (we'll add manually)
- Save to `/Users/alex/git/claude-mac-tray/`

- [ ] **Step 2: Set deployment target**

In project settings → ClaudeTray target → General → Minimum Deployments: **macOS 14.0**

- [ ] **Step 3: Add test target**

File → New → Target → Unit Testing Bundle.
- Name: `ClaudeTrayTests`
- Target to be tested: `ClaudeTray`

- [ ] **Step 4: Set LSUIElement in Info.plist**

Add key `Application is agent (UIElement)` = `YES` to `Info.plist`.

Or in raw XML:
```xml
<key>LSUIElement</key>
<true/>
```

- [ ] **Step 5: Create entitlements file**

Create `ClaudeTray/ClaudeTray.entitlements`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
```

In target → Signing & Capabilities, set Code Signing Entitlements to `ClaudeTray/ClaudeTray.entitlements`.

- [ ] **Step 6: Replace ClaudeTrayApp.swift**

```swift
import SwiftUI

@main
struct ClaudeTrayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
```

- [ ] **Step 7: Create AppDelegate.swift**

```swift
import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Claude Usage")
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 560, height: 640)
        popover.behavior = .transient
        // PopoverRootView is defined in Task 6; use a placeholder here
        popover.contentViewController = NSHostingController(rootView: Text("Loading...").frame(width: 560, height: 200))
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
```

- [ ] **Step 8: Build and run**

Cmd+R. Verify: no Dock icon appears, menu bar shows chart icon, clicking it shows a popover with "Loading..." text.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: scaffold Xcode project with tray icon and empty popover"
```

---

### Task 2: Data Models

**Files:**
- Create: `ClaudeTray/Data/Models.swift`
- Test: `ClaudeTrayTests/ModelTests.swift`

**Interfaces:**
- Produces: `ClaudeMessage`, `ToolCall`, `TokenCount`, `Session`, `ProjectSummary`, `MemoryEvent`, `MemoryOperation`, `TimePeriod`

- [ ] **Step 1: Write failing test**

Create `ClaudeTrayTests/ModelTests.swift`:
```swift
import XCTest
@testable import ClaudeTray

final class ModelTests: XCTestCase {
    func test_session_totalInputTokens_sumsAllMessages() {
        let messages = [
            ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-sonnet-4-6",
                          inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0,
                          toolCalls: [], projectPath: "/test/project"),
            ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-sonnet-4-6",
                          inputTokens: 200, outputTokens: 80, cacheReadTokens: 10, cacheWriteTokens: 5,
                          toolCalls: [], projectPath: "/test/project")
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
                          toolCalls: [], projectPath: "/test"),
            ClaudeMessage(timestamp: Date(), role: "assistant", model: "claude-opus-4-8",
                          inputTokens: 200, outputTokens: 80, cacheReadTokens: 0, cacheWriteTokens: 0,
                          toolCalls: [], projectPath: "/test")
        ]
        let session = Session(id: UUID(), projectPath: "/test",
                              startTime: messages[0].timestamp, endTime: messages[1].timestamp,
                              messages: messages)
        XCTAssertEqual(session.modelBreakdown["claude-sonnet-4-6"]?.input, 100)
        XCTAssertEqual(session.modelBreakdown["claude-opus-4-8"]?.input, 200)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Product → Test (Cmd+U). Expected: compile error — types not defined.

- [ ] **Step 3: Create Models.swift**

```swift
import Foundation

enum MemoryOperation { case read, write, create }

enum TimePeriod: String, CaseIterable {
    case today = "Today"
    case thisWeek = "This Week"
    case thisMonth = "This Month"
    case allTime = "All Time"
}

struct ToolCall: Hashable {
    let name: String
    let arguments: [String: String]
}

struct TokenCount {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int

    static let zero = TokenCount(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)

    static func + (lhs: TokenCount, rhs: TokenCount) -> TokenCount {
        TokenCount(input: lhs.input + rhs.input,
                   output: lhs.output + rhs.output,
                   cacheRead: lhs.cacheRead + rhs.cacheRead,
                   cacheWrite: lhs.cacheWrite + rhs.cacheWrite)
    }
}

struct ClaudeMessage {
    let timestamp: Date
    let role: String
    let model: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let toolCalls: [ToolCall]
    let projectPath: String
}

struct Session: Identifiable {
    let id: UUID
    let projectPath: String
    let startTime: Date
    let endTime: Date
    let messages: [ClaudeMessage]

    var totalInputTokens: Int { messages.reduce(0) { $0 + $1.inputTokens } }
    var totalOutputTokens: Int { messages.reduce(0) { $0 + $1.outputTokens } }
    var totalCacheReadTokens: Int { messages.reduce(0) { $0 + $1.cacheReadTokens } }
    var totalCacheWriteTokens: Int { messages.reduce(0) { $0 + $1.cacheWriteTokens } }

    var projectName: String { URL(fileURLWithPath: projectPath).lastPathComponent }

    var modelBreakdown: [String: TokenCount] {
        var result: [String: TokenCount] = [:]
        for msg in messages {
            guard let model = msg.model else { continue }
            let existing = result[model] ?? .zero
            result[model] = existing + TokenCount(input: msg.inputTokens, output: msg.outputTokens,
                                                   cacheRead: msg.cacheReadTokens, cacheWrite: msg.cacheWriteTokens)
        }
        return result
    }

    var toolCallCounts: [String: Int] {
        var result: [String: Int] = [:]
        for msg in messages {
            for call in msg.toolCalls {
                result[call.name, default: 0] += 1
            }
        }
        return result
    }

    var primaryModel: String? {
        modelBreakdown.max(by: { $0.value.input < $1.value.input })?.key
    }
}

struct ProjectSummary: Identifiable {
    let path: String
    let sessions: [Session]

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var lastActive: Date? { sessions.map(\.endTime).max() }
    var totalSessions: Int { sessions.count }

    var totalTokens: TokenCount {
        sessions.reduce(.zero) { acc, s in
            acc + TokenCount(input: s.totalInputTokens, output: s.totalOutputTokens,
                             cacheRead: s.totalCacheReadTokens, cacheWrite: s.totalCacheWriteTokens)
        }
    }
}

struct MemoryEvent: Identifiable {
    let id: UUID
    let timestamp: Date
    let projectPath: String
    let memoryFilePath: String
    let operation: MemoryOperation
}
```

- [ ] **Step 4: Run tests**

Cmd+U. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeTray/Data/Models.swift ClaudeTrayTests/ModelTests.swift
git commit -m "feat: add core data models"
```

---

### Task 3: Pricing Table

**Files:**
- Create: `ClaudeTray/Data/ModelPricing.swift`
- Test: `ClaudeTrayTests/ModelPricingTests.swift`

**Interfaces:**
- Consumes: `TokenCount` (from Task 2)
- Produces: `ModelPricing.cost(for:tokens:) -> Double?`, `ModelPricing.cost(for:Session) -> Double?`

- [ ] **Step 1: Write failing test**

Create `ClaudeTrayTests/ModelPricingTests.swift`:
```swift
import XCTest
@testable import ClaudeTray

final class ModelPricingTests: XCTestCase {
    func test_cost_knownModel_returnsCorrectCost() {
        // claude-sonnet-4-6: $3/M input, $15/M output, $0.30/M cache read, $3.75/M cache write
        let tokens = TokenCount(input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0)
        let cost = ModelPricing.cost(for: "claude-sonnet-4-6", tokens: tokens)
        XCTAssertEqual(cost!, 3.0, accuracy: 0.001)
    }

    func test_cost_unknownModel_returnsNil() {
        let tokens = TokenCount(input: 1000, output: 500, cacheRead: 0, cacheWrite: 0)
        XCTAssertNil(ModelPricing.cost(for: "some-unknown-model-xyz", tokens: tokens))
    }

    func test_cost_includesCacheTokens() {
        // 1M cache read tokens at $0.30/M = $0.30
        let tokens = TokenCount(input: 0, output: 0, cacheRead: 1_000_000, cacheWrite: 0)
        let cost = ModelPricing.cost(for: "claude-sonnet-4-6", tokens: tokens)
        XCTAssertEqual(cost!, 0.30, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Cmd+U. Expected: compile error.

- [ ] **Step 3: Create ModelPricing.swift**

```swift
import Foundation

struct PricingEntry {
    let inputPerMillion: Double
    let outputPerMillion: Double
    let cacheReadPerMillion: Double
    let cacheWritePerMillion: Double
}

enum ModelPricing {
    // Prices in USD per million tokens as of 2026-06
    // Update when Anthropic changes pricing
    private static let table: [(prefix: String, entry: PricingEntry)] = [
        ("claude-opus-4",    PricingEntry(inputPerMillion: 15.0,  outputPerMillion: 75.0,  cacheReadPerMillion: 1.50,  cacheWritePerMillion: 18.75)),
        ("claude-sonnet-4",  PricingEntry(inputPerMillion: 3.0,   outputPerMillion: 15.0,  cacheReadPerMillion: 0.30,  cacheWritePerMillion: 3.75)),
        ("claude-haiku-4",   PricingEntry(inputPerMillion: 0.80,  outputPerMillion: 4.0,   cacheReadPerMillion: 0.08,  cacheWritePerMillion: 1.0)),
        ("claude-fable-5",   PricingEntry(inputPerMillion: 3.0,   outputPerMillion: 15.0,  cacheReadPerMillion: 0.30,  cacheWritePerMillion: 3.75)),
    ]

    static func cost(for modelID: String, tokens: TokenCount) -> Double? {
        guard let entry = table.first(where: { modelID.contains($0.prefix) })?.entry else { return nil }
        let inputCost  = Double(tokens.input)      / 1_000_000 * entry.inputPerMillion
        let outputCost = Double(tokens.output)     / 1_000_000 * entry.outputPerMillion
        let cacheRead  = Double(tokens.cacheRead)  / 1_000_000 * entry.cacheReadPerMillion
        let cacheWrite = Double(tokens.cacheWrite) / 1_000_000 * entry.cacheWritePerMillion
        return inputCost + outputCost + cacheRead + cacheWrite
    }

    static func cost(for session: Session) -> Double? {
        var total = 0.0
        for msg in session.messages {
            guard let model = msg.model else { return nil }
            let tokens = TokenCount(input: msg.inputTokens, output: msg.outputTokens,
                                     cacheRead: msg.cacheReadTokens, cacheWrite: msg.cacheWriteTokens)
            guard let c = cost(for: model, tokens: tokens) else { return nil }
            total += c
        }
        return total
    }
}
```

- [ ] **Step 4: Run tests**

Cmd+U. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeTray/Data/ModelPricing.swift ClaudeTrayTests/ModelPricingTests.swift
git commit -m "feat: add model pricing table and cost calculation"
```

---

### Task 4: JSONL Parser

**Files:**
- Create: `ClaudeTray/Data/JSONLParser.swift`
- Create: `ClaudeTrayTests/Fixtures/simple_session.jsonl`
- Create: `ClaudeTrayTests/Fixtures/malformed_lines.jsonl`
- Create: `ClaudeTrayTests/Fixtures/memory_ops.jsonl`
- Create: `ClaudeTrayTests/Fixtures/unknown_model.jsonl`
- Create: `ClaudeTrayTests/Fixtures/empty_file.jsonl`
- Test: `ClaudeTrayTests/JSONLParserTests.swift`

**Interfaces:**
- Consumes: `ClaudeMessage`, `ToolCall`, `Session`, `MemoryEvent`, `MemoryOperation` (Task 2)
- Produces: `JSONLParser` actor with `scan(rootURL:) async -> (sessions: [Session], memoryEvents: [MemoryEvent])` and `parseFile(url:projectPath:) async -> ParsedFile`

- [ ] **Step 1: Create fixture files**

Create `ClaudeTrayTests/Fixtures/simple_session.jsonl`:
```json
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hello"}],"model":"claude-sonnet-4-6","usage":{"input_tokens":150,"output_tokens":30,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"timestamp":"2026-06-20T10:00:00Z"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"Bash","input":{"command":"ls"}}],"model":"claude-sonnet-4-6","usage":{"input_tokens":200,"output_tokens":10,"cache_read_input_tokens":50,"cache_creation_input_tokens":20}},"timestamp":"2026-06-20T10:01:00Z"}
```

Create `ClaudeTrayTests/Fixtures/malformed_lines.jsonl`:
```json
{"type":"assistant","message":{"role":"assistant","content":[],"model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"timestamp":"2026-06-20T09:00:00Z"}
not valid json at all {{{
{"type":"assistant","message":{"role":"assistant","content":[],"model":"claude-sonnet-4-6","usage":{"input_tokens":50,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"timestamp":"2026-06-20T09:01:00Z"}
```

Create `ClaudeTrayTests/Fixtures/memory_ops.jsonl`:
```json
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/Users/alex/.claude/projects/myproject/memory/user_prefs.md"}}],"model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"timestamp":"2026-06-20T11:00:00Z"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Write","input":{"file_path":"/Users/alex/.claude/projects/myproject/memory/feedback_terse.md"}}],"model":"claude-sonnet-4-6","usage":{"input_tokens":120,"output_tokens":8,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"timestamp":"2026-06-20T11:01:00Z"}
```

Create `ClaudeTrayTests/Fixtures/unknown_model.jsonl`:
```json
{"type":"assistant","message":{"role":"assistant","content":[],"model":"claude-future-unknown-99","usage":{"input_tokens":300,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"timestamp":"2026-06-20T12:00:00.123Z"}
```

Create `ClaudeTrayTests/Fixtures/empty_file.jsonl` — a zero-byte file (create it but leave it empty).

- [ ] **Step 2: Write failing tests**

Create `ClaudeTrayTests/JSONLParserTests.swift`:
```swift
import XCTest
@testable import ClaudeTray

final class JSONLParserTests: XCTestCase {
    var parser: JSONLParser!
    var fixturesURL: URL!

    override func setUp() {
        super.setUp()
        parser = JSONLParser()
        fixturesURL = Bundle(for: type(of: self)).resourceURL!
            .appendingPathComponent("Fixtures")
    }

    func test_parse_simpleSession_extractsMessages() async throws {
        let url = fixturesURL.appendingPathComponent("simple_session.jsonl")
        let result = await parser.parseFile(url: url, projectPath: "/test/project")
        XCTAssertEqual(result.messages.count, 2)
        XCTAssertEqual(result.messages[0].inputTokens, 150)
        XCTAssertEqual(result.messages[1].toolCalls.first?.name, "Bash")
        XCTAssertEqual(result.messages[1].cacheReadTokens, 50)
        XCTAssertEqual(result.messages[1].cacheWriteTokens, 20)
    }

    func test_parse_malformedLines_skipsAndContinues() async throws {
        let url = fixturesURL.appendingPathComponent("malformed_lines.jsonl")
        let result = await parser.parseFile(url: url, projectPath: "/test")
        XCTAssertEqual(result.messages.count, 2)
    }

    func test_parse_memoryOps_extractsMemoryEvents() async throws {
        let url = fixturesURL.appendingPathComponent("memory_ops.jsonl")
        let result = await parser.parseFile(url: url, projectPath: "/Users/alex/.claude/projects/myproject")
        XCTAssertEqual(result.memoryEvents.count, 2)
        let readEvent = result.memoryEvents.first { $0.operation == .read }
        let writeEvent = result.memoryEvents.first { $0.operation == .write || $0.operation == .create }
        XCTAssertNotNil(readEvent)
        XCTAssertNotNil(writeEvent)
        XCTAssertTrue(readEvent!.memoryFilePath.contains("user_prefs.md"))
    }

    func test_parse_unknownModel_stillParsesTokens() async throws {
        let url = fixturesURL.appendingPathComponent("unknown_model.jsonl")
        let result = await parser.parseFile(url: url, projectPath: "/test")
        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages[0].inputTokens, 300)
        XCTAssertEqual(result.messages[0].model, "claude-future-unknown-99")
    }

    func test_parse_emptyFile_returnsEmptyResult() async throws {
        let url = fixturesURL.appendingPathComponent("empty_file.jsonl")
        let result = await parser.parseFile(url: url, projectPath: "/test")
        XCTAssertEqual(result.messages.count, 0)
        XCTAssertEqual(result.memoryEvents.count, 0)
    }

    func test_parse_fractionalSecondTimestamp_parsesCorrectly() async throws {
        // unknown_model.jsonl has a fractional-second timestamp
        let url = fixturesURL.appendingPathComponent("unknown_model.jsonl")
        let result = await parser.parseFile(url: url, projectPath: "/test")
        XCTAssertEqual(result.messages.count, 1, "Fractional-second timestamp must parse successfully")
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Cmd+U. Expected: compile error — `JSONLParser` not defined.

- [ ] **Step 4: Create JSONLParser.swift**

```swift
import Foundation

struct ParsedFile {
    let messages: [ClaudeMessage]
    let memoryEvents: [MemoryEvent]
}

actor JSONLParser {
    private var mtimeCache: [URL: Date] = [:]

    func scan(rootURL: URL) async -> (sessions: [Session], memoryEvents: [MemoryEvent]) {
        var allSessions: [Session] = []
        var allMemoryEvents: [MemoryEvent] = []

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], []) }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }

            let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mtime, mtimeCache[fileURL] == mtime { continue }
            mtimeCache[fileURL] = mtime

            let projectPath = fileURL.deletingLastPathComponent().path
            let parsed = await parseFile(url: fileURL, projectPath: projectPath)

            if !parsed.messages.isEmpty {
                let session = Session(
                    id: UUID(),
                    projectPath: projectPath,
                    startTime: parsed.messages.first!.timestamp,
                    endTime: parsed.messages.last!.timestamp,
                    messages: parsed.messages
                )
                allSessions.append(session)
            }
            allMemoryEvents.append(contentsOf: parsed.memoryEvents)
        }

        return (allSessions, allMemoryEvents)
    }

    func parseFile(url: URL, projectPath: String) async -> ParsedFile {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return ParsedFile(messages: [], memoryEvents: [])
        }

        var messages: [ClaudeMessage] = []
        var memoryEvents: [MemoryEvent] = []
        var seenMemoryPaths = Set<String>()
        // Two formatters: Claude Code sometimes writes fractional seconds, sometimes not
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoWhole = ISO8601DateFormatter()
        isoWhole.formatOptions = [.withInternetDateTime]
        func parseDate(_ s: String) -> Date? { isoFractional.date(from: s) ?? isoWhole.date(from: s) }

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            guard let messageDict = json["message"] as? [String: Any],
                  let role = messageDict["role"] as? String,
                  let timestampStr = json["timestamp"] as? String,
                  let timestamp = parseDate(timestampStr)
            else { continue }

            let model = messageDict["model"] as? String
            let usage = messageDict["usage"] as? [String: Any]
            let inputTokens      = usage?["input_tokens"] as? Int ?? 0
            let outputTokens     = usage?["output_tokens"] as? Int ?? 0
            let cacheReadTokens  = usage?["cache_read_input_tokens"] as? Int ?? 0
            let cacheWriteTokens = usage?["cache_creation_input_tokens"] as? Int ?? 0

            var toolCalls: [ToolCall] = []
            if let content = messageDict["content"] as? [[String: Any]] {
                for block in content {
                    guard let type = block["type"] as? String, type == "tool_use",
                          let name = block["name"] as? String
                    else { continue }

                    var args: [String: String] = [:]
                    if let input = block["input"] as? [String: Any] {
                        for (k, v) in input { args[k] = "\(v)" }
                    }
                    toolCalls.append(ToolCall(name: name, arguments: args))

                    let pathArg = args["file_path"] ?? args["path"] ?? ""
                    if pathArg.contains("/memory/") {
                        let isRead = name == "Read"
                        let isFirstSeen = !seenMemoryPaths.contains(pathArg)
                        if !isRead { seenMemoryPaths.insert(pathArg) }

                        let op: MemoryOperation
                        if isRead { op = .read }
                        else if isFirstSeen { op = .create }
                        else { op = .write }

                        memoryEvents.append(MemoryEvent(
                            id: UUID(),
                            timestamp: timestamp,
                            projectPath: projectPath,
                            memoryFilePath: pathArg,
                            operation: op
                        ))
                    }
                }
            }

            messages.append(ClaudeMessage(
                timestamp: timestamp,
                role: role,
                model: model,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                toolCalls: toolCalls,
                projectPath: projectPath
            ))
        }

        return ParsedFile(messages: messages, memoryEvents: memoryEvents)
    }
}
```

- [ ] **Step 5: Add fixture files to test target**

In Xcode: select all 5 `.jsonl` fixture files (`simple_session`, `malformed_lines`, `memory_ops`, `unknown_model`, `empty_file`) → Target Membership → check `ClaudeTrayTests`.

- [ ] **Step 6: Run tests**

Cmd+U. Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add ClaudeTray/Data/JSONLParser.swift ClaudeTrayTests/JSONLParserTests.swift ClaudeTrayTests/Fixtures/
git commit -m "feat: JSONL parser with incremental scanning and memory event detection"
```

---

### Task 5: UsageStore

**Files:**
- Create: `ClaudeTray/Data/UsageStore.swift`
- Test: `ClaudeTrayTests/UsageStoreTests.swift`

**Interfaces:**
- Consumes: `JSONLParser.scan()`, `Session`, `ProjectSummary`, `MemoryEvent`, `ModelPricing.cost(for:Session)`, `TimePeriod` (Tasks 2, 3, 4)
- Produces: `UsageStore` — `@Observable @MainActor` class with `sessions: [Session]`, `memoryEvents: [MemoryEvent]`, `projects: [ProjectSummary]`, `func filteredSessions(for:TimePeriod) -> [Session]`, `func totalCost(for:TimePeriod) -> Double?`, `func dailyTokenBuckets(for:TimePeriod) -> [DailyBucket]`, `func modelBreakdown(for:TimePeriod) -> [String: TokenCount]`, `func topToolCalls(for:TimePeriod) -> [(name:String, count:Int)]`, `func startPolling()`

- [ ] **Step 1: Write failing tests**

Create `ClaudeTrayTests/UsageStoreTests.swift`:
```swift
import XCTest
@testable import ClaudeTray

final class UsageStoreTests: XCTestCase {
    func makeSessions() -> [Session] {
        let cal = Calendar.current
        let now = Date()
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        let lastWeek = cal.date(byAdding: .day, value: -8, to: now)!

        func msg(_ tokens: Int, _ model: String, _ date: Date, _ toolName: String? = nil) -> ClaudeMessage {
            let tc = toolName.map { [ToolCall(name: $0, arguments: [:])] } ?? []
            return ClaudeMessage(timestamp: date, role: "assistant", model: model,
                                  inputTokens: tokens, outputTokens: 0,
                                  cacheReadTokens: 0, cacheWriteTokens: 0,
                                  toolCalls: tc, projectPath: "/p")
        }

        return [
            Session(id: UUID(), projectPath: "/p", startTime: now, endTime: now,
                    messages: [msg(1000, "claude-sonnet-4-6", now, "Bash"), msg(500, "claude-sonnet-4-6", now)]),
            Session(id: UUID(), projectPath: "/p", startTime: yesterday, endTime: yesterday,
                    messages: [msg(2000, "claude-opus-4-8", yesterday)]),
            Session(id: UUID(), projectPath: "/q", startTime: lastWeek, endTime: lastWeek,
                    messages: [msg(3000, "claude-sonnet-4-6", lastWeek)]),
        ]
    }

    @MainActor func test_sessions_today_returnsOnlyTodaysSessions() {
        let store = UsageStore()
        store.sessions = makeSessions()
        let todaySessions = store.filteredSessions(for: .today)
        XCTAssertEqual(todaySessions.count, 1)
        XCTAssertEqual(todaySessions[0].totalInputTokens, 1500)
    }

    @MainActor func test_sessions_thisWeek_excludesLastWeek() {
        let store = UsageStore()
        store.sessions = makeSessions()
        let weekSessions = store.filteredSessions(for: .thisWeek)
        XCTAssertEqual(weekSessions.count, 2)
    }

    @MainActor func test_dailyTokenBuckets_allTime_hasEntryPerDay() {
        let store = UsageStore()
        store.sessions = makeSessions()
        let buckets = store.dailyTokenBuckets(for: .allTime)
        XCTAssertGreaterThanOrEqual(buckets.count, 2)
        let totalTokens = buckets.reduce(0) { $0 + $1.totalInputTokens }
        XCTAssertEqual(totalTokens, 6500)
    }

    @MainActor func test_topToolCalls_countsAcrossSessions() {
        let store = UsageStore()
        store.sessions = makeSessions()
        let tools = store.topToolCalls(for: .allTime)
        XCTAssertEqual(tools.first?.name, "Bash")
        XCTAssertEqual(tools.first?.count, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Cmd+U. Expected: compile error.

- [ ] **Step 3: Create UsageStore.swift**

```swift
import Foundation
import Observation

struct DailyBucket: Identifiable {
    let date: Date
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let modelTokens: [String: Int]
    var id: Date { date }
}

@Observable
@MainActor
final class UsageStore {
    var sessions: [Session] = []
    var memoryEvents: [MemoryEvent] = []
    private var timer: Timer?
    private let parser = JSONLParser()

    var projects: [ProjectSummary] {
        Dictionary(grouping: sessions, by: \.projectPath)
            .map { ProjectSummary(path: $0.key, sessions: $0.value) }
            .sorted { ($0.totalTokens.input + $0.totalTokens.output) > ($1.totalTokens.input + $1.totalTokens.output) }
    }

    func startPolling() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { await self?.refreshAsync() }
        }
    }

    func refresh() {
        Task { await refreshAsync() }
    }

    private func refreshAsync() async {
        let rootURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let result = await parser.scan(rootURL: rootURL)
        sessions = result.sessions.sorted { $0.startTime > $1.startTime }
        memoryEvents = result.memoryEvents
    }

    func filteredSessions(for period: TimePeriod) -> [Session] {
        sessions.filter { $0.startTime >= startDate(for: period) }
    }

    func totalCost(for period: TimePeriod) -> Double? {
        var total = 0.0
        for session in filteredSessions(for: period) {
            guard let cost = ModelPricing.cost(for: session) else { return nil }
            total += cost
        }
        return total
    }

    func dailyTokenBuckets(for period: TimePeriod) -> [DailyBucket] {
        let cal = Calendar.current
        var bucketMap: [Date: (Int, Int, [String: Int])] = [:]
        for session in filteredSessions(for: period) {
            let day = cal.startOfDay(for: session.startTime)
            var (inp, out, models) = bucketMap[day] ?? (0, 0, [:])
            inp += session.totalInputTokens
            out += session.totalOutputTokens
            for (model, tc) in session.modelBreakdown {
                models[model, default: 0] += tc.input
            }
            bucketMap[day] = (inp, out, models)
        }
        return bucketMap.map { day, entry in
            DailyBucket(date: day, totalInputTokens: entry.0,
                        totalOutputTokens: entry.1, modelTokens: entry.2)
        }.sorted { $0.date < $1.date }
    }

    func modelBreakdown(for period: TimePeriod) -> [String: TokenCount] {
        var result: [String: TokenCount] = [:]
        for session in filteredSessions(for: period) {
            for (model, tc) in session.modelBreakdown {
                result[model] = (result[model] ?? .zero) + tc
            }
        }
        return result
    }

    func topToolCalls(for period: TimePeriod) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for session in filteredSessions(for: period) {
            for (name, count) in session.toolCallCounts {
                counts[name, default: 0] += count
            }
        }
        return counts.map { (name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    private func startDate(for period: TimePeriod) -> Date {
        let cal = Calendar.current
        let now = Date()
        switch period {
        case .today:     return cal.startOfDay(for: now)
        case .thisWeek:  return cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now))!
        case .thisMonth: return cal.date(byAdding: .month, value: -1, to: cal.startOfDay(for: now))!
        case .allTime:   return Date.distantPast
        }
    }
}
```

- [ ] **Step 4: Wire UsageStore into AppDelegate**

Replace full `AppDelegate.swift`:
```swift
import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let store = UsageStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Claude Usage")
            button.imagePosition = .imageLeft
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 560, height: 640)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverRootView().environment(store))

        store.startPolling()

        Task { @MainActor in
            while true {
                self.updateStatusLabel()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    @MainActor
    private func updateStatusLabel() {
        if let cost = store.totalCost(for: .today) {
            statusItem.button?.title = String(format: " $%.2f", cost)
        } else {
            let count = store.filteredSessions(for: .today).count
            statusItem.button?.title = count > 0 ? " \(count)" : ""
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
```

- [ ] **Step 5: Run tests**

Cmd+U. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add ClaudeTray/Data/UsageStore.swift ClaudeTrayTests/UsageStoreTests.swift ClaudeTray/App/AppDelegate.swift
git commit -m "feat: UsageStore with polling, period filtering, bucketing, and menu bar cost label"
```

---

### Task 6: Shared View Components + Popover Shell

**Files:**
- Create: `ClaudeTray/Views/Shared/StatCard.swift`
- Create: `ClaudeTray/Views/Shared/PeriodPicker.swift`
- Create: `ClaudeTray/Views/PopoverRootView.swift`
- Create stubs: `OverviewTab.swift`, `UsageChartsTab.swift`, `ConversationsTab.swift`, `ProjectsTab.swift`, `MemoryTab.swift`

**Interfaces:**
- Consumes: `UsageStore` (Task 5), `TimePeriod` (Task 2)
- Produces: `StatCard(title:value:subtitle:)`, `PeriodPicker(selection:)`, `PopoverRootView`

- [ ] **Step 1: Create StatCard.swift**

```swift
import SwiftUI

struct StatCard: View {
    let title: String
    let value: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.monospacedDigit())
                .fontWeight(.semibold)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
```

- [ ] **Step 2: Create PeriodPicker.swift**

```swift
import SwiftUI

struct PeriodPicker: View {
    @Binding var selection: TimePeriod

    var body: some View {
        Picker("Period", selection: $selection) {
            ForEach(TimePeriod.allCases, id: \.self) { period in
                Text(period.rawValue).tag(period)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
```

- [ ] **Step 3: Create tab stubs**

Create these five files (real implementations replace them in Tasks 7–11):

`ClaudeTray/Views/OverviewTab.swift`:
```swift
import SwiftUI
struct OverviewTab: View {
    var body: some View { Text("Overview").frame(maxWidth: .infinity, maxHeight: .infinity) }
}
```

`ClaudeTray/Views/UsageChartsTab.swift`:
```swift
import SwiftUI
struct UsageChartsTab: View {
    var body: some View { Text("Charts").frame(maxWidth: .infinity, maxHeight: .infinity) }
}
```

`ClaudeTray/Views/ConversationsTab.swift`:
```swift
import SwiftUI
struct ConversationsTab: View {
    var body: some View { Text("Conversations").frame(maxWidth: .infinity, maxHeight: .infinity) }
}
```

`ClaudeTray/Views/ProjectsTab.swift`:
```swift
import SwiftUI
struct ProjectsTab: View {
    var body: some View { Text("Projects").frame(maxWidth: .infinity, maxHeight: .infinity) }
}
```

`ClaudeTray/Views/MemoryTab.swift`:
```swift
import SwiftUI
struct MemoryTab: View {
    var body: some View { Text("Memory").frame(maxWidth: .infinity, maxHeight: .infinity) }
}
```

- [ ] **Step 4: Create PopoverRootView.swift**

```swift
import SwiftUI

struct PopoverRootView: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        TabView {
            OverviewTab()
                .tabItem { Label("Overview", systemImage: "chart.bar.fill") }
            UsageChartsTab()
                .tabItem { Label("Charts", systemImage: "chart.line.uptrend.xyaxis") }
            ConversationsTab()
                .tabItem { Label("Conversations", systemImage: "bubble.left.and.bubble.right") }
            ProjectsTab()
                .tabItem { Label("Projects", systemImage: "folder") }
            MemoryTab()
                .tabItem { Label("Memory", systemImage: "brain") }
        }
        .frame(width: 560)
        .padding(12)
    }
}
```

- [ ] **Step 5: Build and run**

Cmd+R. Click tray icon. Verify 5-tab popover opens with stub content.

- [ ] **Step 6: Commit**

```bash
git add ClaudeTray/Views/
git commit -m "feat: shared components and 5-tab popover shell"
```

---

### Task 7: Overview Tab

**Files:**
- Modify: `ClaudeTray/Views/OverviewTab.swift` (replace stub)

**Interfaces:**
- Consumes: `UsageStore.sessions(for:)`, `UsageStore.totalCost(for:)`, `UsageStore.projects`, `UsageStore.dailyTokenBuckets(for:)`, `StatCard`, `PeriodPicker`, `DailyBucket`, Swift Charts

- [ ] **Step 1: Replace OverviewTab.swift**

```swift
import SwiftUI
import Charts

struct OverviewTab: View {
    @Environment(UsageStore.self) private var store
    @State private var period: TimePeriod = .today

    private var filtered: [Session] { store.filteredSessions(for: period) }
    private var totalTokens: Int { filtered.reduce(0) { $0 + $1.totalInputTokens + $1.totalOutputTokens } }
    private var costString: String {
        if let cost = store.totalCost(for: period) { return String(format: "$%.2f", cost) }
        return "—"
    }
    private var activeProjects: Int { Set(filtered.map(\.projectPath)).count }
    private var buckets: [DailyBucket] { store.dailyTokenBuckets(for: period) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PeriodPicker(selection: $period)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                StatCard(title: "Tokens", value: totalTokens.formatted())
                StatCard(title: "Cost", value: costString)
                StatCard(title: "Sessions", value: "\(filtered.count)")
                StatCard(title: "Projects", value: "\(activeProjects)")
            }

            if buckets.isEmpty {
                ContentUnavailableView("No data for this period", systemImage: "chart.bar")
                    .frame(height: 120)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Daily Token Usage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Chart(buckets) { bucket in
                        BarMark(
                            x: .value("Day", bucket.date, unit: .day),
                            y: .value("Tokens", bucket.totalInputTokens + bucket.totalOutputTokens)
                        )
                        .foregroundStyle(.blue)
                    }
                    .frame(height: 100)
                    .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisTick(); AxisGridLine() } }
                }
            }

            if let top = store.projects.first {
                HStack {
                    Text("Most active:").font(.caption).foregroundStyle(.secondary)
                    Text(top.name).font(.caption).fontWeight(.medium)
                }
            }

            Spacer()
        }
    }
}
```

- [ ] **Step 2: Build and run, verify Overview tab**

- [ ] **Step 3: Commit**

```bash
git add ClaudeTray/Views/OverviewTab.swift
git commit -m "feat: overview tab with stats cards and daily token sparkline"
```

---

### Task 8: Usage Charts Tab

**Files:**
- Modify: `ClaudeTray/Views/UsageChartsTab.swift` (replace stub)

**Interfaces:**
- Consumes: `UsageStore.dailyTokenBuckets(for:)`, `UsageStore.sessions(for:)`, `ModelPricing.cost(for:Session)`, `DailyBucket`, Swift Charts

- [ ] **Step 1: Replace UsageChartsTab.swift**

```swift
import SwiftUI
import Charts

struct UsageChartsTab: View {
    @Environment(UsageStore.self) private var store
    @State private var period: TimePeriod = .thisWeek

    private var buckets: [DailyBucket] { store.dailyTokenBuckets(for: period) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PeriodPicker(selection: $period)

                // Stacked bar by model
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tokens by Model").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if buckets.isEmpty {
                        ContentUnavailableView("No data", systemImage: "chart.bar").frame(height: 150)
                    } else {
                        Chart {
                            ForEach(buckets) { bucket in
                                ForEach(bucket.modelTokens.sorted(by: { $0.key < $1.key }), id: \.key) { model, tokens in
                                    BarMark(
                                        x: .value("Day", bucket.date, unit: .day),
                                        y: .value("Tokens", tokens)
                                    )
                                    .foregroundStyle(by: .value("Model", shortModelName(model)))
                                }
                            }
                        }
                        .frame(height: 150)
                        .chartLegend(position: .bottom)
                    }
                }

                // Cost over time
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cost Over Time").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    let costBuckets = costByDay()
                    if costBuckets.isEmpty {
                        ContentUnavailableView("No cost data", systemImage: "dollarsign.circle").frame(height: 120)
                    } else {
                        Chart(costBuckets, id: \.date) { item in
                            LineMark(x: .value("Day", item.date, unit: .day), y: .value("Cost", item.cost))
                                .interpolationMethod(.catmullRom)
                            AreaMark(x: .value("Day", item.date, unit: .day), y: .value("Cost", item.cost))
                                .foregroundStyle(.blue.opacity(0.15))
                                .interpolationMethod(.catmullRom)
                        }
                        .frame(height: 120)
                        .chartYAxis { AxisMarks(format: .currency(code: "USD")) }
                    }
                }

                // Input vs Output
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input vs Output Tokens").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    let sessions = store.filteredSessions(for: period)
                    let totalIn = sessions.reduce(0) { $0 + $1.totalInputTokens }
                    let totalOut = sessions.reduce(0) { $0 + $1.totalOutputTokens }
                    if totalIn + totalOut == 0 {
                        ContentUnavailableView("No data", systemImage: "chart.pie").frame(height: 80)
                    } else {
                        Chart {
                            SectorMark(angle: .value("Tokens", totalIn))
                                .foregroundStyle(.blue)
                                .annotation(position: .overlay) {
                                    Text("Input\n\(totalIn.formatted())").font(.caption2).multilineTextAlignment(.center)
                                }
                            SectorMark(angle: .value("Tokens", totalOut))
                                .foregroundStyle(.green)
                                .annotation(position: .overlay) {
                                    Text("Output\n\(totalOut.formatted())").font(.caption2).multilineTextAlignment(.center)
                                }
                        }
                        .frame(height: 120)
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func shortModelName(_ model: String) -> String {
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        if model.contains("fable") { return "Fable" }
        return model
    }

    private func costByDay() -> [(date: Date, cost: Double)] {
        let cal = Calendar.current
        var map: [Date: Double] = [:]
        for session in store.filteredSessions(for: period) {
            guard let cost = ModelPricing.cost(for: session) else { continue }
            let day = cal.startOfDay(for: session.startTime)
            map[day, default: 0] += cost
        }
        return map.map { (date: $0.key, cost: $0.value) }.sorted { $0.date < $1.date }
    }
}
```

- [ ] **Step 2: Build and run, verify three charts render**

- [ ] **Step 3: Commit**

```bash
git add ClaudeTray/Views/UsageChartsTab.swift
git commit -m "feat: usage charts tab with stacked model bars, cost line, input/output pie"
```

---

### Task 9: Conversations Tab

**Files:**
- Modify: `ClaudeTray/Views/ConversationsTab.swift` (replace stub)

**Interfaces:**
- Consumes: `UsageStore.sessions`, `Session.toolCallCounts`, `Session.modelBreakdown`, `Session.primaryModel`, `ModelPricing.cost(for:Session)`

- [ ] **Step 1: Replace ConversationsTab.swift**

```swift
import SwiftUI

struct ConversationsTab: View {
    @Environment(UsageStore.self) private var store
    @State private var expandedSessionID: UUID? = nil
    @State private var searchText = ""

    private var filtered: [Session] {
        guard !searchText.isEmpty else { return store.sessions }
        return store.sessions.filter {
            $0.projectName.localizedCaseInsensitiveContains(searchText) ||
            ($0.primaryModel ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Filter by project or model", text: $searchText)
                .textFieldStyle(.roundedBorder)

            if filtered.isEmpty {
                ContentUnavailableView("No conversations", systemImage: "bubble.left.and.bubble.right")
                    .frame(maxHeight: .infinity)
            } else {
                List(filtered) { session in
                    SessionRow(session: session, isExpanded: expandedSessionID == session.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedSessionID = expandedSessionID == session.id ? nil : session.id
                            }
                        }
                }
                .listStyle(.plain)
            }
        }
    }
}

private struct SessionRow: View {
    let session: Session
    let isExpanded: Bool

    private var costString: String {
        if let cost = ModelPricing.cost(for: session) { return String(format: "$%.4f", cost) }
        return "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.projectName)
                        .font(.system(.body, design: .monospaced)).fontWeight(.medium)
                    Text(session.startTime.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(costString).font(.caption.monospacedDigit()).fontWeight(.medium)
                    Text("\((session.totalInputTokens + session.totalOutputTokens).formatted()) tok")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let model = session.primaryModel {
                    Text(shortModel(model))
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.blue.opacity(0.15), in: Capsule())
                        .foregroundStyle(.blue)
                }
            }

            if isExpanded {
                Divider()
                if !session.toolCallCounts.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tool Calls").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(session.toolCallCounts.sorted { $0.value > $1.value }, id: \.key) { tool, count in
                            HStack {
                                Text(tool).font(.caption.monospaced())
                                Spacer()
                                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if session.modelBreakdown.count > 1 {
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model Split").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(session.modelBreakdown.sorted { $0.value.input > $1.value.input }, id: \.key) { model, tc in
                            HStack {
                                Text(shortModel(model)).font(.caption)
                                Spacer()
                                Text("\((tc.input + tc.output).formatted()) tok")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func shortModel(_ model: String) -> String {
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        if model.contains("fable") { return "Fable" }
        return String(model.prefix(12))
    }
}
```

- [ ] **Step 2: Build and run, tap sessions to verify expansion**

- [ ] **Step 3: Commit**

```bash
git add ClaudeTray/Views/ConversationsTab.swift
git commit -m "feat: conversations tab with expandable session rows and tool breakdown"
```

---

### Task 10: Projects Tab

**Files:**
- Modify: `ClaudeTray/Views/ProjectsTab.swift` (replace stub)

**Interfaces:**
- Consumes: `UsageStore.projects`, `ProjectSummary`, `ModelPricing.cost(for:Session)`, Swift Charts

- [ ] **Step 1: Replace ProjectsTab.swift**

```swift
import SwiftUI
import Charts

enum ProjectSort: String, CaseIterable {
    case cost = "Cost"; case sessions = "Sessions"; case recent = "Recent"
}

struct ProjectsTab: View {
    @Environment(UsageStore.self) private var store
    @State private var sortBy: ProjectSort = .cost
    @State private var expandedProject: String? = nil

    private var sorted: [ProjectSummary] {
        switch sortBy {
        case .cost:     return store.projects.sorted { projectCost($0) > projectCost($1) }
        case .sessions: return store.projects.sorted { $0.totalSessions > $1.totalSessions }
        case .recent:   return store.projects.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("Sort", selection: $sortBy) {
                ForEach(ProjectSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if sorted.isEmpty {
                ContentUnavailableView("No projects found", systemImage: "folder").frame(maxHeight: .infinity)
            } else {
                List(sorted) { project in
                    ProjectRow(project: project, isExpanded: expandedProject == project.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedProject = expandedProject == project.id ? nil : project.id
                            }
                        }
                }
                .listStyle(.plain)
            }
        }
    }

    private func projectCost(_ p: ProjectSummary) -> Double {
        p.sessions.compactMap { ModelPricing.cost(for: $0) }.reduce(0, +)
    }
}

private struct ProjectRow: View {
    let project: ProjectSummary
    let isExpanded: Bool

    private var totalCost: Double { project.sessions.compactMap { ModelPricing.cost(for: $0) }.reduce(0, +) }
    private var costString: String {
        let hasMissing = project.sessions.contains { ModelPricing.cost(for: $0) == nil }
        if hasMissing && totalCost == 0 { return "—" }
        return String(format: "$%.2f", totalCost)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.system(.body, design: .monospaced)).fontWeight(.medium)
                    if let last = project.lastActive {
                        Text("Last active \(last.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(costString).font(.caption.monospacedDigit().weight(.semibold))
                    Text("\(project.totalSessions) sessions").font(.caption2).foregroundStyle(.secondary)
                }
            }

            if isExpanded {
                Divider()
                let monthly = monthlyCostBuckets(project)
                if monthly.count > 1 {
                    Chart(monthly, id: \.date) { item in
                        BarMark(x: .value("Month", item.date, unit: .month), y: .value("Cost", item.cost))
                            .foregroundStyle(.blue)
                    }
                    .frame(height: 60)
                }
                let breakdown = modelBreakdown(project)
                if !breakdown.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model Mix").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(breakdown, id: \.model) { item in
                            HStack {
                                Text(item.model).font(.caption)
                                Spacer()
                                Text("\(item.tokens.formatted()) tokens")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func monthlyCostBuckets(_ project: ProjectSummary) -> [(date: Date, cost: Double)] {
        let cal = Calendar.current
        var map: [Date: Double] = [:]
        for session in project.sessions {
            guard let cost = ModelPricing.cost(for: session) else { continue }
            let month = cal.date(from: cal.dateComponents([.year, .month], from: session.startTime))!
            map[month, default: 0] += cost
        }
        return map.map { (date: $0.key, cost: $0.value) }.sorted { $0.date < $1.date }
    }

    private func modelBreakdown(_ project: ProjectSummary) -> [(model: String, tokens: Int)] {
        var counts: [String: Int] = [:]
        for session in project.sessions {
            for (model, tc) in session.modelBreakdown {
                counts[model, default: 0] += tc.input + tc.output
            }
        }
        return counts.map { (model: $0.key, tokens: $0.value) }.sorted { $0.tokens > $1.tokens }
    }
}
```

- [ ] **Step 2: Build and run, verify sort toggles and expansion**

- [ ] **Step 3: Commit**

```bash
git add ClaudeTray/Views/ProjectsTab.swift
git commit -m "feat: projects tab with sort, cost rollup, and monthly sparklines"
```

---

### Task 11: Memory Tab

**Files:**
- Modify: `ClaudeTray/Views/MemoryTab.swift` (replace stub)

**Interfaces:**
- Consumes: `UsageStore.memoryEvents`, `MemoryEvent`, `MemoryOperation`, `StatCard`, Swift Charts

- [ ] **Step 1: Replace MemoryTab.swift**

```swift
import SwiftUI
import Charts

struct MemoryTab: View {
    @Environment(UsageStore.self) private var store

    private var events: [MemoryEvent] { store.memoryEvents }
    private var totalWrites: Int { events.filter { $0.operation == .write || $0.operation == .create }.count }
    private var totalReads: Int { events.filter { $0.operation == .read }.count }
    private var totalCreates: Int { events.filter { $0.operation == .create }.count }

    private var perProjectCounts: [(project: String, count: Int)] {
        Dictionary(grouping: events, by: \.projectPath)
            .map { (project: URL(fileURLWithPath: $0.key).lastPathComponent, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    private var topReadFiles: [(file: String, count: Int)] {
        Dictionary(grouping: events.filter { $0.operation == .read }, by: \.memoryFilePath)
            .map { (file: URL(fileURLWithPath: $0.key).lastPathComponent, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(10).map { $0 }
    }

    private var topWriteFiles: [(file: String, count: Int)] {
        Dictionary(grouping: events.filter { $0.operation == .write || $0.operation == .create }, by: \.memoryFilePath)
            .map { (file: URL(fileURLWithPath: $0.key).lastPathComponent, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(10).map { $0 }
    }

    private var growthBuckets: [(date: Date, cumulative: Int)] {
        let creates = events.filter { $0.operation == .create }.sorted { $0.timestamp < $1.timestamp }
        return creates.enumerated().map { (date: $0.element.timestamp, cumulative: $0.offset + 1) }
    }

    var body: some View {
        ScrollView {
            if events.isEmpty {
                ContentUnavailableView("No memory activity", systemImage: "brain")
                    .frame(maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                        StatCard(title: "Reads", value: "\(totalReads)")
                        StatCard(title: "Writes", value: "\(totalWrites)")
                        StatCard(title: "Created", value: "\(totalCreates)")
                    }

                    if growthBuckets.count > 1 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Memory File Growth").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Chart(growthBuckets, id: \.date) { item in
                                LineMark(x: .value("Date", item.date), y: .value("Files", item.cumulative))
                                    .interpolationMethod(.stepEnd)
                                AreaMark(x: .value("Date", item.date), y: .value("Files", item.cumulative))
                                    .foregroundStyle(.purple.opacity(0.15)).interpolationMethod(.stepEnd)
                            }
                            .frame(height: 100)
                        }
                    }

                    if !perProjectCounts.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("By Project").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(perProjectCounts, id: \.project) { item in
                                HStack {
                                    Text(item.project).font(.caption.monospaced())
                                    Spacer()
                                    Text("\(item.count) events").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if !topReadFiles.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Most Read").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(topReadFiles, id: \.file) { item in
                                HStack {
                                    Text(item.file).font(.caption.monospaced()).lineLimit(1)
                                    Spacer()
                                    Text("\(item.count)×").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if !topWriteFiles.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Most Written").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(topWriteFiles, id: \.file) { item in
                                HStack {
                                    Text(item.file).font(.caption.monospaced()).lineLimit(1)
                                    Spacer()
                                    Text("\(item.count)×").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }
}
```

- [ ] **Step 2: Build and run, verify Memory tab**

- [ ] **Step 3: Commit**

```bash
git add ClaudeTray/Views/MemoryTab.swift
git commit -m "feat: memory tab with growth chart, per-project counts, top read/write files"
```

---

### Task 12: Final Integration Pass

- [ ] **Step 1: Full build**

Cmd+B. Zero errors, zero warnings.

- [ ] **Step 2: Run full test suite**

Cmd+U. All tests pass.

- [ ] **Step 3: Manual test checklist**

- [ ] Open popover — all 5 tabs appear with correct icons
- [ ] Overview tab: change period selector, stats update
- [ ] Charts tab: stacked model chart, cost line, input/output pie all render (or empty state if no data)
- [ ] Conversations tab: sessions list; tap to expand shows tool calls and model split
- [ ] Projects tab: sort by Cost / Sessions / Recent works; expand shows monthly sparkline
- [ ] Memory tab: stats show if memory events exist in `~/.claude/projects/`; empty state if not
- [ ] Menu bar icon shows today's cost (e.g. `$0.42`) or session count
- [ ] Close popover (click outside), reopen — no crash
- [ ] Wait 30 seconds — verify no crash, silent poll fires

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "feat: complete Claude Mac Tray analytics app"
```
