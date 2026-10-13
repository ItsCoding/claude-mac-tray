import SwiftUI
import Charts

/// "Will I reach reset?" panel. Math lives in `RunwayPredictor`; this view only
/// feeds it the real rate-limit windows plus recent per-message costs and draws the result.
struct PredictionPanel: View {
    @Environment(UsageStore.self) private var store
    @Bindable var vm: AnalyticsViewModel

    var body: some View {
        // Re-evaluate periodically so "now", time-to-reset and the burn window move.
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            content(now: ctx.date)
        }
    }

    private func forecast(_ w: RateWindow?, _ window: AnalyticsViewModel.PredictionWindow,
                          writtenAt: Date?, now: Date) -> RunwayPredictor.Forecast? {
        vm.prediction(window: window, rate: w, calibratedAt: writtenAt, now: now)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let limits = store.limits
        if limits.mode != .anthropic {
            budgetFallback(limits)
        } else {
            let windows = store.rateWindows
            let f5 = forecast(windows.fiveHour, .fiveHour, writtenAt: windows.writtenAt, now: now)
            let f7 = forecast(windows.sevenDay, .sevenDay, writtenAt: windows.writtenAt, now: now)
            let selected = vm.predictionWindow == .fiveHour ? f5 : f7
            let other = vm.predictionWindow == .fiveHour ? f7 : f5
            if vm.predictionCollapsed {
                HStack(spacing: 12) {
                    title
                    if let f = selected { verdictPill(f, compact: true) }
                    Spacer()
                    windowPicker
                    collapseButton
                }
                .analyticsPanel(padding: 10)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    left(selected, f5: f5, f7: f7, windows: windows)
                        .frame(width: 290)
                    Group {
                        if let f = selected { PredictionChart(forecast: f) }
                        else { Text("The selected window has no live data yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }
                    right(selected, other: other)
                        .frame(width: 250)
                }
                .analyticsPanel(padding: 12)
                .frame(height: 226)
            }
        }
    }

    // MARK: Parts

    private var title: some View {
        Text("Will I reach reset?").font(.subheadline.weight(.semibold))
    }

    private var windowPicker: some View {
        Seg(options: AnalyticsViewModel.PredictionWindow.allCases, selection: vm.predictionWindow, title: { $0.rawValue }) {
            vm.predictionWindow = $0
        }
    }

    private var collapseButton: some View {
        Button(vm.predictionCollapsed ? "Show" : "Hide") { vm.predictionCollapsed.toggle() }.controlSize(.small)
    }

    private func left(_ f: RunwayPredictor.Forecast?, f5: RunwayPredictor.Forecast?, f7: RunwayPredictor.Forecast?,
                      windows: (fiveHour: RateWindow?, sevenDay: RateWindow?, writtenAt: Date?)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { title; Spacer(); windowPicker; collapseButton }
            if let f {
                verdictPill(f, compact: false)
                VStack(spacing: 3) {
                    row("5-hour used", windows.fiveHour.map { "\(Int($0.usedPercentage.rounded()))% · resets in \(Self.duration(f5?.hoursLeft ?? 0))" } ?? "no data")
                    row("7-day used", windows.sevenDay.map { "\(Int($0.usedPercentage.rounded()))% · resets in \(Self.duration(f7?.hoursLeft ?? 0))" } ?? "no data")
                    row("Burn · recent 2h", String(format: "%.2f %%/h", f.recentRate))
                    row("Burn · window avg", String(format: "%.2f %%/h", f.averageRate))
                    row("Projected at reset", String(format: "%.0f%% (%.0f–%.0f)", f.projected, f.low, f.high))
                    row("Time to 100%", f.hoursToLimit.map { Self.duration($0) } ?? "never at this rate")
                }
            } else {
                Text("Window reset or no data yet.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func right(_ f: RunwayPredictor.Forecast?, other: RunwayPredictor.Forecast?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("What if")
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Lower burn rate by").font(.caption).foregroundStyle(.secondary)
                    Text("\(Int(vm.predictionOptions.reduceBurn * 100))%").font(.caption.weight(.semibold))
                }
                Slider(value: $vm.predictionOptions.reduceBurn, in: 0...0.6, step: 0.05)
            }
            Toggle("Switch Opus to Sonnet for new work", isOn: $vm.predictionOptions.opusToSonnet)
                .toggleStyle(.checkbox).font(.caption)
            HStack {
                Text("Rate basis").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $vm.predictionOptions.basis) {
                    Text("Recent (2h)").tag(RunwayPredictor.Basis.recent)
                    Text("Window avg").tag(RunwayPredictor.Basis.windowAverage)
                }
                .labelsHidden().controlSize(.small)
            }
            if let f {
                VStack(spacing: 3) {
                    row("Safe burn to reset", String(format: "%.2f %%/h", f.safeRate))
                    row("Scenario burn", String(format: "%.2f %%/h", f.scenarioRate))
                    row("Cut needed", f.cutNeeded > 0 ? "\(Int((f.cutNeeded * 100).rounded()))% less burn" : "none")
                    if let other {
                        row(vm.predictionWindow == .fiveHour ? "7-day window" : "5-hour window", Self.verdictName(other.verdict))
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ a: String, _ b: String) -> some View {
        HStack(spacing: 8) {
            Text(a).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(b).fontWeight(.semibold).lineLimit(1).minimumScaleFactor(0.8)
        }
        .font(.caption.monospacedDigit())
    }

    private func verdictPill(_ f: RunwayPredictor.Forecast, compact: Bool) -> some View {
        let (text, sub, color) = Self.describe(f)
        return VStack(alignment: .leading, spacing: 3) {
            Text(text).font(compact ? .callout.weight(.semibold) : .headline)
            if !compact { Text(sub).font(.caption).fontWeight(.regular) }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12).padding(.vertical, compact ? 4 : 9)
        .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
        .background(color.opacity(0.17), in: .rect(cornerRadius: 10))
    }

    /// No rate limits (Bedrock): the same cost-vs-budget bars the popover shows.
    private func budgetFallback(_ limits: LimitsModel) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                title
                Text("Needs live Claude.ai rate limits. Showing cost against your budgets instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            budgetBar("Session · 5h", limits.session)
            budgetBar("Weekly · 7d", limits.weekly)
        }
        .analyticsPanel(padding: 10)
    }

    private func budgetBar(_ title: String, _ bar: BarState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(bar.primaryLabel).font(.caption.monospacedDigit().weight(.semibold))
            }
            ProgressView(value: bar.fraction).tint(bar.fraction > 0.9 ? .red : .indigo)
        }
        .frame(width: 190)
    }

    // MARK: Text helpers

    static func describe(_ f: RunwayPredictor.Forecast) -> (String, String, Color) {
        switch f.verdict {
        case .onTrack:
            return ("On track", String(format: "Projected %.0f%% at reset (band %.0f–%.0f%%)", f.projected, f.low, f.high), .green)
        case .atRisk:
            return ("At risk", String(format: "Projected %.0f%%, upper band %.0f%% · thin headroom", f.projected, f.high), .orange)
        case .limitReached:
            return ("Limit reached", String(format: "%.0f%% used · resets in %@", f.usedPercent, duration(f.hoursLeft)), .red)
        case .runsOut(let at):
            let mins = max(0, Int(f.resetsAt.timeIntervalSince(at) / 60))
            return ("Will run out ~\(at.formatted(date: .abbreviated, time: .shortened))",
                    "\(mins) min before reset · burning \(String(format: "%.1f", f.scenarioRate)) %/h", .red)
        }
    }

    static func verdictName(_ v: RunwayPredictor.Verdict) -> String {
        switch v { case .onTrack: return "On track"; case .atRisk: return "At risk"; case .runsOut: return "Runs out"; case .limitReached: return "Limit reached" }
    }

    static func duration(_ hours: Double) -> String {
        let total = Int((max(0, hours) * 60).rounded())
        let h = total / 60, m = total % 60
        if h >= 48 { return "\(h / 24)d \(h % 24)h" }
        return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
    }
}

