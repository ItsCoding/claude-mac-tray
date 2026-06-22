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
