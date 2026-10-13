import SwiftUI
import Charts

/// The main time-series chart. All data shaping happens in `ChartPlot` (once per
/// body evaluation); hover state lives in `ChartHoverLayer` so moving the mouse
/// never re-evaluates the chart itself.
struct AnalyticsChartView: View {
    let vm: AnalyticsViewModel
    let result: AnalyticsResult
    let kind: ChartKind

    var body: some View {
        let plot = ChartPlot(result: result, kind: kind, hidden: vm.hiddenSeries,
                             logScale: vm.state.logScale, overlays: vm.state.overlays)
        let palette = SeriesPalette(names: result.series.map(\.key))
        let focus = vm.focus
        let pinDate: Date? = vm.pin.flatMap { $0 < result.starts.count ? result.starts[$0] : nil }

        Chart {
            ForEach(plot.points) { p in
                let dim = focus != nil && focus != p.series
                switch kind {
                case .stacked, .share:
                    AreaMark(x: .value("Time", p.date), y: .value("Value", p.y))
                        .foregroundStyle(by: .value("Series", p.series))
                        .opacity(dim ? 0.12 : 0.6)
                case .bars:
                    BarMark(x: .value("Time", p.date, unit: result.granularity.component), y: .value("Value", p.y))
                        .foregroundStyle(by: .value("Series", p.series))
                        .opacity(dim ? 0.15 : 0.9)
                default:
                    LineMark(x: .value("Time", p.date), y: .value("Value", p.y))
                        .foregroundStyle(by: .value("Series", p.series))
                        .lineStyle(StrokeStyle(lineWidth: dim ? 1 : 2, lineJoin: .round))
                        .opacity(dim ? 0.2 : 1)
                }
            }
            if plot.showOverlays {
                if let prev = plot.previous {
                    ForEach(prev) { m in
                        LineMark(x: .value("Time", m.date), y: .value("Value", m.y),
                                 series: .value("Series", "Previous period"))
                            .foregroundStyle(Color.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1.3, dash: [4, 4]))
                    }
                }
                if let ma = plot.movingAverage {
                    ForEach(ma) { m in
                        LineMark(x: .value("Time", m.date), y: .value("Value", m.y),
                                 series: .value("Series", "Moving average"))
                            .foregroundStyle(Color.primary.opacity(0.85))
                            .lineStyle(StrokeStyle(lineWidth: 1.4))
                    }
                }
                if let fc = plot.forecastLine {
                    ForEach(fc) { m in
                        LineMark(x: .value("Time", m.date), y: .value("Value", m.y),
                                 series: .value("Series", "Forecast"))
                            .foregroundStyle(Color.blue)
                            .lineStyle(StrokeStyle(lineWidth: 1.8, dash: [2, 4]))
                    }
                }
                ForEach(plot.outlierPoints) { m in
                    PointMark(x: .value("Time", m.date), y: .value("Value", m.y))
                        .symbol { Circle().strokeBorder(Color.red, lineWidth: 1.6).frame(width: 10, height: 10) }
                }
            }
            if let pinDate {
                RuleMark(x: .value("Pinned", pinDate)).foregroundStyle(Color.primary.opacity(0.6))
            }
        }
        .chartForegroundStyleScale(domain: palette.domain, range: palette.range)
        .chartLegend(.hidden)
        .chartYScale(domain: 0...plot.yTop)
        .chartXScaleIfNeeded(kind != .bars, domain: plot.xDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: plot.yTicks) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(plot.yLabel(d)).font(.caption2) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                AxisGridLine()
                AxisValueLabel(format: result.granularity == .hour
                               ? Date.FormatStyle().day().hour()
                               : Date.FormatStyle().month(.abbreviated).day())
            }
        }
        .chartOverlay { proxy in
            ChartHoverLayer(proxy: proxy, dates: plot.allDates, bucketCount: result.starts.count,
                            tip: { plot.tip(at: $0, palette: palette) },
                            onTap: { i in vm.pin = (vm.pin == i) ? nil : i })
        }
    }
}

/// Everything the chart draws, derived from an `AnalyticsResult`.
struct ChartPlot {
    struct Pt: Identifiable { let id: Int; let series: String; let date: Date; let y: Double }
    struct Mark: Identifiable { let id: Int; let date: Date; let y: Double }
    struct Tip {
        var header: String
        var rows: [(Color, String, String)] = []
        var total: String?
        var extras: [(String, Color)] = []
    }

