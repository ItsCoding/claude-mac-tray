# Usage Limits & Timing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Session (5-hour) and Weekly (7-day) usage progress bars plus an API/wall-time readout to the menu-bar popover, fed by Claude Code's statusline payload captured via an installed wrapper script.

**Architecture:** A statusline wrapper writes each Claude Code statusline payload to a per-session JSON snapshot. `SnapshotStore` reads those snapshots; `LimitsModel` turns them (plus existing message-cost data) into two progress bars and a timing readout, auto-selecting **Anthropic mode** (real `rate_limits`) or **Bedrock mode** (USD cost ÷ configurable budget). New SwiftUI views render the bars and a settings popover; `UsageStore` exposes everything.

**Tech Stack:** Swift 5, SwiftUI, `@Observable`/`@MainActor`, XCTest, `JSONSerialization`, `UserDefaults`. macOS app, no external dependencies.

## Global Constraints

- Target platform: macOS 14+ (`MACOSX_DEPLOYMENT_TARGET = 14.0`); macOS 26-only APIs must stay behind `if #available(macOS 26.0, *)`.
- No new third-party dependencies. Wrapper script must be POSIX `sh` using only tools shipped with macOS (`sed`, `cat`, `mkdir`, `mv`) — **no `jq`, no `python3`**.
- Real `rate_limits` data only exists for Claude.ai Pro/Max accounts; on Bedrock/API-key it is always absent. Code must never assume it is present.
- The app runs outside Claude Code and cannot read its stdin; the only capture path is the installed statusline wrapper writing snapshot files.
- Follow existing code conventions: doc-comments on non-obvious types, `@Observable @MainActor` store, shared `glassCard`/`ModelStyle` styling, `JSONSerialization` (not `Codable`) for resilient external-JSON parsing, matching the existing `JSONLParser`/`UsageStore` style.
- Budgets are USD. Default weekly budget `$50`, default session budget `$10`. A budget `<= 0` means "unset": show raw cost with no fraction fill.
- Snapshot directory: `~/Library/Application Support/ClaudeTry/snapshots/`. Active window: 300s. Retention (prune older): 24h.
- Mode detection is automatic from snapshot contents; no manual toggle in v1.

---

## File Structure

```
ClaudeTry/ClaudeTry/
├── Data/
│   ├── UsageSnapshot.swift        # NEW: snapshot value type + decode
│   ├── SnapshotStore.swift        # NEW: read/decode/prune snapshot dir
│   ├── AppConfig.swift            # NEW: UserDefaults-backed budgets + statusline backup
│   ├── TimeFormat.swift           # NEW: duration + reset-countdown formatting
│   ├── LimitsModel.swift          # NEW: mode detection, BarState, timing
│   ├── StatuslineInstaller.swift  # NEW: settings.json edit + embedded wrapper script
│   └── UsageStore.swift           # CHANGED: own SnapshotStore + AppConfig, expose `limits`
├── Views/
│   ├── LimitsSection.swift        # NEW: bars + timing view (compact + full)
│   ├── SettingsView.swift         # NEW: budgets + install/uninstall
│   └── DashboardView.swift        # CHANGED: gear button + LimitsSection in both layouts
ClaudeTry/ClaudeTryTests/
│   ├── UsageSnapshotTests.swift   # NEW
│   ├── SnapshotStoreTests.swift   # NEW
│   ├── AppConfigTests.swift       # NEW
│   ├── TimeFormatTests.swift      # NEW
│   ├── LimitsModelTests.swift     # NEW
│   └── StatuslineInstallerTests.swift # NEW
ClaudeTry/ClaudeTry.xcodeproj/
│   ├── project.pbxproj            # CHANGED: add ClaudeTryTests unit-test target
│   └── xcshareddata/xcschemes/ClaudeTry.xcscheme # NEW: shared scheme with test action
```

New `.swift` files in `ClaudeTry/ClaudeTry/**` and `ClaudeTry/ClaudeTryTests/**` are picked up automatically by the project's `PBXFileSystemSynchronizedRootGroup`s — **no further `project.pbxproj` edits are needed after Task 0.**

---

## Task 0: Add a working XCTest target

The `ClaudeTryTests/*.swift` files exist on disk but are wired into no target; `xcodebuild test` currently errors with "Scheme ClaudeTry is not currently configured for the test action." This task adds a unit-test target and a shared scheme so the rest of the plan is true TDD.

**Files:**
- Modify: `ClaudeTry/ClaudeTry.xcodeproj/project.pbxproj`
- Create: `ClaudeTry/ClaudeTry.xcodeproj/xcshareddata/xcschemes/ClaudeTry.xcscheme`

**Interfaces:**
- Consumes: nothing.
- Produces: a runnable `xcodebuild test -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -destination 'platform=macOS'` command used by every later task.

- [ ] **Step 1: Confirm the current failure**

Run: `xcodebuild test -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -destination 'platform=macOS' 2>&1 | tail -3`
Expected: `error: Scheme ClaudeTry is not currently configured for the test action.`

- [ ] **Step 2: Add the test target's product reference**

In `project.pbxproj`, in the `PBXFileReference` section (between the `ClaudeTry.app` line and `/* End PBXFileReference section */`), add:

```
		AB00000000000000000001 /* ClaudeTryTests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = ClaudeTryTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
```

- [ ] **Step 3: Add the synchronized group for the tests folder**

In the `PBXFileSystemSynchronizedRootGroup` section (after the existing `ClaudeTry` group, before `/* End ... */`), add:

```
		AB00000000000000000002 /* ClaudeTryTests */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = ClaudeTryTests;
			sourceTree = "<group>";
		};
```

- [ ] **Step 4: Reference the new group and product in the project groups**

In the main group (`FA0482EA2FE6160E003401AC`), change its `children` from:

```
			children = (
				FA0482F52FE6160E003401AC /* ClaudeTry */,
				FA0482F42FE6160E003401AC /* Products */,
			);
```

to:

```
			children = (
				FA0482F52FE6160E003401AC /* ClaudeTry */,
				AB00000000000000000002 /* ClaudeTryTests */,
				FA0482F42FE6160E003401AC /* Products */,
			);
```

In the Products group (`FA0482F42FE6160E003401AC`), change its `children` from:

```
			children = (
				FA0482F32FE6160E003401AC /* ClaudeTry.app */,
			);
```

to:

```
			children = (
				FA0482F32FE6160E003401AC /* ClaudeTry.app */,
				AB00000000000000000001 /* ClaudeTryTests.xctest */,
			);
```

- [ ] **Step 5: Add the test native target**

In the `PBXNativeTarget` section, after the `ClaudeTry` target's closing `};` and before `/* End PBXNativeTarget section */`, add:

```
		AB00000000000000000003 /* ClaudeTryTests */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = AB00000000000000000007 /* Build configuration list for PBXNativeTarget "ClaudeTryTests" */;
			buildPhases = (
				AB00000000000000000004 /* Sources */,
				AB00000000000000000005 /* Frameworks */,
				AB00000000000000000006 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
				AB0000000000000000000A /* PBXTargetDependency */,
			);
			fileSystemSynchronizedGroups = (
				AB00000000000000000002 /* ClaudeTryTests */,
			);
			name = ClaudeTryTests;
			packageProductDependencies = (
			);
			productName = ClaudeTryTests;
			productReference = AB00000000000000000001 /* ClaudeTryTests.xctest */;
			productType = "com.apple.product-type.bundle.unit-test";
		};
```

- [ ] **Step 6: Register the target and its attributes on the project**

In the `PBXProject` object, change `TargetAttributes` from:

```
				TargetAttributes = {
					FA0482F22FE6160E003401AC = {
						CreatedOnToolsVersion = 26.5;
					};
				};
```

to:

```
				TargetAttributes = {
					FA0482F22FE6160E003401AC = {
						CreatedOnToolsVersion = 26.5;
					};
					AB00000000000000000003 = {
						CreatedOnToolsVersion = 26.5;
						TestTargetID = FA0482F22FE6160E003401AC;
					};
				};
```

And change the project `targets` list from:

```
			targets = (
				FA0482F22FE6160E003401AC /* ClaudeTry */,
			);
```

to:

```
			targets = (
				FA0482F22FE6160E003401AC /* ClaudeTry */,
				AB00000000000000000003 /* ClaudeTryTests */,
			);
```

