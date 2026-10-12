import Foundation

/// Time-sorted cost points with prefix sums, so any "cost between a and b" is two
/// binary searches instead of a scan.
struct CostIndex: Sendable {
    private(set) var times: [TimeInterval] = []
    private var cumCost: [Double] = [0]
    private var cumEffective: [Double] = [0]   // cost if Opus work ran on Sonnet

    init() {}

    init(points: [CostPoint]) {
        var pts = points
        if !zip(pts, pts.dropFirst()).allSatisfy({ $0.time <= $1.time }) { pts.sort { $0.time < $1.time } }
        times.reserveCapacity(pts.count)
        cumCost.reserveCapacity(pts.count + 1)
        cumEffective.reserveCapacity(pts.count + 1)
        var c = 0.0, e = 0.0
        for p in pts {
            times.append(p.time.timeIntervalSince1970)
            c += p.cost
            // Per-point Sonnet price from the pricing catalog; legacy points fall back to a flat ratio.
            e += p.isOpus ? min(p.cost, p.sonnetCost ?? p.cost * RunwayPredictor.sonnetToOpusCostRatio) : p.cost
            cumCost.append(c)
            cumEffective.append(e)
        }
    }

    private func lowerBound(_ t: TimeInterval) -> Int {
        var lo = 0, hi = times.count
        while lo < hi { let m = (lo + hi) / 2; if times[m] < t { lo = m + 1 } else { hi = m } }
        return lo
    }
    private func upperBound(_ t: TimeInterval) -> Int {
        var lo = 0, hi = times.count
        while lo < hi { let m = (lo + hi) / 2; if times[m] <= t { lo = m + 1 } else { hi = m } }
        return lo
    }

    /// Cost with a <= time <= b.
    func cost(from a: Date, to b: Date) -> Double {
        let lo = lowerBound(a.timeIntervalSince1970), hi = upperBound(b.timeIntervalSince1970)
        return hi > lo ? cumCost[hi] - cumCost[lo] : 0
    }
    /// Same range, with Opus priced as Sonnet.
    func effectiveCost(from a: Date, to b: Date) -> Double {
        let lo = lowerBound(a.timeIntervalSince1970), hi = upperBound(b.timeIntervalSince1970)
        return hi > lo ? cumEffective[hi] - cumEffective[lo] : 0
    }
}

/// Pure math behind "Will I reach reset?". The same average-rate extrapolation
/// powers `UsageStore.forecastRunway` (popover) and the analytics prediction panel.
enum RunwayPredictor {
    enum Basis: String, CaseIterable, Sendable { case recent, windowAverage }

    struct Options: Sendable, Equatable {
        var basis: Basis = .recent
        /// 0...0.6: fraction by which the user lowers their burn rate.
        var reduceBurn: Double = 0
        /// Price new Opus work like Sonnet.
        var opusToSonnet = false
    }

    struct Inputs: Sendable {
        var usedPercent: Double
        var resetsAt: Date
        var windowHours: Double
        var now: Date
        var index: CostIndex
        /// When `usedPercent` was measured (snapshot write time). Spend after it is added on top.
        var calibratedAt: Date?

        init(usedPercent: Double, resetsAt: Date, windowHours: Double, now: Date,
             index: CostIndex, calibratedAt: Date? = nil) {
            self.usedPercent = usedPercent; self.resetsAt = resetsAt; self.windowHours = windowHours
            self.now = now; self.index = index; self.calibratedAt = calibratedAt
        }

        init(usedPercent: Double, resetsAt: Date, windowHours: Double, now: Date,
             points: [CostPoint], calibratedAt: Date? = nil) {
            self.init(usedPercent: usedPercent, resetsAt: resetsAt, windowHours: windowHours, now: now,
                      index: CostIndex(points: points), calibratedAt: calibratedAt)
        }
    }

    enum Verdict: Equatable, Sendable {
        case onTrack, atRisk, limitReached
        case runsOut(at: Date)
    }

    struct Forecast: Sendable {
        var verdict: Verdict
        var usedPercent: Double
        var hoursLeft: Double
        var windowStart: Date
        var resetsAt: Date
        var now: Date
        var recentRate: Double        // percent of limit per hour, last 2h
        var averageRate: Double       // percent per hour since window start
        var scenarioRate: Double      // rate after basis + what-if options
        var projected: Double         // % at reset
        var low: Double
        var high: Double
        var hoursToLimit: Double?     // nil = not at this rate
        var exhaustAt: Date?
        var safeRate: Double          // max % per hour that still reaches reset
        var cutNeeded: Double         // 0...1 fraction of burn to drop to be safe
        var past: [CurvePoint]
        var future: [CurvePoint]
    }

    struct CurvePoint: Sendable, Equatable {
        var time: Date
        var value: Double
        var low: Double
        var high: Double
    }

    /// Fallback when a point has no catalog Sonnet price (Sonnet ~ 1/5 of Opus 4/4.1).
    static let sonnetToOpusCostRatio = 0.2
    /// z for an ~80% one-sided band.
    static let bandZ = 1.28
    /// Below this, "% per dollar" is too noisy to trust; use the window average instead.
    static let minUsedForCalibration = 2.0
    static let minCostForCalibration = 0.05
    /// Shortest span (hours) for a meaningful recent burn rate.
    static let minRecentSpanHours = 0.25

    // MARK: Shared with UsageStore.forecastRunway

    /// Percent of the limit consumed per hour since the window opened.
    static func averageRate(usedPercent: Double, hoursLeft: Double, windowHours: Double) -> Double? {
        let elapsed = windowHours - hoursLeft
        guard elapsed > 0.1 else { return nil }
        return usedPercent / elapsed
    }

