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