- [ ] **Step 7: Add the test target's build phases**

In the `PBXResourcesBuildPhase` section, after the existing phase, add:

```
		AB00000000000000000006 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
```

In the `PBXSourcesBuildPhase` section, after the existing phase, add:

```
		AB00000000000000000004 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
```

In the `PBXFrameworksBuildPhase` section, after the existing phase, add:

```
		AB00000000000000000005 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
```

- [ ] **Step 8: Add the target dependency proxy sections**

The project has no `PBXContainerItemProxy` or `PBXTargetDependency` sections yet. Add both as new sections immediately before `/* Begin PBXFileReference section */`:

```
/* Begin PBXContainerItemProxy section */
		AB0000000000000000000B /* PBXContainerItemProxy */ = {
			isa = PBXContainerItemProxy;
			containerPortal = FA0482EB2FE6160E003401AC /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = FA0482F22FE6160E003401AC;
			remoteInfo = ClaudeTry;
		};
/* End PBXContainerItemProxy section */

/* Begin PBXTargetDependency section */
		AB0000000000000000000A /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			target = FA0482F22FE6160E003401AC /* ClaudeTry */;
			targetProxy = AB0000000000000000000B /* PBXContainerItemProxy */;
		};
/* End PBXTargetDependency section */

```

- [ ] **Step 9: Add the test target's build configurations**

In the `XCBuildConfiguration` section, after the last config (`FA0483002FE6160F003401AC /* Release */`) and before `/* End XCBuildConfiguration section */`, add:

```
		AB00000000000000000008 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				BUNDLE_LOADER = "$(TEST_HOST)";
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Manual;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				GENERATE_INFOPLIST_FILE = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = zone.trash.ClaudeTryTests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = NO;
				SWIFT_VERSION = 5.0;
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/ClaudeTry.app/Contents/MacOS/ClaudeTry";
			};
			name = Debug;
		};
		AB00000000000000000009 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				BUNDLE_LOADER = "$(TEST_HOST)";
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Manual;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				GENERATE_INFOPLIST_FILE = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = zone.trash.ClaudeTryTests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = NO;
				SWIFT_VERSION = 5.0;
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/ClaudeTry.app/Contents/MacOS/ClaudeTry";
			};
			name = Release;
		};
```

- [ ] **Step 10: Add the test target's configuration list**

In the `XCConfigurationList` section, after the last list and before `/* End XCConfigurationList section */`, add:

```
		AB00000000000000000007 /* Build configuration list for PBXNativeTarget "ClaudeTryTests" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				AB00000000000000000008 /* Debug */,
				AB00000000000000000009 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
```

- [ ] **Step 11: Create a shared scheme with a test action**

Create `ClaudeTry/ClaudeTry.xcodeproj/xcshareddata/xcschemes/ClaudeTry.xcscheme`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2650" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "FA0482F22FE6160E003401AC"
               BuildableName = "ClaudeTry.app"
               BlueprintName = "ClaudeTry"
               ReferencedContainer = "container:ClaudeTry.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "AB00000000000000000003"
               BuildableName = "ClaudeTryTests.xctest"
               BlueprintName = "ClaudeTryTests"
               ReferencedContainer = "container:ClaudeTry.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "FA0482F22FE6160E003401AC"
            BuildableName = "ClaudeTry.app"
            BlueprintName = "ClaudeTry"
            ReferencedContainer = "container:ClaudeTry.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