    /// Hours until 100% if the burn stays at `ratePerHour` (percent/hour).
    static func hoursToLimit(usedPercent: Double, ratePerHour: Double) -> Double? {
        guard ratePerHour > 0 else { return nil }
        return max(0, 100 - usedPercent) / ratePerHour
    }

    /// Average-rate runway in hours, as the popover shows it. Nil when too little
    /// has been used (<= 2%) or the window just opened to extrapolate sensibly.
    static func averageRunwayHours(usedPercent: Double, resetsAt: Date, windowHours: Double, now: Date = Date()) -> Double? {
        guard usedPercent > 2 else { return nil }
        let left = max(0, resetsAt.timeIntervalSince(now) / 3600)
        guard let rate = averageRate(usedPercent: usedPercent, hoursLeft: left, windowHours: windowHours) else { return nil }
        return hoursToLimit(usedPercent: usedPercent, ratePerHour: rate)
    }

    // MARK: Forecast

    static func forecast(_ i: Inputs, options o: Options = Options()) -> Forecast? {
        let hoursLeft = i.resetsAt.timeIntervalSince(i.now) / 3600
        guard hoursLeft > 0, i.windowHours > 0 else { return nil }
        let windowStart = i.resetsAt.addingTimeInterval(-i.windowHours * 3600)
        let idx = i.index

        // The reported % was measured at `calibratedAt`; spend since then is added on top.
        let measuredAt = min(max(i.calibratedAt ?? i.now, windowStart), i.now)
        let measured = max(0, i.usedPercent)

        // Calibrate "% of limit per dollar" from spend inside the window up to the measurement.
        let costAtMeasure = idx.cost(from: windowStart, to: measuredAt)
        let scale: Double? = (measured >= minUsedForCalibration && costAtMeasure >= minCostForCalibration)
            ? measured / costAtMeasure : nil
        let used = measured + (scale.map { idx.cost(from: measuredAt.addingTimeInterval(0.001), to: i.now) * $0 } ?? 0)

        let avg = averageRate(usedPercent: used, hoursLeft: hoursLeft, windowHours: i.windowHours) ?? 0

        // Recent burn over at most the last 2h, never reaching before the window opened.
        let recentStart = max(i.now.addingTimeInterval(-2 * 3600), windowStart)
        let recentSpan = i.now.timeIntervalSince(recentStart) / 3600
        let recent: Double
        if let scale, recentSpan >= minRecentSpanHours {
            recent = idx.cost(from: recentStart, to: i.now) / recentSpan * scale
        } else {
            recent = avg
        }

        // Hour-to-hour volatility over the last 24h drives the confidence band.
        var sd = 0.0
        if let scale {
            var hourly: [Double] = []
            hourly.reserveCapacity(24)
            for k in 0..<24 {
                let hi = i.now.addingTimeInterval(-Double(k) * 3600)
                hourly.append(idx.cost(from: hi.addingTimeInterval(-3600 + 0.001), to: hi) * scale)
            }
            let mu = hourly.reduce(0, +) / 24
            sd = (hourly.reduce(0) { $0 + pow($1 - mu, 2) } / 24).squareRoot()
        }

        let base = o.basis == .recent ? recent : avg
        var mix = 1.0
        if o.opusToSonnet {
            let from = i.now.addingTimeInterval(-86_400)
            let total = idx.cost(from: from, to: i.now)
            mix = total > 0 ? idx.effectiveCost(from: from, to: i.now) / total : 1
        }
        let rate = max(0, base * (1 - min(max(o.reduceBurn, 0), 0.95)) * mix)

        func band(_ dt: Double) -> Double { bandZ * sd * dt.squareRoot() }
        let projected = used + rate * hoursLeft
        let low = max(used, projected - band(hoursLeft))
        let high = projected + band(hoursLeft)
        let toLimit = hoursToLimit(usedPercent: used, ratePerHour: rate)
        let verdict: Verdict
        if used >= 100 {
            verdict = .limitReached
        } else if let t = toLimit, t < hoursLeft {
            verdict = .runsOut(at: i.now.addingTimeInterval(t * 3600))
        } else if high >= 100 || projected >= 85 {
            verdict = .atRisk
        } else {
            verdict = .onTrack
        }
        let safe = max(0, 100 - used) / hoursLeft

        // Curves for the chart (prefix sums: one lookup per step).
        var past: [CurvePoint] = []
        let steps = 48
        let span = i.now.timeIntervalSince(windowStart)
        for s in 0...steps {
            let t = windowStart.addingTimeInterval(span * Double(s) / Double(steps))
            let v: Double
            if let scale { v = idx.cost(from: windowStart, to: t) * scale } else { v = used * Double(s) / Double(steps) }
            past.append(CurvePoint(time: t, value: min(v, used), low: 0, high: 0))
        }
        var future: [CurvePoint] = []
        for s in 0...30 {
            let dt = hoursLeft * Double(s) / 30
            let v = used + rate * dt
            future.append(CurvePoint(time: i.now.addingTimeInterval(dt * 3600), value: v,
                                     low: max(used, v - band(dt)), high: v + band(dt)))
        }

        return Forecast(
            verdict: verdict, usedPercent: used, hoursLeft: hoursLeft, windowStart: windowStart,
            resetsAt: i.resetsAt, now: i.now, recentRate: recent, averageRate: avg, scenarioRate: rate,
            projected: projected, low: low, high: high, hoursToLimit: toLimit,
            exhaustAt: toLimit.map { i.now.addingTimeInterval($0 * 3600) },
            safeRate: safe, cutNeeded: rate > safe && rate > 0 ? 1 - safe / rate : 0,
            past: past, future: future)
    }
}
