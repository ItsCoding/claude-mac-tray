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
