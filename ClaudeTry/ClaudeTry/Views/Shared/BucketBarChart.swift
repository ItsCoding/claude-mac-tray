import SwiftUI
import Charts

/// Stacked-by-model bar chart with a hover tooltip. Used for cost (Overview),
/// tokens (Charts) and per-project cost (Projects) so interaction is identical.
struct BucketBarChart: View {
    enum Metric { case cost, tokens, count }

    let buckets: [ModelBucket]
    let unit: BucketUnit
    var metric: Metric = .cost
    var height: CGFloat = 200

    @State private var selected: Date?

    private let tooltipWidth: CGFloat = 150

    private var colorMap: [String: Color] {
        let s = ModelStyle.scale(for: buckets.map(\.model))
        return Dictionary(uniqueKeysWithValues: zip(s.domain, s.range))
    }

    private var uniqueDates: [Date] { Array(Set(buckets.map(\.date))).sorted() }
    private func value(_ b: ModelBucket) -> Double {
        switch metric {
        case .cost:   return b.cost
        case .tokens: return Double(b.totalTokens)
        case .count:  return Double(b.inputTokens)
        }
    }
    private func format(_ v: Double) -> String {
        switch metric {
        case .cost:   return String(format: "$%.2f", v)
        case .tokens: return Int(v).abbrev
        case .count:  return "\(Int(v))"
        }
    }
    private var selectedRows: [ModelBucket] {
        guard let selected else { return [] }
        return buckets.filter { $0.date == selected }.sorted { value($0) > value($1) }
    }

    var body: some View {
        let scale = ModelStyle.scale(for: buckets.map(\.model))
        Chart {
            ForEach(buckets) { b in
                BarMark(
                    x: .value("Date", b.date, unit: unit.calendarComponent),
                    y: .value(metric == .cost ? "Cost" : "Tokens", value(b))
                )
                .foregroundStyle(by: .value("Model", b.model))
                .opacity(selected == nil || b.date == selected ? 1 : 0.3)
            }
            if let selected {
                RuleMark(x: .value("Date", selected))
                    .foregroundStyle(Color.secondary.opacity(0.25))
            }
        }
        .chartForegroundStyleScale(domain: scale.domain, range: scale.range)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        switch metric {
                        case .cost:   Text(v.formatted(.currency(code: "USD").precision(.fractionLength(0))))
                        case .tokens: Text(Int(v).abbrev)
                        case .count:  Text("\(Int(v))")
                        }
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: height)
        .animation(.easeOut(duration: 0.12), value: selected)
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let pt):
                                guard let plot = proxy.plotFrame else { return }
                                let x = pt.x - geo[plot].minX
                                if let date = proxy.value(atX: x, as: Date.self) {
                                    selected = uniqueDates.min {
                                        abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date))
                                    }
                                }
                            case .ended:
                                selected = nil
                            }
                        }

                    if let selected, !selectedRows.isEmpty, let plot = proxy.plotFrame,
                       let pos = proxy.position(forX: selected) {
                        let frame = geo[plot]
                        let x = min(max(frame.minX + pos - tooltipWidth / 2, frame.minX),
                                    frame.maxX - tooltipWidth)
                        tooltip(for: selected)
                            .offset(x: x, y: frame.minY + 4)
                    }
                }
            }
        }
    }

    private func tooltip(for date: Date) -> some View {
        let total = selectedRows.reduce(0) { $0 + value($1) }
        return VStack(alignment: .leading, spacing: 4) {
            Text(bucketHeader(date, unit: unit))
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(selectedRows) { b in
                HStack(spacing: 6) {
                    Circle().fill(colorMap[b.model] ?? .gray).frame(width: 6, height: 6)
                    Text(b.model).font(.caption2)
                    Spacer(minLength: 10)
                    Text(format(value(b))).font(.caption2.monospacedDigit())
                }
            }
            if selectedRows.count > 1 {
                Divider()
                HStack {
                    Text("Total").font(.caption2.weight(.semibold))
                    Spacer()
                    Text(format(total)).font(.caption2.monospacedDigit().weight(.semibold))
                }
            }
        }
        .padding(8)
        .frame(width: tooltipWidth)
        .glassCard(cornerRadius: 10)
    }
}
