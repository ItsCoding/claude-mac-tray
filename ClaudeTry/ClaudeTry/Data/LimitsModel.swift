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