</Scheme>
```

- [ ] **Step 12: Verify the test target builds and runs**

Run: `xcodebuild test -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -destination 'platform=macOS' 2>&1 | tail -25`
Expected: the build succeeds and tests execute. `ModelTests` and `ModelPricingTests` (which use no bundled fixtures) PASS, confirming the target works. If the three `JSONLParserTests` that load `Fixtures/*.jsonl` fail with a missing-file error, that is a pre-existing fixture-bundling quirk unrelated to this feature — note it and continue; **no feature test in this plan depends on bundled fixtures** (they all build JSON inline). Do not block on it.

- [ ] **Step 13: Commit**

```bash
git add ClaudeTry/ClaudeTry.xcodeproj/project.pbxproj ClaudeTry/ClaudeTry.xcodeproj/xcshareddata
git commit -m "test: add ClaudeTryTests unit-test target and shared scheme"
```

---

## Task 1: UsageSnapshot value type + decode

**Files:**
- Create: `ClaudeTry/ClaudeTry/Data/UsageSnapshot.swift`
- Test: `ClaudeTry/ClaudeTryTests/UsageSnapshotTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct RateWindow { let usedPercentage: Double; let resetsAt: Date }`
  - `struct UsageSnapshot { let sessionID: String; let writtenAt: Date; let costUSD: Double?; let apiDurationMs: Int?; let wallDurationMs: Int?; let fiveHour: RateWindow?; let sevenDay: RateWindow? }`
  - `static func UsageSnapshot.decode(_ data: Data, writtenAt: Date) -> UsageSnapshot?` — returns `nil` when JSON is invalid or has no `session_id`.

- [ ] **Step 1: Write the failing tests**

Create `ClaudeTry/ClaudeTryTests/UsageSnapshotTests.swift`:

```swift
import XCTest
@testable import ClaudeTry

final class UsageSnapshotTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_000_000)

    func test_decode_fullPayloadWithRateLimits() throws {
        let json = """
        {"session_id":"abc","cost":{"total_cost_usd":0.5,"total_duration_ms":45000,"total_api_duration_ms":2300},
         "rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},
                        "seven_day":{"used_percentage":41.2,"resets_at":1738857600}}}
        """
        let snap = try XCTUnwrap(UsageSnapshot.decode(Data(json.utf8), writtenAt: when))
        XCTAssertEqual(snap.sessionID, "abc")
        XCTAssertEqual(snap.writtenAt, when)
        XCTAssertEqual(snap.costUSD, 0.5)
        XCTAssertEqual(snap.apiDurationMs, 2300)
        XCTAssertEqual(snap.wallDurationMs, 45000)
        XCTAssertEqual(snap.fiveHour?.usedPercentage, 23.5)
        XCTAssertEqual(snap.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1738425600))
        XCTAssertEqual(snap.sevenDay?.usedPercentage, 41.2)
    }

    func test_decode_bedrockPayloadHasNoRateLimits() throws {
        let json = """
        {"session_id":"xyz","cost":{"total_cost_usd":1.25,"total_duration_ms":1000,"total_api_duration_ms":500}}
        """
        let snap = try XCTUnwrap(UsageSnapshot.decode(Data(json.utf8), writtenAt: when))
        XCTAssertEqual(snap.sessionID, "xyz")
        XCTAssertEqual(snap.costUSD, 1.25)
        XCTAssertNil(snap.fiveHour)
        XCTAssertNil(snap.sevenDay)
    }

    func test_decode_malformedJSON_returnsNil() {
        XCTAssertNil(UsageSnapshot.decode(Data("not json".utf8), writtenAt: when))
    }

    func test_decode_missingSessionID_returnsNil() {
        XCTAssertNil(UsageSnapshot.decode(Data(#"{"cost":{"total_cost_usd":1}}"#.utf8), writtenAt: when))
    }

    func test_decode_missingCostFields_areNil() throws {
        let snap = try XCTUnwrap(UsageSnapshot.decode(Data(#"{"session_id":"s"}"#.utf8), writtenAt: when))
        XCTAssertNil(snap.costUSD)
        XCTAssertNil(snap.apiDurationMs)
        XCTAssertNil(snap.wallDurationMs)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -destination 'platform=macOS' -only-testing:ClaudeTryTests/UsageSnapshotTests 2>&1 | tail -20`
Expected: build fails — `cannot find 'UsageSnapshot' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ClaudeTry/ClaudeTry/Data/UsageSnapshot.swift`:

```swift
import Foundation

/// One Claude Code rate-limit window (Pro/Max only): how full it is and when it resets.
struct UsageSnapshot {
    let sessionID: String
    /// When the wrapper wrote this snapshot (the file's modification date).
    let writtenAt: Date
    let costUSD: Double?
    let apiDurationMs: Int?
    let wallDurationMs: Int?
    let fiveHour: RateWindow?
    let sevenDay: RateWindow?
}

struct RateWindow {
    let usedPercentage: Double
    let resetsAt: Date
}

extension UsageSnapshot {
    /// Decode one statusline stdin payload. `nil` if the JSON is unparseable or
    /// carries no `session_id`. Cost/timing/rate-limit fields are all optional —
    /// `rate_limits` is present only for Claude.ai subscribers.
    static func decode(_ data: Data, writtenAt: Date) -> UsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = root["session_id"] as? String, !sessionID.isEmpty
        else { return nil }

        let cost = root["cost"] as? [String: Any]
        let limits = root["rate_limits"] as? [String: Any]

        func window(_ key: String) -> RateWindow? {
            guard let w = limits?[key] as? [String: Any],
                  let pct = (w["used_percentage"] as? NSNumber)?.doubleValue,
                  let resets = (w["resets_at"] as? NSNumber)?.doubleValue
            else { return nil }
            return RateWindow(usedPercentage: pct, resetsAt: Date(timeIntervalSince1970: resets))
        }

        return UsageSnapshot(
            sessionID: sessionID,
            writtenAt: writtenAt,
            costUSD: (cost?["total_cost_usd"] as? NSNumber)?.doubleValue,
            apiDurationMs: (cost?["total_api_duration_ms"] as? NSNumber)?.intValue,
            wallDurationMs: (cost?["total_duration_ms"] as? NSNumber)?.intValue,
            fiveHour: window("five_hour"),
            sevenDay: window("seven_day")
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -destination 'platform=macOS' -only-testing:ClaudeTryTests/UsageSnapshotTests 2>&1 | tail -20`
Expected: all 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeTry/ClaudeTry/Data/UsageSnapshot.swift ClaudeTry/ClaudeTryTests/UsageSnapshotTests.swift
git commit -m "feat: UsageSnapshot decode from statusline payload"
```

---

## Task 2: SnapshotStore (read / decode / prune / active)

**Files:**
- Create: `ClaudeTry/ClaudeTry/Data/SnapshotStore.swift`
- Test: `ClaudeTry/ClaudeTryTests/SnapshotStoreTests.swift`

**Interfaces:**
- Consumes: `UsageSnapshot`, `RateWindow` (Task 1).
- Produces:
  - `final class SnapshotStore` with `init(directory: URL, activeWindow: TimeInterval = 300, retention: TimeInterval = 86_400, now: @escaping () -> Date = Date.init)`
  - `static func standard() -> SnapshotStore` (uses the App Support snapshots dir)
  - `static var snapshotsDirectory: URL`
  - `func reload()` — decode all `*.json` in the dir; delete files older than `retention`.
  - `private(set) var snapshots: [UsageSnapshot]`
  - `var active: [UsageSnapshot]` — `now() - writtenAt <= activeWindow`
  - `var freshest: UsageSnapshot?` — max `writtenAt`

- [ ] **Step 1: Write the failing tests**

Create `ClaudeTry/ClaudeTryTests/SnapshotStoreTests.swift`:

```swift
import XCTest
@testable import ClaudeTry

final class SnapshotStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snaptest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ json: String, ageSeconds: TimeInterval) throws {
        let url = dir.appendingPathComponent(name)
        try Data(json.utf8).write(to: url)
        let mtime = Date().addingTimeInterval(-ageSeconds)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    func test_reload_decodesAllValidSnapshots() throws {
        try write("a.json", #"{"session_id":"a","cost":{"total_cost_usd":1}}"#, ageSeconds: 10)
        try write("b.json", #"{"session_id":"b","cost":{"total_cost_usd":2}}"#, ageSeconds: 20)
        let store = SnapshotStore(directory: dir)
        store.reload()
        XCTAssertEqual(Set(store.snapshots.map(\.sessionID)), ["a", "b"])
    }

    func test_reload_skipsMalformedFiles() throws {
        try write("ok.json", #"{"session_id":"ok"}"#, ageSeconds: 10)
        try write("bad.json", "garbage", ageSeconds: 10)
        let store = SnapshotStore(directory: dir)
        store.reload()
        XCTAssertEqual(store.snapshots.map(\.sessionID), ["ok"])
    }

    func test_active_filtersByWindow() throws {
        try write("fresh.json", #"{"session_id":"fresh"}"#, ageSeconds: 60)
        try write("old.json", #"{"session_id":"old"}"#, ageSeconds: 600)
        let store = SnapshotStore(directory: dir, activeWindow: 300, retention: 86_400)
        store.reload()
        XCTAssertEqual(store.active.map(\.sessionID), ["fresh"])
    }

    func test_reload_prunesFilesOlderThanRetention() throws {
        try write("stale.json", #"{"session_id":"stale"}"#, ageSeconds: 100_000)
        try write("keep.json", #"{"session_id":"keep"}"#, ageSeconds: 100)
        let store = SnapshotStore(directory: dir, retention: 86_400)
        store.reload()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("stale.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("keep.json").path))
        XCTAssertEqual(store.snapshots.map(\.sessionID), ["keep"])
    }

    func test_freshest_returnsMostRecentlyWritten() throws {
        try write("old.json", #"{"session_id":"old"}"#, ageSeconds: 300)
        try write("new.json", #"{"session_id":"new"}"#, ageSeconds: 10)
        let store = SnapshotStore(directory: dir)
        store.reload()
        XCTAssertEqual(store.freshest?.sessionID, "new")
    }

    func test_reload_missingDirectory_isEmpty() {
        let store = SnapshotStore(directory: dir.appendingPathComponent("does-not-exist"))
        store.reload()
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertNil(store.freshest)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -destination 'platform=macOS' -only-testing:ClaudeTryTests/SnapshotStoreTests 2>&1 | tail -20`
Expected: build fails — `cannot find 'SnapshotStore' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ClaudeTry/ClaudeTry/Data/SnapshotStore.swift`:

```swift
import Foundation

/// Reads the per-session JSON snapshots written by the statusline wrapper.
/// Decodes them into `UsageSnapshot`s, prunes stale files, and exposes the
/// freshest snapshot (for mode/limit detection) and the active set (for timing).
final class SnapshotStore {
    private let directory: URL
    private let activeWindow: TimeInterval
    private let retention: TimeInterval
    private let now: () -> Date

    private(set) var snapshots: [UsageSnapshot] = []

    init(directory: URL,
         activeWindow: TimeInterval = 300,
         retention: TimeInterval = 86_400,
         now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.activeWindow = activeWindow
        self.retention = retention
        self.now = now
    }

    static var snapshotsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ClaudeTry/snapshots", isDirectory: true)
    }

    static func standard() -> SnapshotStore { SnapshotStore(directory: snapshotsDirectory) }

    func reload() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else {
            snapshots = []
            return
        }

        let cutoff = now().addingTimeInterval(-retention)
        var result: [UsageSnapshot] = []
        for url in urls where url.pathExtension == "json" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if mtime < cutoff {
                try? fm.removeItem(at: url)
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let snap = UsageSnapshot.decode(data, writtenAt: mtime) else { continue }
            result.append(snap)
        }
        snapshots = result
    }

    var active: [UsageSnapshot] {
        let cutoff = now().addingTimeInterval(-activeWindow)
        return snapshots.filter { $0.writtenAt >= cutoff }
    }

    var freshest: UsageSnapshot? {
        snapshots.max { $0.writtenAt < $1.writtenAt }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -destination 'platform=macOS' -only-testing:ClaudeTryTests/SnapshotStoreTests 2>&1 | tail -20`
Expected: all 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeTry/ClaudeTry/Data/SnapshotStore.swift ClaudeTry/ClaudeTryTests/SnapshotStoreTests.swift
git commit -m "feat: SnapshotStore reads, prunes, and surfaces usage snapshots"
```

---

## Task 3: AppConfig (budgets + statusline backup)

**Files:**
- Create: `ClaudeTry/ClaudeTry/Data/AppConfig.swift`
- Test: `ClaudeTry/ClaudeTryTests/AppConfigTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct Budgets: Equatable { var weeklyUSD: Double; var sessionUSD: Double }`
  - `final class AppConfig` with `init(defaults: UserDefaults = .standard)`
  - `var budgets: Budgets { get set }` — defaults `weeklyUSD = 50`, `sessionUSD = 10` when unset.
  - `var previousStatusLine: String? { get set }` — raw JSON of the statusLine block replaced at install, restored on uninstall.

- [ ] **Step 1: Write the failing tests**

Create `ClaudeTry/ClaudeTryTests/AppConfigTests.swift`:

```swift
import XCTest
@testable import ClaudeTry

final class AppConfigTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "appconfig-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func test_budgets_defaultsWhenUnset() {
        let cfg = AppConfig(defaults: freshDefaults())
        XCTAssertEqual(cfg.budgets, Budgets(weeklyUSD: 50, sessionUSD: 10))
    }

    func test_budgets_persistAndReadBack() {
        let d = freshDefaults()
        AppConfig(defaults: d).budgets = Budgets(weeklyUSD: 80, sessionUSD: 15)
        XCTAssertEqual(AppConfig(defaults: d).budgets, Budgets(weeklyUSD: 80, sessionUSD: 15))
    }

    func test_budgets_zeroIsPreserved() {
        let d = freshDefaults()
        AppConfig(defaults: d).budgets = Budgets(weeklyUSD: 0, sessionUSD: 0)
        XCTAssertEqual(AppConfig(defaults: d).budgets, Budgets(weeklyUSD: 0, sessionUSD: 0))
    }

    func test_previousStatusLine_roundTripsAndClears() {
        let d = freshDefaults()
        let cfg = AppConfig(defaults: d)
        XCTAssertNil(cfg.previousStatusLine)
        cfg.previousStatusLine = #"{"type":"command","command":"foo"}"#
        XCTAssertEqual(AppConfig(defaults: d).previousStatusLine, #"{"type":"command","command":"foo"}"#)
        cfg.previousStatusLine = nil
        XCTAssertNil(AppConfig(defaults: d).previousStatusLine)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -destination 'platform=macOS' -only-testing:ClaudeTryTests/AppConfigTests 2>&1 | tail -20`
Expected: build fails — `cannot find 'AppConfig' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ClaudeTry/ClaudeTry/Data/AppConfig.swift`:

```swift
import Foundation

/// USD budgets the Bedrock-mode bars fill toward. A value <= 0 means "unset".
struct Budgets: Equatable {
    var weeklyUSD: Double
    var sessionUSD: Double
}

/// `UserDefaults`-backed app settings: the configurable budgets and a backup of
/// any statusline command we replaced at install time (so uninstall can restore it).
final class AppConfig {
    private let defaults: UserDefaults
    private enum Key {
        static let weekly = "budget.weeklyUSD"
        static let session = "budget.sessionUSD"
        static let prevStatusLine = "statusline.previous"
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var budgets: Budgets {
        get {
            Budgets(
                weeklyUSD: defaults.object(forKey: Key.weekly) as? Double ?? 50,
                sessionUSD: defaults.object(forKey: Key.session) as? Double ?? 10
            )
        }
        set {
            defaults.set(newValue.weeklyUSD, forKey: Key.weekly)
            defaults.set(newValue.sessionUSD, forKey: Key.session)
        }
    }

    var previousStatusLine: String? {
        get { defaults.string(forKey: Key.prevStatusLine) }
        set {
            if let newValue { defaults.set(newValue, forKey: Key.prevStatusLine) }
            else { defaults.removeObject(forKey: Key.prevStatusLine) }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -destination 'platform=macOS' -only-testing:ClaudeTryTests/AppConfigTests 2>&1 | tail -20`
Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeTry/ClaudeTry/Data/AppConfig.swift ClaudeTry/ClaudeTryTests/AppConfigTests.swift
git commit -m "feat: AppConfig for budgets and statusline backup"
```

---

## Task 4: TimeFormat helpers (duration + reset countdown)

**Files:**
- Create: `ClaudeTry/ClaudeTry/Data/TimeFormat.swift`
- Test: `ClaudeTry/ClaudeTryTests/TimeFormatTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum TimeFormat`
  - `static func compactDuration(ms: Int) -> String` — `0 -> "0s"`, `78_000 -> "1m 18s"`, `1_860_000 -> "31m"`, `3_840_000 -> "1h 4m"`
  - `static func resetCountdown(to: Date, from: Date) -> String` — future → `"resets in 2h 14m"` / `"resets in 3d 4h"`; non-future → `"resetting…"`

- [ ] **Step 1: Write the failing tests**

Create `ClaudeTry/ClaudeTryTests/TimeFormatTests.swift`:

```swift
import XCTest
@testable import ClaudeTry

final class TimeFormatTests: XCTestCase {
    func test_compactDuration_secondsOnly() {
        XCTAssertEqual(TimeFormat.compactDuration(ms: 0), "0s")
        XCTAssertEqual(TimeFormat.compactDuration(ms: 45_000), "45s")
    }

    func test_compactDuration_minutesAndSeconds() {
        XCTAssertEqual(TimeFormat.compactDuration(ms: 78_000), "1m 18s")
    }

    func test_compactDuration_wholeMinutesDropSeconds() {
        XCTAssertEqual(TimeFormat.compactDuration(ms: 1_860_000), "31m")
    }

    func test_compactDuration_hoursAndMinutes() {
        XCTAssertEqual(TimeFormat.compactDuration(ms: 3_840_000), "1h 4m")
    }

    func test_resetCountdown_hoursAndMinutes() {
        let from = Date(timeIntervalSince1970: 0)
        let to = Date(timeIntervalSince1970: 2 * 3600 + 14 * 60)
        XCTAssertEqual(TimeFormat.resetCountdown(to: to, from: from), "resets in 2h 14m")
    }

    func test_resetCountdown_daysAndHours() {
        let from = Date(timeIntervalSince1970: 0)
        let to = Date(timeIntervalSince1970: 3 * 86_400 + 4 * 3600)
        XCTAssertEqual(TimeFormat.resetCountdown(to: to, from: from), "resets in 3d 4h")
    }

    func test_resetCountdown_pastIsResetting() {
        let from = Date(timeIntervalSince1970: 100)
        let to = Date(timeIntervalSince1970: 50)
        XCTAssertEqual(TimeFormat.resetCountdown(to: to, from: from), "resetting…")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -destination 'platform=macOS' -only-testing:ClaudeTryTests/TimeFormatTests 2>&1 | tail -20`
Expected: build fails — `cannot find 'TimeFormat' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ClaudeTry/ClaudeTry/Data/TimeFormat.swift`:

```swift
import Foundation

/// Compact, human time formatting for the limits UI. Pure functions (no locale
/// state) so they are deterministic and testable.
enum TimeFormat {
    /// "1h 4m", "31m", "1m 18s", "45s". Shows at most two units; drops the
    /// smaller unit once it is zero or once minutes are whole at/above an hour.
    static func compactDuration(ms: Int) -> String {
        let totalSeconds = max(0, ms / 1000)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return s > 0 ? "\(m)m \(s)s" : "\(m)m" }
        return "\(s)s"
    }

    /// "resets in 2h 14m" / "resets in 3d 4h"; "resetting…" when not in the future.
    static func resetCountdown(to date: Date, from now: Date) -> String {
        let remaining = Int(date.timeIntervalSince(now))
        guard remaining > 0 else { return "resetting…" }
        let d = remaining / 86_400
        let h = (remaining % 86_400) / 3600
        let m = (remaining % 3600) / 60
        if d > 0 { return "resets in \(d)d \(h)h" }
        return "resets in \(h)h \(m)m"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -destination 'platform=macOS' -only-testing:ClaudeTryTests/TimeFormatTests 2>&1 | tail -20`
Expected: all 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeTry/ClaudeTry/Data/TimeFormat.swift ClaudeTry/ClaudeTryTests/TimeFormatTests.swift
git commit -m "feat: TimeFormat duration and reset-countdown helpers"
```

---

## Task 5: LimitsModel (mode detection, bars, timing)

**Files:**
- Create: `ClaudeTry/ClaudeTry/Data/LimitsModel.swift`
- Test: `ClaudeTry/ClaudeTryTests/LimitsModelTests.swift`

**Interfaces:**
- Consumes: `UsageSnapshot`, `RateWindow` (Task 1), `Budgets` (Task 3), `TimeFormat` (Task 4).
- Produces:
  - `struct BarState: Equatable { let fraction: Double; let primaryLabel: String; let detailLabel: String?; let isReal: Bool }`
  - `struct TimingReadout: Equatable { let apiMs: Int; let wallMs: Int; let activeSessions: Int }`
  - `struct LimitsModel: Equatable { enum Mode { case anthropic, bedrock }; let mode: Mode; let session: BarState; let weekly: BarState; let timing: TimingReadout }`
  - `static func LimitsModel.make(freshest: UsageSnapshot?, active: [UsageSnapshot], sessionCostUSD: Double, weeklyCostUSD: Double, budgets: Budgets, now: Date) -> LimitsModel`

- [ ] **Step 1: Write the failing tests**

Create `ClaudeTry/ClaudeTryTests/LimitsModelTests.swift`:

```swift
import XCTest
@testable import ClaudeTry

final class LimitsModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func snap(five: RateWindow? = nil, seven: RateWindow? = nil,
                      api: Int? = nil, wall: Int? = nil, id: String = "s") -> UsageSnapshot {
        UsageSnapshot(sessionID: id, writtenAt: now, costUSD: nil,
                      apiDurationMs: api, wallDurationMs: wall, fiveHour: five, sevenDay: seven)
    }

    func test_anthropicMode_whenRateLimitsPresent() {
        let s = snap(five: RateWindow(usedPercentage: 23.5, resetsAt: now.addingTimeInterval(3600)),
                     seven: RateWindow(usedPercentage: 41, resetsAt: now.addingTimeInterval(86_400)))
        let m = LimitsModel.make(freshest: s, active: [s], sessionCostUSD: 0, weeklyCostUSD: 0,
                                 budgets: Budgets(weeklyUSD: 50, sessionUSD: 10), now: now)
        XCTAssertEqual(m.mode, .anthropic)
        XCTAssertEqual(m.session.fraction, 0.235, accuracy: 0.0001)
        XCTAssertEqual(m.session.primaryLabel, "24%")          // rounded
        XCTAssertTrue(m.session.isReal)
        XCTAssertEqual(m.session.detailLabel, "resets in 1h 0m")
    }

    func test_bedrockMode_whenNoRateLimits() {
        let s = snap()
        let m = LimitsModel.make(freshest: s, active: [s], sessionCostUSD: 4, weeklyCostUSD: 25,
                                 budgets: Budgets(weeklyUSD: 50, sessionUSD: 10), now: now)
        XCTAssertEqual(m.mode, .bedrock)
        XCTAssertEqual(m.session.fraction, 0.4, accuracy: 0.0001)
        XCTAssertEqual(m.session.primaryLabel, "$4.00 / $10")
        XCTAssertFalse(m.session.isReal)
        XCTAssertEqual(m.weekly.fraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(m.weekly.primaryLabel, "$25.00 / $50")
    }

    func test_noSnapshots_isBedrock() {
        let m = LimitsModel.make(freshest: nil, active: [], sessionCostUSD: 0, weeklyCostUSD: 0,
                                 budgets: Budgets(weeklyUSD: 50, sessionUSD: 10), now: now)
        XCTAssertEqual(m.mode, .bedrock)
    }

    func test_partialRateLimits_fallBackPerWindow() {
        // Only the 5-hour window is real; the 7-day window falls back to Bedrock.
        let s = snap(five: RateWindow(usedPercentage: 10, resetsAt: now.addingTimeInterval(600)))
        let m = LimitsModel.make(freshest: s, active: [s], sessionCostUSD: 1, weeklyCostUSD: 30,
                                 budgets: Budgets(weeklyUSD: 60, sessionUSD: 10), now: now)
        XCTAssertEqual(m.mode, .anthropic)
        XCTAssertTrue(m.session.isReal)
        XCTAssertFalse(m.weekly.isReal)
        XCTAssertEqual(m.weekly.fraction, 0.5, accuracy: 0.0001)
    }

    func test_budgetZero_showsRawCostNoFill() {
        let m = LimitsModel.make(freshest: snap(), active: [], sessionCostUSD: 7, weeklyCostUSD: 0,
                                 budgets: Budgets(weeklyUSD: 0, sessionUSD: 0), now: now)
        XCTAssertEqual(m.session.fraction, 0)
        XCTAssertEqual(m.session.primaryLabel, "$7.00")
    }

    func test_timing_sumsActiveSnapshots() {
        let a = snap(api: 1000, wall: 5000, id: "a")
        let b = snap(api: 2000, wall: 7000, id: "b")
        let m = LimitsModel.make(freshest: a, active: [a, b], sessionCostUSD: 0, weeklyCostUSD: 0,
                                 budgets: Budgets(weeklyUSD: 50, sessionUSD: 10), now: now)
        XCTAssertEqual(m.timing, TimingReadout(apiMs: 3000, wallMs: 12000, activeSessions: 2))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -destination 'platform=macOS' -only-testing:ClaudeTryTests/LimitsModelTests 2>&1 | tail -20`
Expected: build fails — `cannot find 'LimitsModel' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ClaudeTry/ClaudeTry/Data/LimitsModel.swift`:

```swift
import Foundation

/// One progress bar's resolved state. `fraction` drives the fill (0...1);
/// `isReal` is true only for genuine subscriber rate-limit data.
struct BarState: Equatable {
    let fraction: Double
    let primaryLabel: String
    let detailLabel: String?
    let isReal: Bool
}

/// API and wall time summed across the currently-active sessions.
struct TimingReadout: Equatable {
    let apiMs: Int
    let wallMs: Int
    let activeSessions: Int
}

/// The session (5-hour) and weekly (7-day) bars plus the timing readout.
/// Anthropic mode uses real `rate_limits`; Bedrock mode fills cost toward a budget.
struct LimitsModel: Equatable {
    enum Mode { case anthropic, bedrock }
    let mode: Mode
    let session: BarState
    let weekly: BarState
    let timing: TimingReadout

    static func make(freshest: UsageSnapshot?,
                     active: [UsageSnapshot],
                     sessionCostUSD: Double,
                     weeklyCostUSD: Double,
                     budgets: Budgets,
                     now: Date) -> LimitsModel {
        let mode: Mode = (freshest?.fiveHour != nil || freshest?.sevenDay != nil) ? .anthropic : .bedrock

        let session = bar(window: freshest?.fiveHour, costUSD: sessionCostUSD,
                          budgetUSD: budgets.sessionUSD, fallbackDetail: "5-hour window", now: now)
        let weekly = bar(window: freshest?.sevenDay, costUSD: weeklyCostUSD,
                         budgetUSD: budgets.weeklyUSD, fallbackDetail: "7-day window", now: now)

        let timing = TimingReadout(
            apiMs: active.reduce(0) { $0 + ($1.apiDurationMs ?? 0) },
            wallMs: active.reduce(0) { $0 + ($1.wallDurationMs ?? 0) },
            activeSessions: active.count
        )
        return LimitsModel(mode: mode, session: session, weekly: weekly, timing: timing)
    }

    /// Real bar from a rate window if present, else a Bedrock cost-vs-budget bar.
    private static func bar(window: RateWindow?, costUSD: Double, budgetUSD: Double,
                            fallbackDetail: String, now: Date) -> BarState {
        if let window {
            return BarState(
                fraction: min(1, max(0, window.usedPercentage / 100)),
                primaryLabel: "\(Int(window.usedPercentage.rounded()))%",
                detailLabel: TimeFormat.resetCountdown(to: window.resetsAt, from: now),
                isReal: true
            )
        }
        if budgetUSD > 0 {
            return BarState(
                fraction: min(1, max(0, costUSD / budgetUSD)),
                primaryLabel: String(format: "$%.2f / $%g", costUSD, budgetUSD),
                detailLabel: fallbackDetail,
                isReal: false
            )
        }
        return BarState(fraction: 0, primaryLabel: String(format: "$%.2f", costUSD),
                        detailLabel: fallbackDetail, isReal: false)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -destination 'platform=macOS' -only-testing:ClaudeTryTests/LimitsModelTests 2>&1 | tail -20`
Expected: all 6 tests PASS. (Note `$%g` renders `50.0` as `50` and `60.0` as `60`, matching the expected `$10` / `$50` / `$60` labels.)

- [ ] **Step 5: Commit**

```bash
git add ClaudeTry/ClaudeTry/Data/LimitsModel.swift ClaudeTry/ClaudeTryTests/LimitsModelTests.swift
git commit -m "feat: LimitsModel mode detection, bars, and timing"
```

---

## Task 6: StatuslineInstaller (settings.json edit + embedded wrapper script)

**Files:**
- Create: `ClaudeTry/ClaudeTry/Data/StatuslineInstaller.swift`
- Test: `ClaudeTry/ClaudeTryTests/StatuslineInstallerTests.swift`

**Interfaces:**
- Consumes: `AppConfig` (Task 3), `SnapshotStore.snapshotsDirectory` (Task 2).
- Produces:
  - `final class StatuslineInstaller` with `init(settingsURL: URL, scriptURL: URL, snapshotDir: URL, config: AppConfig)`
  - `static func standard() -> StatuslineInstaller`
  - `var isInstalled: Bool`
  - `func scriptContents(chainingTo previous: String?) -> String`
  - `func install() throws`
  - `func uninstall() throws`
  - `enum InstallError: Error { case settingsUnreadable }`

- [ ] **Step 1: Write the failing tests**

Create `ClaudeTry/ClaudeTryTests/StatuslineInstallerTests.swift`:

```swift
import XCTest
@testable import ClaudeTry

final class StatuslineInstallerTests: XCTestCase {
    private var dir: URL!
    private var settingsURL: URL!
    private var scriptURL: URL!
    private var snapDir: URL!
    private var config: AppConfig!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("inst-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settingsURL = dir.appendingPathComponent("settings.json")
        scriptURL = dir.appendingPathComponent("claude-tray-statusline.sh")
        snapDir = dir.appendingPathComponent("snapshots", isDirectory: true)
        config = AppConfig(defaults: UserDefaults(suiteName: "inst-\(UUID().uuidString)")!)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func installer() -> StatuslineInstaller {
        StatuslineInstaller(settingsURL: settingsURL, scriptURL: scriptURL, snapshotDir: snapDir, config: config)
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_scriptContents_embedsSnapshotDirAndPrior() {
        let s = installer().scriptContents(chainingTo: "my-prior --line")
        XCTAssertTrue(s.contains(snapDir.path))
        XCTAssertTrue(s.contains("my-prior --line"))
        XCTAssertTrue(s.contains("session_id"))
    }

    func test_install_writesScriptAndPointsSettingsAtIt() throws {
        try Data(#"{"model":"x"}"#.utf8).write(to: settingsURL)
        try installer().install()

        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptURL.path))
        let settings = try readSettings()
        XCTAssertEqual(settings["model"] as? String, "x")           // preserved
        let sl = try XCTUnwrap(settings["statusLine"] as? [String: Any])
        XCTAssertEqual(sl["type"] as? String, "command")
        XCTAssertEqual(sl["command"] as? String, scriptURL.path)
    }

    func test_install_recordsAndChainsPriorStatusLine() throws {
        try Data(#"{"statusLine":{"type":"command","command":"old-cmd"}}"#.utf8).write(to: settingsURL)
        try installer().install()

        XCTAssertNotNil(config.previousStatusLine)
        XCTAssertTrue(config.previousStatusLine!.contains("old-cmd"))
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(script.contains("old-cmd"))                   // chained
    }

    func test_isInstalled_reflectsState() throws {
        try Data("{}".utf8).write(to: settingsURL)
        let inst = installer()
        XCTAssertFalse(inst.isInstalled)
        try inst.install()
        XCTAssertTrue(inst.isInstalled)
    }

    func test_install_isIdempotent() throws {
        try Data(#"{"statusLine":{"type":"command","command":"old-cmd"}}"#.utf8).write(to: settingsURL)
        let inst = installer()
        try inst.install()
        try inst.install()                                          // second time: no double-chain
        XCTAssertEqual(config.previousStatusLine?.contains("old-cmd"), true)
        XCTAssertEqual(config.previousStatusLine?.contains(scriptURL.path), false)
    }

    func test_uninstall_restoresPriorAndRemovesScript() throws {
        try Data(#"{"statusLine":{"type":"command","command":"old-cmd"}}"#.utf8).write(to: settingsURL)
        let inst = installer()
        try inst.install()
        try inst.uninstall()

        let sl = try XCTUnwrap(try readSettings()["statusLine"] as? [String: Any])
        XCTAssertEqual(sl["command"] as? String, "old-cmd")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scriptURL.path))
        XCTAssertNil(config.previousStatusLine)
    }

    func test_uninstall_removesKeyWhenNoPrior() throws {
        try Data("{}".utf8).write(to: settingsURL)
        let inst = installer()
        try inst.install()
        try inst.uninstall()
        XCTAssertNil(try readSettings()["statusLine"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -destination 'platform=macOS' -only-testing:ClaudeTryTests/StatuslineInstallerTests 2>&1 | tail -20`
Expected: build fails — `cannot find 'StatuslineInstaller' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ClaudeTry/ClaudeTry/Data/StatuslineInstaller.swift`:

```swift
import Foundation

/// Installs a statusline wrapper as Claude Code's `statusLine.command` so the
/// menu-bar app can capture the usage payload. The wrapper writes a per-session
/// JSON snapshot and chains to whatever statusline was configured before, so it
/// composes with claude-hud or a user's own statusline rather than replacing it.
final class StatuslineInstaller {
    enum InstallError: Error { case settingsUnreadable }

    private let settingsURL: URL
    private let scriptURL: URL
    private let snapshotDir: URL
    private let config: AppConfig

    init(settingsURL: URL, scriptURL: URL, snapshotDir: URL, config: AppConfig) {
        self.settingsURL = settingsURL
        self.scriptURL = scriptURL
        self.snapshotDir = snapshotDir
        self.config = config
    }

    static func standard() -> StatuslineInstaller {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClaudeTry", isDirectory: true)
        return StatuslineInstaller(
            settingsURL: home.appendingPathComponent(".claude/settings.json"),
            scriptURL: appSupport.appendingPathComponent("claude-tray-statusline.sh"),
            snapshotDir: SnapshotStore.snapshotsDirectory,
            config: AppConfig()
        )
    }

    /// True when settings.json's statusLine command already points at our script.
    var isInstalled: Bool {
        guard let dict = readSettings(),
              let sl = dict["statusLine"] as? [String: Any],
              let cmd = sl["command"] as? String else { return false }
        return cmd == scriptURL.path
    }

    /// The POSIX `sh` wrapper. Writes the payload to `<snapshotDir>/<session_id>.json`
    /// (atomic temp + rename), then chains to `previous` if given, else prints a
    /// minimal `[model]` line so the statusline is never blank.
    func scriptContents(chainingTo previous: String?) -> String {
        let prior = (previous ?? "").replacingOccurrences(of: "'", with: "'\\''")
        return """
        #!/bin/sh
        # ClaudeTry statusline wrapper — captures usage payload, then chains.
        SNAP_DIR='\(snapshotDir.path)'
        mkdir -p "$SNAP_DIR"
        input=$(cat)
        sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
        [ -z "$sid" ] && sid="unknown"
        tmp="$SNAP_DIR/.$sid.tmp"
        printf '%s' "$input" > "$tmp" && mv "$tmp" "$SNAP_DIR/$sid.json"
        PRIOR='\(prior)'
        if [ -n "$PRIOR" ]; then
          printf '%s' "$input" | sh -c "$PRIOR"
        else
          printf '%s' "$input" | sed -n 's/.*"display_name"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/[\\1]/p'
        fi
        """
    }

    func install() throws {
        guard var dict = readSettings() else { throw InstallError.settingsUnreadable }

        // Capture the prior statusLine for chaining + restore, unless we're already installed.
        var priorCommand: String? = nil
        if let sl = dict["statusLine"] as? [String: Any], (sl["command"] as? String) != scriptURL.path {
            priorCommand = sl["command"] as? String
            if let data = try? JSONSerialization.data(withJSONObject: sl),
               let json = String(data: data, encoding: .utf8) {
                config.previousStatusLine = json
            }
        } else if let saved = config.previousStatusLine,
                  let obj = try? JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any] {
            priorCommand = obj["command"] as? String  // re-install: reuse the saved prior
        }

        // Write the wrapper script (executable) and point settings.json at it.
        try FileManager.default.createDirectory(at: scriptURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try scriptContents(chainingTo: priorCommand).write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        dict["statusLine"] = ["type": "command", "command": scriptURL.path]
        try writeSettings(dict)
    }

    func uninstall() throws {
        guard var dict = readSettings() else { throw InstallError.settingsUnreadable }
        if let saved = config.previousStatusLine,
           let obj = try? JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any] {
            dict["statusLine"] = obj
        } else {
            dict.removeValue(forKey: "statusLine")
        }
        try writeSettings(dict)
        config.previousStatusLine = nil
        try? FileManager.default.removeItem(at: scriptURL)
    }

    private func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict
    }

    private func writeSettings(_ dict: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dict,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -destination 'platform=macOS' -only-testing:ClaudeTryTests/StatuslineInstallerTests 2>&1 | tail -20`
Expected: all 8 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeTry/ClaudeTry/Data/StatuslineInstaller.swift ClaudeTry/ClaudeTryTests/StatuslineInstallerTests.swift
git commit -m "feat: StatuslineInstaller writes wrapper and edits settings.json"
```

---

## Task 7: Wire snapshots + limits into UsageStore

**Files:**
- Modify: `ClaudeTry/ClaudeTry/Data/UsageStore.swift`
- Test: `ClaudeTry/ClaudeTryTests/UsageStoreTests.swift` (add cases)

**Interfaces:**
- Consumes: `SnapshotStore` (Task 2), `AppConfig`/`Budgets` (Task 3), `LimitsModel` (Task 5), existing `totalCost(in:)`.
- Produces (on `UsageStore`):
  - `init(snapshots: SnapshotStore = .standard(), config: AppConfig = AppConfig())`
  - `var limits: LimitsModel { get }` — built from `snapshots.freshest/active`, `totalCost` over the last 5h/7d, and `config.budgets`.
  - `refreshAsync()` additionally calls `snapshots.reload()`.

- [ ] **Step 1: Write the failing tests**

Add to `ClaudeTry/ClaudeTryTests/UsageStoreTests.swift` (inside the class):

```swift
    @MainActor func test_limits_bedrockMode_whenNoSnapshots() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("us-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = UsageStore(snapshots: SnapshotStore(directory: dir),
                               config: AppConfig(defaults: UserDefaults(suiteName: "us-\(UUID().uuidString)")!))
        store.sessions = makeSessions()
        XCTAssertEqual(store.limits.mode, .bedrock)
        // Session bar reflects the last-5h cost vs the $10 session budget; today's
        // sessions exist, so cost is >= 0 and the label is dollar-formatted.
        XCTAssertTrue(store.limits.session.primaryLabel.hasPrefix("$"))
    }

    @MainActor func test_limits_anthropicMode_whenSnapshotHasRateLimits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("us-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"{"session_id":"s","rate_limits":{"five_hour":{"used_percentage":50,"resets_at":4000000000},"seven_day":{"used_percentage":20,"resets_at":4000000000}}}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("s.json"))

        let store = UsageStore(snapshots: SnapshotStore(directory: dir),
                               config: AppConfig(defaults: UserDefaults(suiteName: "us-\(UUID().uuidString)")!))
        store.sessions = makeSessions()
        XCTAssertEqual(store.limits.mode, .anthropic)
        XCTAssertEqual(store.limits.session.fraction, 0.5, accuracy: 0.0001)
        XCTAssertTrue(store.limits.session.isReal)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -destination 'platform=macOS' -only-testing:ClaudeTryTests/UsageStoreTests 2>&1 | tail -20`
Expected: build fails — `UsageStore` has no `init(snapshots:config:)` / no member `limits`.

- [ ] **Step 3: Write the implementation**

In `ClaudeTry/ClaudeTry/Data/UsageStore.swift`, replace the property/init region. Change:

```swift
@Observable
@MainActor
final class UsageStore {
    var sessions: [Session] = []
    private var timer: Timer?
    private let parser = JSONLParser()
```

to:

```swift
@Observable
@MainActor
final class UsageStore {
    var sessions: [Session] = []
    private var timer: Timer?
    private let parser = JSONLParser()
    private let snapshots: SnapshotStore
    private let config: AppConfig

    init(snapshots: SnapshotStore = .standard(), config: AppConfig = AppConfig()) {
        self.snapshots = snapshots
        self.config = config
    }

    /// Session (5h) + weekly (7d) limit bars and the API/wall-time readout.
    /// Anthropic mode when snapshots carry real `rate_limits`, else Bedrock budgets.
    var limits: LimitsModel {
        let now = Date()
        let cal = Calendar.current
        let fiveHourAgo = now.addingTimeInterval(-5 * 3600)
        let sevenDaysAgo = cal.date(byAdding: .day, value: -7, to: now) ?? now.addingTimeInterval(-7 * 86_400)
        let sessionCost = totalCost(in: DateInterval(start: fiveHourAgo, end: now.addingTimeInterval(60))) ?? 0
        let weeklyCost = totalCost(in: DateInterval(start: sevenDaysAgo, end: now.addingTimeInterval(60))) ?? 0
        return LimitsModel.make(
            freshest: snapshots.freshest, active: snapshots.active,
            sessionCostUSD: sessionCost, weeklyCostUSD: weeklyCost,
            budgets: config.budgets, now: now
        )
    }
```

Then in `refreshAsync()`, add a snapshot reload at the end. Change:

```swift
    private func refreshAsync() async {
        let rootURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let result = await parser.scan(rootURL: rootURL)
        sessions = result.sessions.sorted { $0.startTime > $1.startTime }
    }
```

to:

```swift
    private func refreshAsync() async {
        let rootURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let result = await parser.scan(rootURL: rootURL)
        sessions = result.sessions.sorted { $0.startTime > $1.startTime }
        snapshots.reload()
    }
```

(Note: `UsageStore()` with no arguments still works for existing call sites because both init parameters have defaults.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -destination 'platform=macOS' -only-testing:ClaudeTryTests/UsageStoreTests 2>&1 | tail -20`
Expected: all `UsageStoreTests` (existing 4 + new 2) PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeTry/ClaudeTry/Data/UsageStore.swift ClaudeTry/ClaudeTryTests/UsageStoreTests.swift
git commit -m "feat: expose LimitsModel from UsageStore via SnapshotStore"
```

---

## Task 8: LimitsSection view (bars + timing)

**Files:**
- Create: `ClaudeTry/ClaudeTry/Views/LimitsSection.swift`

**Interfaces:**
- Consumes: `LimitsModel`, `BarState`, `TimingReadout` (Task 5), `TimeFormat` (Task 4), `glassCard` (existing `ChartStyle.swift`).
- Produces:
  - `struct LimitsSection: View { let limits: LimitsModel; var compact: Bool; var onConnect: () -> Void; var showConnectPrompt: Bool }`
  - `static func LimitsSection.barColor(for fraction: Double) -> Color` — `<0.75` indigo, `<0.9` orange (amber), else red.

This view has no unit test (SwiftUI rendering); it is verified by build + manual run in Task 10. Keep all logic in the already-tested `LimitsModel`/`TimeFormat`.

- [ ] **Step 1: Write the implementation**

Create `ClaudeTry/ClaudeTry/Views/LimitsSection.swift`:

```swift
import SwiftUI

/// Session (5h) + weekly (7d) usage bars and an API/wall-time line. Shown in both
/// the minimal and expanded dashboard layouts. When the statusline integration
/// isn't installed, shows a slim "connect" prompt instead.
struct LimitsSection: View {
    let limits: LimitsModel
    var compact: Bool = false
    var showConnectPrompt: Bool = false
    var onConnect: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            if showConnectPrompt {
                connectPrompt
            } else {
                LimitBar(title: "Session · 5h", bar: limits.session)
                LimitBar(title: "Weekly · 7d", bar: limits.weekly)
                timingLine
            }
        }
        .padding(compact ? 12 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: compact ? 14 : 16)
    }

    private var timingLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer").font(.caption2).foregroundStyle(.secondary)
            if limits.timing.activeSessions == 0 {
                Text("No active sessions").font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("API \(TimeFormat.compactDuration(ms: limits.timing.apiMs)) · Wall \(TimeFormat.compactDuration(ms: limits.timing.wallMs))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(limits.timing.activeSessions) active").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var connectPrompt: some View {
        Button(action: onConnect) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.horizontal.circle")
                Text("Connect live usage").font(.caption.weight(.medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2)
            }
            .foregroundStyle(.indigo)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func barColor(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.75: return .indigo
        case ..<0.9:  return .orange
        default:      return .red
        }
    }
}

/// One labelled progress bar with a primary value and an optional caption.
private struct LimitBar: View {
    let title: String
    let bar: BarState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text(bar.primaryLabel).font(.caption.monospacedDigit().weight(.semibold))
                    .contentTransition(.numericText())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.15))
                    Capsule().fill(LimitsSection.barColor(for: bar.fraction).gradient)
                        .frame(width: max(4, geo.size.width * bar.fraction))
                }
            }
            .frame(height: 8)
            if let detail = bar.detailLabel {
                Text(detail).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `xcodebuild build -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -destination 'platform=macOS' -configuration Debug 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add ClaudeTry/ClaudeTry/Views/LimitsSection.swift
git commit -m "feat: LimitsSection view with usage bars and timing"
```

---

## Task 9: SettingsView + gear button plumbing

**Files:**
- Create: `ClaudeTry/ClaudeTry/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `AppConfig`/`Budgets` (Task 3), `StatuslineInstaller` (Task 6).
- Produces:
  - `struct SettingsView: View { init(config: AppConfig = AppConfig(), installer: StatuslineInstaller = .standard()) }`

No unit test (SwiftUI + filesystem side effects); verified by build + manual run in Task 10.

- [ ] **Step 1: Write the implementation**

Create `ClaudeTry/ClaudeTry/Views/SettingsView.swift`:

```swift
import SwiftUI

/// Budgets + statusline integration. Presented from the dashboard header gear.
struct SettingsView: View {
    private let config: AppConfig
    private let installer: StatuslineInstaller

    @State private var weekly: Double
    @State private var session: Double
    @State private var installed: Bool
    @State private var errorText: String?

    init(config: AppConfig = AppConfig(), installer: StatuslineInstaller = .standard()) {
        self.config = config
        self.installer = installer
        let b = config.budgets
        _weekly = State(initialValue: b.weeklyUSD)
        _session = State(initialValue: b.sessionUSD)
        _installed = State(initialValue: installer.isInstalled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Budgets (Bedrock mode)").font(.subheadline.weight(.semibold))
                budgetField("Weekly budget", value: $weekly)
                budgetField("Session budget (5h)", value: $session)
                Text("Used when no Claude.ai rate-limit data is available.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Live usage integration").font(.subheadline.weight(.semibold))
                Text(installed ? "Installed — capturing usage from Claude Code's statusline."
                               : "Not installed. Captures live usage and chains to any existing statusline.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button(installed ? "Uninstall" : "Install statusline integration") {
                    toggleInstall()
                }
                .controlSize(.small)
                if let errorText {
                    Text(errorText).font(.caption2).foregroundStyle(.red)
                }
            }
        }
        .padding(18)
        .frame(width: 320)
    }

    private func budgetField(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 80).multilineTextAlignment(.trailing)
                .onChange(of: value.wrappedValue) { _, _ in
                    config.budgets = Budgets(weeklyUSD: weekly, sessionUSD: session)
                }
            Stepper("", value: value, in: 0...100_000, step: 5).labelsHidden()
        }
    }

    private func toggleInstall() {
        errorText = nil
        do {
            if installed { try installer.uninstall() } else { try installer.install() }
            installed = installer.isInstalled
        } catch {
            errorText = "Could not update ~/.claude/settings.json."
        }
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `xcodebuild build -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -destination 'platform=macOS' -configuration Debug 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add ClaudeTry/ClaudeTry/Views/SettingsView.swift
git commit -m "feat: SettingsView for budgets and statusline install"
```

---

## Task 10: Integrate into DashboardView (both layouts) + verify

**Files:**
- Modify: `ClaudeTry/ClaudeTry/Views/DashboardView.swift`

**Interfaces:**
- Consumes: `LimitsSection` (Task 8), `SettingsView` (Task 9), `store.limits` (Task 7), `StatuslineInstaller` (Task 6).
- Produces: the rendered feature.

- [ ] **Step 1: Add settings state and a gear button to the header**

In `DashboardView`, add state near the other `@State` declarations:

```swift
    @State private var showingSettings = false
    private let installer = StatuslineInstaller.standard()
```

Then in the `header` view, change:

```swift
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.callout).foregroundStyle(.indigo)
                Text("Claude Usage").font(.headline)
                Spacer()
            }
```

to:

```swift
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.callout).foregroundStyle(.indigo)
                Text("Claude Usage").font(.headline)
                Spacer()
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape").font(.callout).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings")
                .popover(isPresented: $showingSettings, arrowEdge: .bottom) { SettingsView() }
            }
```

- [ ] **Step 2: Render LimitsSection in both layouts**

In `body`, in the **expanded** branch, insert the limits section right after `heroCard(compact: false)`:

```swift
                        heroCard(compact: false)
                        LimitsSection(limits: store.limits, compact: false,
                                      showConnectPrompt: !installer.isInstalled,
                                      onConnect: { showingSettings = true })
```

In the **collapsed** (`else`) branch, insert it right after `heroCard(compact: true)`:

```swift
                    heroCard(compact: true)
                    LimitsSection(limits: store.limits, compact: true,
                                  showConnectPrompt: !installer.isInstalled,
                                  onConnect: { showingSettings = true })
```

- [ ] **Step 3: Verify it builds**

Run: `xcodebuild build -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -destination 'platform=macOS' -configuration Debug 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the full test suite**

Run: `xcodebuild test -project ClaudeTry/ClaudeTry.xcodeproj -scheme ClaudeTry -destination 'platform=macOS' 2>&1 | tail -25`
Expected: all feature tests PASS (`UsageSnapshotTests`, `SnapshotStoreTests`, `AppConfigTests`, `TimeFormatTests`, `LimitsModelTests`, `StatuslineInstallerTests`, `UsageStoreTests`, `ModelTests`, `ModelPricingTests`).

- [ ] **Step 5: Manual verification**

Run: `make build && make restart` (or run the built app).
Then:
1. Open the popover. In the collapsed view, confirm the two bars + timing line (or the "Connect live usage" prompt) appear under the hero.
2. Click the gear → Settings. Click **Install statusline integration**. Confirm it flips to "Installed".
3. In a terminal, verify `~/.claude/settings.json` now has `statusLine.command` pointing at `…/ClaudeTry/claude-tray-statusline.sh`, and any prior statusline was preserved in the app's saved backup.
4. Run a Claude Code command in any project so the statusline fires; within ~30s confirm a snapshot file appears under `~/Library/Application Support/ClaudeTry/snapshots/` and the timing line updates to show active sessions.
5. On this Bedrock setup, confirm the bars show "$X / $50" (weekly) and "$X / $10" (session). Change a budget in Settings and confirm the bar fraction/label updates.
6. Click **Uninstall** and confirm `settings.json`'s `statusLine` is restored to its prior value (or removed).

Expected: all steps behave as described. If anything fails, debug before committing.

- [ ] **Step 6: Commit**

```bash
git add ClaudeTry/ClaudeTry/Views/DashboardView.swift
git commit -m "feat: show usage limit bars and timing in the dashboard"
```

---

## Self-Review Notes

- **Spec coverage:** statusline wrapper + chaining + reversible install (Task 6); per-session snapshots + freshness/pruning (Task 2); auto mode detection incl. partial rate_limits (Task 5); Bedrock USD budgets w/ budget=0 edge (Tasks 3, 5); API/wall timing across active sessions (Task 5); bars in both layouts + connect prompt (Tasks 8, 10); settings popover with budgets + install (Task 9); color thresholds (Task 8); all error-handling rows (decode→nil, malformed file skip, missing dir, settings unreadable, prior chained, no active sessions, past reset, budget≤0) covered by tests in Tasks 1, 2, 5, 6. Out-of-scope items (network limits, menu-bar indicator, per-conversation timing, manual override) intentionally excluded.
- **Test infrastructure:** Task 0 establishes the missing test target before any TDD task; feature tests avoid bundled fixtures (inline JSON) so they don't depend on the pre-existing fixture-bundling quirk.
- **Type consistency:** `UsageSnapshot`/`RateWindow`, `Budgets`, `BarState`/`TimingReadout`/`LimitsModel.make(...)`, `SnapshotStore.standard()/snapshotsDirectory/freshest/active`, `StatuslineInstaller.standard()/isInstalled/scriptContents(chainingTo:)`, `LimitsSection.barColor(for:)` — names match across producing and consuming tasks.
```
