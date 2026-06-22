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
