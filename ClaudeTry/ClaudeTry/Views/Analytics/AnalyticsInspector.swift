import SwiftUI
import Charts

/// Right-hand inspector. Scope is the pinned bucket when there is one, otherwise
/// the whole window. Deltas compare against the equal-length period before it.
struct AnalyticsInspector: View {
    @Bindable var vm: AnalyticsViewModel

    var body: some View {
        ScrollView {
            if let r = vm.result {
                content(r)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            }
        }
        .analyticsPanel(padding: 14)
    }

    @ViewBuilder
    private func content(_ r: AnalyticsResult) -> some View {
        let pin = vm.pin.flatMap { $0 < r.bucketCount ? $0 : nil }
        let acc = pin.map { r.totals[$0] } ?? r.windowTotal
        let prev = pin.map { r.previous[$0] } ?? r.previousTotal
        let palette = SeriesPalette(names: r.series.map(\.key))
        VStack(alignment: .leading, spacing: 14) {
            SectionCaption(pin.map { "Pinned · " + bucketHeader(r.starts[$0], unit: r.granularity.unit) } ?? "Window · \(rangeName)")

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach([AnalyticsMetric.cost, .tokens, .linesAdded, .sessions, .cacheHit, .costPerLine]) { m in
                    kpi(m, acc: acc, prev: prev)
                }
            }

            sparkline(r)

            shares(r, pin: pin, palette: palette)

            if vm.state.overlays.outliers { outliers(r) }

            topSessions(r, pin: pin)
        }
    }

    private var rangeName: String {
        vm.state.range == .zoom ? "zoomed" : vm.state.range.rawValue
    }

    private func kpi(_ m: AnalyticsMetric, acc: MetricAccumulator, prev: MetricAccumulator) -> some View {
        let v = m.value(acc), p = m.value(prev)
        let delta: Double? = p > 0 ? (v - p) / p : nil
        let good = delta.map { (m.risingIsBad ? $0 <= 0 : $0 >= 0) }
        return VStack(alignment: .leading, spacing: 1) {
            Text(m.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(m.format(v)).font(.title3.weight(.semibold).monospacedDigit())
            if let delta {
                Text("\(delta >= 0 ? "▲" : "▼") \(Int((abs(delta) * 100).rounded()))% vs prev")
                    .font(.caption2).foregroundStyle(good == true ? Color.green : Color.red)
            } else {
                Text("no prior data").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8))
    }

    @ViewBuilder
    private func sparkline(_ r: AnalyticsResult) -> some View {
        let vals = r.totalValues
        if vals.count > 1 {
            Chart(Array(vals.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("i", i), y: .value("v", v))
                    .foregroundStyle(Color.accentColor).interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
            .frame(height: 44)
        }
    }

    private func shares(_ r: AnalyticsResult, pin: Int?, palette: SeriesPalette) -> some View {
        let rows = r.series.map { s -> (String, Double) in
            let a = pin.map { s.buckets[$0] } ?? MetricAccumulator.sum(s.buckets)
            return (s.key, r.metric.value(a))
        }.sorted { $0.1 > $1.1 }
        let peak = max(rows.first?.1 ?? 0, 1e-9)
        return VStack(alignment: .leading, spacing: 4) {
            SectionCaption("\(r.query.groupBy.rawValue) · click to focus")
            if rows.isEmpty { Text("Nothing in scope").font(.caption).foregroundStyle(.secondary) }
            ForEach(rows, id: \.0) { name, v in
                Button { vm.focus = vm.focus == name ? nil : name } label: {
                    VStack(spacing: 3) {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(palette.color(name)).frame(width: 8, height: 8)
                            Text(name).font(.callout).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(r.metric.format(v)).font(.callout.monospacedDigit().weight(.semibold))
                        }
                        GeometryReader { g in
                            Capsule().fill(Color.primary.opacity(0.07))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(palette.color(name)).frame(width: g.size.width * max(0, v) / peak)
                                }
                        }
                        .frame(height: 3)
                    }
                    .padding(4)
                    .background(vm.focus == name ? Color.primary.opacity(0.12) : .clear, in: .rect(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func outliers(_ r: AnalyticsResult) -> some View {
        let tv = r.totalValues
        return VStack(alignment: .leading, spacing: 4) {
            SectionCaption("Outliers · click to pin")
            if r.outliers.isEmpty {
                Text("No outlier buckets in window").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(r.outliers.prefix(6), id: \.self) { i in
                Button { vm.pin = i } label: {
                    HStack {
                        Text(bucketHeader(r.starts[i], unit: r.granularity.unit)).font(.callout)
                        Spacer()
                        Text(r.metric.format(tv[i])).font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(.red)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func topSessions(_ r: AnalyticsResult, pin: Int?) -> some View {
        var rows = r.sessions
        if let pin {
            let a = r.starts[pin]
            let b = Calendar.current.date(byAdding: r.granularity.component, value: 1, to: a) ?? a
            rows = rows.filter { $0.start >= a && $0.start < b }
        }
        let top = rows.sorted { $0.cost > $1.cost }.prefix(5)
        return VStack(alignment: .leading, spacing: 4) {
            SectionCaption("Top sessions by cost · click to search")
            if top.isEmpty { Text("None in selection").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(top)) { s in
                Button { vm.showTable(searching: s.id) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text("\(s.project) · \(s.model)").font(.callout).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(AnalyticsFormat.money(s.cost)).font(.callout.monospacedDigit().weight(.semibold))
                        }
                        Text("\(s.start.formatted(.dateTime.month(.abbreviated).day().hour().minute()))\(s.isSubagent ? " · subagent" : "") · \(s.messages) msgs · \(s.linesAdded) lines · \(String(format: "%.1f", s.durationSec / 60)) min")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().opacity(0.5)
            }
        }
    }
}
