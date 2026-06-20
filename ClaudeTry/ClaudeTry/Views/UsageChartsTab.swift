import SwiftUI
import Charts

struct UsageChartsTab: View {
    @Environment(UsageStore.self) private var store
    @State private var period: TimePeriod = .thisWeek

    private var buckets: [DailyBucket] { store.dailyTokenBuckets(for: period) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PeriodPicker(selection: $period)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Tokens by Model").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if buckets.isEmpty {
                        ContentUnavailableView("No data", systemImage: "chart.bar").frame(height: 150)
                    } else {
                        Chart {
                            ForEach(buckets) { bucket in
                                ForEach(bucket.modelTokens.sorted(by: { $0.key < $1.key }), id: \.key) { model, tokens in
                                    BarMark(
                                        x: .value("Day", bucket.date, unit: .day),
                                        y: .value("Tokens", tokens)
                                    )
                                    .foregroundStyle(by: .value("Model", shortModelName(model)))
                                }
                            }
                        }
                        .frame(height: 150)
                        .chartLegend(position: .bottom)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Cost Over Time").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    let costBuckets = costByDay()
                    if costBuckets.isEmpty {
                        ContentUnavailableView("No cost data", systemImage: "dollarsign.circle").frame(height: 120)
                    } else {
                        Chart(costBuckets, id: \.date) { item in
                            LineMark(x: .value("Day", item.date, unit: .day), y: .value("Cost", item.cost))
                                .interpolationMethod(.catmullRom)
                            AreaMark(x: .value("Day", item.date, unit: .day), y: .value("Cost", item.cost))
                                .foregroundStyle(.blue.opacity(0.15))
                                .interpolationMethod(.catmullRom)
                        }
                        .frame(height: 120)
                        .chartYAxis { AxisMarks(format: .currency(code: "USD")) }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Input vs Output Tokens").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    let sessions = store.filteredSessions(for: period)
                    let totalIn = sessions.reduce(0) { $0 + $1.totalInputTokens }
                    let totalOut = sessions.reduce(0) { $0 + $1.totalOutputTokens }
                    if totalIn + totalOut == 0 {
                        ContentUnavailableView("No data", systemImage: "chart.pie").frame(height: 80)
                    } else {
                        Chart {
                            SectorMark(angle: .value("Tokens", totalIn))
                                .foregroundStyle(.blue)
                                .annotation(position: .overlay) {
                                    Text("Input\n\(totalIn.formatted())").font(.caption2).multilineTextAlignment(.center)
                                }
                            SectorMark(angle: .value("Tokens", totalOut))
                                .foregroundStyle(.green)
                                .annotation(position: .overlay) {
                                    Text("Output\n\(totalOut.formatted())").font(.caption2).multilineTextAlignment(.center)
                                }
                        }
                        .frame(height: 120)
                    }
                }
            }
            .padding()
        }
    }

    private func shortModelName(_ model: String) -> String {
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        if model.contains("fable") { return "Fable" }
        return model
    }

    private func costByDay() -> [(date: Date, cost: Double)] {
        let cal = Calendar.current
        var map: [Date: Double] = [:]
        for session in store.filteredSessions(for: period) {
            guard let cost = ModelPricing.cost(for: session) else { continue }
            let day = cal.startOfDay(for: session.startTime)
            map[day, default: 0] += cost
        }
        return map.map { (date: $0.key, cost: $0.value) }.sorted { $0.date < $1.date }
    }
}
