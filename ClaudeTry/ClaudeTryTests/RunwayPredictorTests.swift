import XCTest
@testable import ClaudeTry

final class RunwayPredictorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Steady spend of `perHour` dollars, one point per 10 minutes, going back `hours`.
    private func steady(perHour: Double, hours: Int, opus: Bool = false) -> [CostPoint] {
        (0..<(hours * 6)).map { k in
            CostPoint(time: now.addingTimeInterval(-Double(k) * 600), cost: perHour / 6, isOpus: opus)
        }.reversed()
    }

    private func inputs(used: Double, leftH: Double, windowH: Double = 5, points: [CostPoint]) -> RunwayPredictor.Inputs {
        .init(usedPercent: used, resetsAt: now.addingTimeInterval(leftH * 3600), windowHours: windowH, now: now, points: points)
    }

    func test_averageRate_andHoursToLimit() {
        XCTAssertEqual(RunwayPredictor.averageRate(usedPercent: 40, hoursLeft: 3, windowHours: 5)!, 20, accuracy: 1e-9)
        XCTAssertNil(RunwayPredictor.averageRate(usedPercent: 40, hoursLeft: 4.95, windowHours: 5))
        XCTAssertEqual(RunwayPredictor.hoursToLimit(usedPercent: 40, ratePerHour: 20)!, 3, accuracy: 1e-9)
        XCTAssertNil(RunwayPredictor.hoursToLimit(usedPercent: 40, ratePerHour: 0))
    }

    func test_averageRunwayHours_matchesLegacyFormula() {
        // 50% used, 2.5h left of a 5h window: 20 %/h => 2.5h to 100%
        let r = RunwayPredictor.averageRunwayHours(usedPercent: 50, resetsAt: now.addingTimeInterval(2.5 * 3600), windowHours: 5, now: now)
        XCTAssertEqual(r!, 2.5, accuracy: 1e-9)
        XCTAssertNil(RunwayPredictor.averageRunwayHours(usedPercent: 1, resetsAt: now.addingTimeInterval(3600), windowHours: 5, now: now))
    }

    func test_onTrack_whenBurnIsLow() {
        // 10% used, window 2h old (avg 5 %/h), steady spend -> projection 25%
        let f = RunwayPredictor.forecast(inputs(used: 10, leftH: 3, points: steady(perHour: 1, hours: 1)))!
        XCTAssertEqual(f.verdict, .onTrack)
        XCTAssertEqual(f.averageRate, 5, accuracy: 1e-9)
        XCTAssertEqual(f.recentRate, 5, accuracy: 1e-6) // lookback clamped to the window, divided by the real span
        XCTAssertEqual(f.projected, 10 + 5 * 3, accuracy: 1e-6)
    }

    func test_runsOut_beforeReset() {
        let f = RunwayPredictor.forecast(inputs(used: 60, leftH: 2.5, points: steady(perHour: 1, hours: 3)))!
        // avg 60/2.5 = 24 %/h, 40% left => 1.67h < 2.5h
        guard case .runsOut(let at) = f.verdict else { return XCTFail("expected runsOut, got \(f.verdict)") }
        XCTAssertEqual(at.timeIntervalSince(now) / 3600, 40.0 / f.scenarioRate, accuracy: 1e-6)
        XCTAssertEqual(f.hoursToLimit!, 40.0 / f.scenarioRate, accuracy: 1e-6)
        XCTAssertGreaterThan(f.cutNeeded, 0)
    }

    func test_whatIf_reduceBurnFlipsVerdict() {
        let pts = steady(perHour: 1, hours: 3)
        let base = RunwayPredictor.forecast(inputs(used: 60, leftH: 2.5, points: pts), options: .init(basis: .windowAverage))!
        if case .runsOut = base.verdict {} else { XCTFail("baseline should run out") }
        let cut = RunwayPredictor.forecast(inputs(used: 60, leftH: 2.5, points: pts),
                                           options: .init(basis: .windowAverage, reduceBurn: 0.6))!
        XCTAssertEqual(cut.scenarioRate, base.scenarioRate * 0.4, accuracy: 1e-9)
        XCTAssertNotEqual(cut.verdict, base.verdict)
        XCTAssertEqual(cut.projected, 60 + 9.6 * 2.5, accuracy: 1e-6) // 24 * 0.4 = 9.6 %/h
    }

    func test_safeRate_isRemainingHeadroomOverTimeLeft() {
        let f = RunwayPredictor.forecast(inputs(used: 50, leftH: 2, points: steady(perHour: 1, hours: 3)))!
        XCTAssertEqual(f.safeRate, 25, accuracy: 1e-9)
    }

    func test_opusToSonnet_cutsRateByOpusShare() {
        let pts = steady(perHour: 1, hours: 3, opus: true) // 100% opus
        let a = RunwayPredictor.forecast(inputs(used: 30, leftH: 2.5, points: pts))!
        let b = RunwayPredictor.forecast(inputs(used: 30, leftH: 2.5, points: pts), options: .init(opusToSonnet: true))!
        XCTAssertEqual(b.scenarioRate, a.scenarioRate * RunwayPredictor.sonnetToOpusCostRatio, accuracy: 1e-9)
        // No opus => no change
        let none = steady(perHour: 1, hours: 3, opus: false)
        let c = RunwayPredictor.forecast(inputs(used: 30, leftH: 2.5, points: none))!
        let d = RunwayPredictor.forecast(inputs(used: 30, leftH: 2.5, points: none), options: .init(opusToSonnet: true))!
        XCTAssertEqual(c.scenarioRate, d.scenarioRate, accuracy: 1e-9)
    }

    func test_recentVsAverageBasis_differWhenBurnAccelerates() {
        // quiet early, busy in the last 2h
        var pts = steady(perHour: 0.2, hours: 3)
        pts += steady(perHour: 3, hours: 2)
        let recent = RunwayPredictor.forecast(inputs(used: 50, leftH: 2, points: pts), options: .init(basis: .recent))!
        let avg = RunwayPredictor.forecast(inputs(used: 50, leftH: 2, points: pts), options: .init(basis: .windowAverage))!
        XCTAssertGreaterThan(recent.scenarioRate, avg.scenarioRate)
        XCTAssertEqual(recent.averageRate, avg.averageRate, accuracy: 1e-9)
    }

    func test_noCostData_fallsBackToAverageRate_andNilWhenWindowReset() {
        let f = RunwayPredictor.forecast(inputs(used: 40, leftH: 2, points: []))!
        XCTAssertEqual(f.recentRate, f.averageRate, accuracy: 1e-9)
        XCTAssertEqual(f.high, f.projected, accuracy: 1e-9) // no volatility info -> no band
        XCTAssertNil(RunwayPredictor.forecast(inputs(used: 40, leftH: -1, points: [])))
    }

    func test_alreadyAtLimit_isLimitReached() {
        let f = RunwayPredictor.forecast(inputs(used: 100, leftH: 1, points: steady(perHour: 1, hours: 3)))!
        XCTAssertEqual(f.verdict, .limitReached)
        XCTAssertEqual(PredictionPanel.describe(f).0, "Limit reached")
    }

    func test_earlyWindow_burstDoesNotFalselyRunOut() {
        // Window opened 20 min ago, 3% used from a $1 burst. A naive "last 2h / 2" would
        // read 1.5x the real rate; the lookback must be clamped to the 20 min span.
        let pts = [CostPoint(time: now.addingTimeInterval(-600), cost: 1, isOpus: false)]
        let f = RunwayPredictor.forecast(inputs(used: 3, leftH: 5 - 1.0 / 3, points: pts))!
        XCTAssertEqual(f.recentRate, 3 / (1.0 / 3), accuracy: 1e-6)   // 9 %/h over the actual span
        XCTAssertEqual(f.verdict, .onTrack)
    }

    func test_tinyUsageFallsBackToWindowAverage() {
        let pts = [CostPoint(time: now.addingTimeInterval(-600), cost: 0.001, isOpus: false)]
        let f = RunwayPredictor.forecast(inputs(used: 1, leftH: 3, points: pts))!
        XCTAssertEqual(f.recentRate, f.averageRate, accuracy: 1e-9)
    }

    func test_spendAfterSnapshotIsAddedToUsed() {
        // snapshot (30%) written 30 min ago; $0.5 spent since, calibration: $2.5 -> 30% = 12 %/$
        var pts = steady(perHour: 1, hours: 3)
        pts = pts.filter { $0.time <= now.addingTimeInterval(-1800) } + [CostPoint(time: now.addingTimeInterval(-60), cost: 0.5, isOpus: false)]
        var inp = inputs(used: 30, leftH: 2.5, points: pts)
        inp.calibratedAt = now.addingTimeInterval(-1800)
        let f = RunwayPredictor.forecast(inp)!
        let base = pts.filter { $0.time <= now.addingTimeInterval(-1800) && $0.time >= now.addingTimeInterval(-2.5 * 3600) }.reduce(0) { $0 + $1.cost }
        XCTAssertEqual(f.usedPercent, 30 + 0.5 * (30 / base), accuracy: 1e-6)
    }

    func test_opusToSonnet_usesPerPointCatalogPrice() {
        // Opus point whose Sonnet-equivalent is 40% of its cost
        let pts = (0..<30).map { CostPoint(time: now.addingTimeInterval(-Double($0) * 600), cost: 0.1, isOpus: true, sonnetCost: 0.04) }
        let a = RunwayPredictor.forecast(inputs(used: 30, leftH: 2.5, points: pts))!
        let b = RunwayPredictor.forecast(inputs(used: 30, leftH: 2.5, points: pts), options: .init(opusToSonnet: true))!
        XCTAssertEqual(b.scenarioRate, a.scenarioRate * 0.4, accuracy: 1e-9)
    }

    func test_costIndex_rangeSums() {
        let pts = (0..<10).map { CostPoint(time: now.addingTimeInterval(Double($0) * 60), cost: 1, isOpus: false) }
        let idx = CostIndex(points: pts.reversed())      // unsorted input is sorted
        XCTAssertEqual(idx.cost(from: now, to: now.addingTimeInterval(9 * 60)), 10)
        XCTAssertEqual(idx.cost(from: now.addingTimeInterval(120), to: now.addingTimeInterval(240)), 3)
        XCTAssertEqual(idx.cost(from: now.addingTimeInterval(-100), to: now.addingTimeInterval(-1)), 0)
    }

    func test_curves_spanWindowAndEndAtProjection() {
        let f = RunwayPredictor.forecast(inputs(used: 30, leftH: 2.5, points: steady(perHour: 1, hours: 3)))!
        XCTAssertEqual(f.past.first!.time, f.windowStart)
        XCTAssertEqual(f.past.last!.time, now)
        XCTAssertEqual(f.past.last!.value, 30, accuracy: 1e-6)
        XCTAssertEqual(f.future.last!.time, f.resetsAt)
        XCTAssertEqual(f.future.last!.value, f.projected, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(f.future.last!.low, f.future.last!.value)
        XCTAssertGreaterThanOrEqual(f.future.last!.high, f.future.last!.value)
    }
}