    let result: AnalyticsResult
    let kind: ChartKind
    let visible: [SeriesData]
    let metric: AnalyticsMetric
    let log: Bool
    let showOverlays: Bool
    var points: [Pt] = []
    var previous: [Mark]?
    var movingAverage: [Mark]?
    var forecastLine: [Mark]?
    var outlierPoints: [Mark] = []
    var futureDates: [Date] = []
    var forecastValues: [Double] = []
    var yTop: Double = 1
    var yTicks: [Double] = [0, 1]

    var allDates: [Date] { result.starts + futureDates }
    var xDomain: ClosedRange<Date> {
        let first = result.starts.first ?? Date()
        let last = futureDates.last ?? result.starts.last ?? first
        return first...max(last, first.addingTimeInterval(1))
    }

    init(result: AnalyticsResult, kind: ChartKind, hidden: Set<String>, logScale: Bool, overlays: Overlays) {
        self.result = result
        self.kind = kind
        metric = result.metric
        visible = result.series.filter { !hidden.contains($0.key) }
        log = logScale && (kind == .lines || kind == .cumulative)
        showOverlays = kind != .share && kind != .cumulative
        let n = result.starts.count
        let isShare = kind == .share

        func T(_ v: Double) -> Double { log ? Foundation.log10(v + 1) : v }

        var rows: [(String, [Double])] = visible.map { ($0.key, result.values(of: $0)) }
        if kind == .cumulative {
            rows = rows.map { name, ys in var c = 0.0; return (name, ys.map { c += $0; return c }) }
        }
        if isShare {
            let tot = (0..<n).map { i in rows.reduce(0) { $0 + $1.1[i] } }
            rows = rows.map { name, ys in (name, ys.indices.map { tot[$0] > 0 ? ys[$0] / tot[$0] : 0 }) }
        }
        var id = 0
        var maxY = 0.0
        let stacked = kind == .stacked || kind == .bars || isShare
        for (name, ys) in rows {
            for i in 0..<n {
                points.append(Pt(id: id, series: name, date: result.starts[i], y: T(ys[i])))
                id += 1
                if !stacked { maxY = max(maxY, T(ys[i])) }
            }
        }
        if stacked {
            for i in 0..<n { maxY = max(maxY, rows.reduce(0) { $0 + $1.1[i] }) }
            if isShare { maxY = 1 }
        }

        if showOverlays {
            if overlays.comparePrevious {
                previous = result.previousValues.enumerated().map { Mark(id: $0.offset, date: result.starts[$0.offset], y: T($0.element)) }
                maxY = max(maxY, previous?.map(\.y).max() ?? 0)
            }
            if overlays.movingAverage {
                movingAverage = result.movingAverage.enumerated().map { Mark(id: $0.offset, date: result.starts[$0.offset], y: T($0.element)) }
                maxY = max(maxY, movingAverage?.map(\.y).max() ?? 0)
            }
            if overlays.forecast {
                let fc = result.forecast
                forecastValues = fc
                if let last = result.starts.last {
                    let cal = Calendar.current
                    futureDates = fc.indices.compactMap {
                        cal.date(byAdding: result.granularity.component, value: $0 + 1, to: last)
                    }
                    let tv = result.totalValues
                    if let lastVal = tv.last, futureDates.count == fc.count {
                        var line = [Mark(id: 0, date: last, y: T(lastVal))]
                        for (k, pair) in zip(futureDates, fc).enumerated() { line.append(Mark(id: k + 1, date: pair.0, y: T(pair.1))) }
                        forecastLine = line
                        maxY = max(maxY, fc.map(T).max() ?? 0)
                    }
                }
            }
            if overlays.outliers {
                let tv = result.totalValues
                outlierPoints = result.outliers.map { Mark(id: $0, date: result.starts[$0], y: T(tv[$0])) }
            }
        }

        if maxY <= 0 { maxY = 1 }
        if isShare {
            yTop = 1
            yTicks = [0, 0.25, 0.5, 0.75, 1]
        } else if log {
            yTop = maxY * 1.04
            var ticks: [Double] = []
            var e = 0.0
            while e <= yTop { ticks.append(e); e += 1 }
            yTicks = ticks.count > 1 ? ticks : [0, yTop]
        } else {
            yTop = Self.niceTop(maxY * 1.08)
            yTicks = (0...4).map { yTop * Double($0) / 4 }
        }
    }

