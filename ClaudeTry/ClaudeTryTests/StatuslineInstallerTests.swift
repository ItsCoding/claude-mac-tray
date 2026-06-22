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

    func test_isInstalled_detectsChainWrapper() throws {
        // A custom wrapper that calls our script in the background (like claude-hud-with-tray.sh)
        let wrapperURL = dir.appendingPathComponent("claude-hud-with-tray.sh")
        let wrapperContent = """
        #!/bin/bash
        input=$(cat)
        printf '%s' "$input" | "\(scriptURL.path)" >/dev/null 2>&1 &
        printf '%s' "$input" | some-other-tool
        """
        try wrapperContent.write(to: wrapperURL, atomically: true, encoding: .utf8)
        let settingsDict: [String: Any] = ["statusLine": ["type": "command", "command": wrapperURL.path]]
        try JSONSerialization.data(withJSONObject: settingsDict).write(to: settingsURL)
        XCTAssertTrue(installer().isInstalled)
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
