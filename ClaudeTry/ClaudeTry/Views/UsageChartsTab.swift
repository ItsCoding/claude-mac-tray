import SwiftUI
import Charts

struct UsageChartsTab: View {
    @Environment(UsageStore.self) private var store
    @State private var range = RangeState(mode: .week)
    @State private var selectedDate: Date?

    private var interval: DateInterval { range.interval }
    private var buckets: [ModelBucket] { store.modelBuckets(in: interval) }
    private var unit: BucketUnit { store.bucketUnit(in: interval) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                RangePicker(range: $range)

                section("Tokens by model") {
                    if buckets.isEmpty {
                        empty("chart.bar")
                    } else {
                        BucketBarChart(buckets: buckets, unit: unit, metric: .tokens, height: 180)
                    }
                }

                section("Cumulative cost") {
                    cumulativeChart
                }

                section("Token composition") {
                    compositionChart
                }

                section("Insights") {
                    insights
                }

                section("Top tools") {
                    topTools
                }
            }
            .padding()
        }
    }

    @ViewBuilder private var cumulativeChart: some View {
        let growth = store.cumulativeCost(in: interval)
        if growth.count < 2 {
            empty("dollarsign.circle")
        } else {
            let total = growth.last?.cumulative ?? 0
            Chart {
                ForEach(growth, id: \.date) { item in
                    LineMark(x: .value("Date", item.date), y: .value("Cost", item.cumulative))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.indigo)
                    AreaMark(x: .value("Date", item.date), y: .value("Cost", item.cumulative))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.linearGradient(colors: [.indigo.opacity(0.25), .indigo.opacity(0.02)],
                                                         startPoint: .top, endPoint: .bottom))
                }
                if let selectedDate, let point = nearestPoint(growth, to: selectedDate) {
                    RuleMark(x: .value("Date", point.date))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                        .annotation(position: .top, spacing: 6,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(point.date.formatted(.dateTime.day().month(.abbreviated)))
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(String(format: "$%.2f", point.cumulative))
                                    .font(.caption.monospacedDigit().weight(.semibold))
                            }
                            .padding(8)
                            .glassCard(cornerRadius: 10)
                        }
                }
            }
            .chartYAxis { AxisMarks(format: .currency(code: "USD").precision(.fractionLength(0))) }
            .frame(height: 150)
            .overlay(alignment: .topTrailing) {
                Text(String(format: "Total %.2f USD", total))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let pt):
                                guard let plot = proxy.plotFrame else { return }
                                if let date = proxy.value(atX: pt.x - geo[plot].minX, as: Date.self) {
                                    selectedDate = date
                                }
                            case .ended: selectedDate = nil
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder private var compositionChart: some View {
        let t = store.tokenTotals(in: interval)
        let parts: [(String, Int, Color)] = [
            ("Input", t.input, .blue), ("Output", t.output, .green),
            ("Cache read", t.cacheRead, .teal), ("Cache write", t.cacheWrite, .orange),
        ].filter { $0.1 > 0 }
        let total = parts.reduce(0) { $0 + $1.1 }
        if parts.isEmpty {
            empty("chart.pie")
        } else {
            Chart(parts, id: \.0) { part in
                SectorMark(angle: .value("Tokens", part.1), innerRadius: .ratio(0.62), angularInset: 1.5)
                    .foregroundStyle(by: .value("Kind", part.0))
                    .cornerRadius(4)
            }
            .chartForegroundStyleScale(domain: parts.map(\.0), range: parts.map(\.2))
            .chartBackground { _ in
                VStack(spacing: 0) {
                    Text(total.abbrev).font(.title3.weight(.semibold).monospacedDigit())
                    Text("tokens").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .chartLegend(position: .bottom, spacing: 10)
            .frame(height: 200)
        }
    }

    @ViewBuilder private var insights: some View {
        let saved = store.cacheSavings(in: interval)
        let busiest = store.busiestHour(in: interval)
        let avg = store.avgSessionMinutes(in: interval)
        HStack(spacing: 8) {
            InsightTile(icon: "bolt.fill", tint: .green, title: "Cache saved",
                        value: String(format: "$%.0f", saved))
            InsightTile(icon: "clock.fill", tint: .teal, title: "Peak hour",
                        value: busiest.map { String(format: "%02d:00", $0.hour) } ?? "—")
            InsightTile(icon: "timer", tint: .orange, title: "Avg session",
                        value: avg.map { $0 >= 1 ? "\(Int($0))m" : "<1m" } ?? "—")
        }
    }

    @ViewBuilder private var topTools: some View {
        let tools = store.topToolCalls(in: interval)
        if tools.isEmpty {
            empty("wrench.and.screwdriver")
        } else {
            let maxCount = tools.first?.count ?? 1
            VStack(spacing: 4) {
                ForEach(tools.prefix(6), id: \.name) { tool in
                    HStack(spacing: 8) {
                        Text(tool.name).font(.caption).frame(width: 80, alignment: .leading)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.indigo.gradient)
                                .frame(width: max(4, geo.size.width * CGFloat(tool.count) / CGFloat(maxCount)))
                        }
                        .frame(height: 12)
                        Text("\(tool.count)").font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func nearestPoint(_ points: [(date: Date, cumulative: Double)], to date: Date) -> (date: Date, cumulative: Double)? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func empty(_ symbol: String) -> some View {
        ContentUnavailableView("No data", systemImage: symbol).frame(height: 120)
    }
}