    func yLabel(_ v: Double) -> String {
        if kind == .share { return "\(Int((v * 100).rounded()))%" }
        return metric.format(log ? pow(10, v) - 1 : v)
    }

    static func niceTop(_ v: Double) -> Double {
        guard v > 0 else { return 1 }
        let p = pow(10, floor(log10(v)))
        let n = v / p
        return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 2.5 ? 2.5 : n <= 5 ? 5 : 10) * p
    }

    func label(for date: Date) -> String {
        bucketHeader(date, unit: result.granularity.unit)
    }

    /// Tooltip content for bucket index `i` (indices past the actuals are forecast buckets).
    func tip(at i: Int, palette: SeriesPalette) -> Tip {
        let n = result.starts.count
        guard i >= 0 else { return Tip(header: "") }
        guard i < n else {
            let k = i - n
            guard k >= 0, k < futureDates.count else { return Tip(header: "") }
            var t = Tip(header: "Forecast · \(label(for: futureDates[k]))")
            if k < forecastValues.count { t.rows = [(.blue, "Linear trend", metric.format(forecastValues[k]))] }
            return t
        }
        var t = Tip(header: label(for: result.starts[i]))
        t.rows = visible.reversed().map { s in
            (palette.color(s.key), s.key, metric.format(metric.value(s.buckets[i])))
        }
        t.total = metric.format(metric.value(result.totals[i]))
        if showOverlays, previous != nil {
            let pv = metric.value(result.previous[i]), cv = metric.value(result.totals[i])
            if pv > 0 {
                let d = (cv - pv) / pv * 100
                t.extras.append((String(format: "vs previous period %+.0f%%", d), d >= 0 ? .green : .red))
            }
        }
        if showOverlays, result.outliers.contains(i) { t.extras.append(("Outlier (above 2σ)", .red)) }
        return t
    }
}

private extension View {
    @ViewBuilder func chartXScaleIfNeeded(_ apply: Bool, domain: ClosedRange<Date>) -> some View {
        if apply { self.chartXScale(domain: domain) } else { self }
    }
}

/// Hover guide, tooltip and click-to-pin. Owns its own @State so hovering is cheap.
private struct ChartHoverLayer: View {
    let proxy: ChartProxy
    let dates: [Date]
    let bucketCount: Int
    let tip: (Int) -> ChartPlot.Tip
    let onTap: (Int) -> Void
    @State private var hover: (index: Int, point: CGPoint)?

    var body: some View {
        GeometryReader { geo in
            let frame = proxy.plotFrame.map { geo[$0] } ?? .zero
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hover = nearest(p.x - frame.minX).map { ($0, p) }
                        case .ended: hover = nil
                        }
                    }
                    .onChange(of: dates) { _, _ in hover = nil }
                    .onTapGesture { location in
                        if let i = nearest(location.x - frame.minX), i < bucketCount { onTap(i) }
                    }
                if let h = hover, h.index < dates.count, let gx = proxy.position(forX: dates[h.index]) {
                    Rectangle().fill(Color.secondary.opacity(0.6))
                        .frame(width: 1, height: frame.height)
                        .offset(x: frame.minX + gx, y: frame.minY)
                        .allowsHitTesting(false)
                    tooltip(tip(h.index))
                        .offset(x: min(frame.minX + gx + 14, geo.size.width - 210), y: max(4, min(h.point.y - 20, geo.size.height - 150)))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func nearest(_ x: CGFloat) -> Int? {
        guard !dates.isEmpty, let d: Date = proxy.value(atX: x) else { return nil }
        var lo = 0, hi = dates.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if dates[mid] < d { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(dates[lo - 1].timeIntervalSince(d)) < abs(dates[lo].timeIntervalSince(d)) { lo -= 1 }
        return lo
    }

    private func tooltip(_ t: ChartPlot.Tip) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t.header).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(t.rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2).fill(r.0).frame(width: 8, height: 8)
                    Text(r.1).font(.caption)
                    Spacer(minLength: 12)
                    Text(r.2).font(.caption.monospacedDigit().weight(.semibold))
                }
            }
            if let total = t.total {
                Divider()
                HStack { Text("Total").font(.caption); Spacer(); Text(total).font(.caption.monospacedDigit().weight(.semibold)) }
            }
            ForEach(Array(t.extras.enumerated()), id: \.offset) { _, e in
                Text(e.0).font(.caption).foregroundStyle(e.1)
            }
        }
        .padding(9)
        .frame(width: 196)
        .background(.regularMaterial, in: .rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}
