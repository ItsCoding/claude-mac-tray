import Foundation

/// One Claude Code rate-limit window (Pro/Max only): how full it is and when it resets.
struct RateWindow {
    let usedPercentage: Double
    let resetsAt: Date
}

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