/// Used-so-far curve, projected burn with a confidence band, now/reset markers and the 100% line.
private struct PredictionChart: View {
    let forecast: RunwayPredictor.Forecast

    var body: some View {
        let f = forecast
        let top = min(400, max(120, f.high * 1.05))
        let clamp = { (v: Double) in min(v, top) }
        Chart {
            ForEach(Array(f.future.enumerated()), id: \.offset) { _, p in
                AreaMark(x: .value("Time", p.time), yStart: .value("Low", clamp(p.low)), yEnd: .value("High", clamp(p.high)),
                         series: .value("S", "band"))
                    .foregroundStyle(Color.orange.opacity(0.16))
            }
            ForEach(Array(f.past.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("Time", p.time), y: .value("Used", clamp(p.value)), series: .value("S", "used"))
                    .foregroundStyle(Color.blue).lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(Array(f.future.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("Time", p.time), y: .value("Projected", clamp(p.value)), series: .value("S", "proj"))
                    .foregroundStyle(Color.orange).lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
            RuleMark(y: .value("Limit", 100))
                .foregroundStyle(Color.red.opacity(0.8)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .annotation(position: .top, alignment: .leading) { Text("limit").font(.caption2).foregroundStyle(.secondary) }
            RuleMark(x: .value("Now", f.now))
                .foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .annotation(position: .top, alignment: .leading, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                    Text("now \(f.now.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                }
            RuleMark(x: .value("Reset", f.resetsAt))
                .foregroundStyle(Color.primary.opacity(0.7))
                .annotation(position: .top, alignment: .trailing) {
                    Text("reset \(f.resetsAt.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                }
            PointMark(x: .value("Time", f.now), y: .value("Used", clamp(f.usedPercent)))
                .foregroundStyle(Color.blue).symbolSize(40)
            if case .runsOut(let at) = f.verdict, at <= f.resetsAt {
                PointMark(x: .value("Time", at), y: .value("Limit", 100)).foregroundStyle(Color.red).symbolSize(55)
                    .annotation(position: .bottom, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text("out \(at.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.red)
                    }
            }
        }
        .chartYScale(domain: 0...top)
        .chartXScale(domain: f.windowStart...f.resetsAt)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%").font(.caption2) } }
            }
        }
        .chartXAxis {
            // Multi-day window: one tick per day; 5-hour window: one per hour.
            let multiDay = f.resetsAt.timeIntervalSince(f.windowStart) > 2 * 86_400
            AxisMarks(values: .stride(by: multiDay ? .day : .hour)) { _ in
                AxisTick()
                AxisValueLabel(format: multiDay ? .dateTime.weekday(.abbreviated).day() : .dateTime.hour().minute(), centered: false)
            }
        }
        .padding(.top, 14)
    }
}
