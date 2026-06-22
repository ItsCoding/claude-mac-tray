import Foundation

/// Installs a statusline wrapper as Claude Code's `statusLine.command` so the
/// menu-bar app can capture the usage payload. The wrapper writes a per-session
/// JSON snapshot and chains to whatever statusline was configured before, so it
/// composes with claude-hud or a user's own statusline rather than replacing it.
final class StatuslineInstaller {
    enum InstallError: Error { case settingsUnreadable }

    private let settingsURL: URL
    private let scriptURL: URL
    /// Companion script that holds the prior statusLine command verbatim.
    /// Stored as a separate file to avoid any shell-quoting of the prior command.
    private var priorScriptURL: URL {
        scriptURL.deletingLastPathComponent().appendingPathComponent("claude-tray-prior.sh")
    }
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

    /// The command we write into settings.json — bash-wrapped so paths with spaces work.
    private var installedCommand: String { "bash \"\(scriptURL.path)\"" }

    /// True when settings.json's statusLine command is ours (either format),
    /// or when the configured command is a wrapper file that calls our script.
    var isInstalled: Bool {
        guard let dict = readSettings(),
              let sl = dict["statusLine"] as? [String: Any],
              let cmd = sl["command"] as? String else { return false }
        if cmd == installedCommand || cmd == scriptURL.path { return true }
        // Detect chain wrappers (e.g. claude-hud-with-tray.sh) that call our script
        if let content = try? String(contentsOfFile: cmd, encoding: .utf8) {
            return content.contains(scriptURL.path)
        }
        return false
    }

    /// True when claude-hud is part of the statusLine — either as the current command
    /// (not yet installed) or as the saved prior command (already installed + chained).
    var claudeHudInvolved: Bool {
        if isInstalled {
            guard let saved = config.previousStatusLine,
                  let obj = try? JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any],
                  let cmd = obj["command"] as? String else { return false }
            return cmd.contains("claude-hud")
        } else {
            guard let dict = readSettings(),
                  let sl = dict["statusLine"] as? [String: Any],
                  let cmd = sl["command"] as? String else { return false }
            return cmd.contains("claude-hud")
        }
    }

    /// Main wrapper script. Captures the payload, then delegates to the companion
    /// prior script if present, else falls back to displaying the model name.
    /// The prior command lives in a separate file so no shell-quoting is needed.
    func scriptContents() -> String {
        // Single-quote escape only needed for snapshotDir.path (companion path uses double-quotes)
        let snap = snapshotDir.path.replacingOccurrences(of: "'", with: "'\\''")
        return """
        #!/bin/sh
        # ClaudeTry statusline wrapper — captures usage payload, then chains.
        SNAP_DIR='\(snap)'
        PRIOR="\(priorScriptURL.path)"
        mkdir -p "$SNAP_DIR"
        input=$(cat)
        sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
        [ -z "$sid" ] && sid="unknown"
        tmp="$SNAP_DIR/.$sid.tmp"
        printf '%s' "$input" > "$tmp" && mv "$tmp" "$SNAP_DIR/$sid.json"
        if [ -f "$PRIOR" ]; then
          printf '%s' "$input" | sh "$PRIOR"
        else
          printf '%s' "$input" | sed -n 's/.*"display_name"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/[\\1]/p'
        fi
        """
    }

    func install() throws {
        guard var dict = readSettings() else { throw InstallError.settingsUnreadable }

        // Capture the prior statusLine for chaining + restore, unless we're already installed.
        var priorCommand: String? = nil
        if let sl = dict["statusLine"] as? [String: Any],
           let existingCmd = sl["command"] as? String,
           existingCmd != installedCommand && existingCmd != scriptURL.path {
            priorCommand = existingCmd
            if let data = try? JSONSerialization.data(withJSONObject: sl),
               let json = String(data: data, encoding: .utf8) {
                config.previousStatusLine = json
            }
        } else if let saved = config.previousStatusLine,
                  let obj = try? JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any] {
            priorCommand = obj["command"] as? String  // re-install: reuse the saved prior
        }

        try FileManager.default.createDirectory(at: scriptURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        // Write the prior command verbatim into a companion script — no quoting needed.
        if let cmd = priorCommand {
            try "#!/bin/sh\n\(cmd)\n".write(to: priorScriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: priorScriptURL.path)
        } else {
            try? FileManager.default.removeItem(at: priorScriptURL)
        }

        try scriptContents().write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        dict["statusLine"] = ["type": "command", "command": installedCommand]
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
        try? FileManager.default.removeItem(at: priorScriptURL)
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
