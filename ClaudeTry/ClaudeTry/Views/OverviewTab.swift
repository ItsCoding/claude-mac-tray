import SwiftUI
import Charts

struct OverviewTab: View {
    @Environment(UsageStore.self) private var store
    @State private var period: TimePeriod = .today

    private var filtered: [Session] { store.filteredSessions(for: period) }
    private var totalTokens: Int { filtered.reduce(0) { $0 + $1.totalInputTokens + $1.totalOutputTokens } }
    private var costString: String {
        if let cost = store.totalCost(for: period) { return String(format: "$%.2f", cost) }
        return "—"
    }
    private var activeProjects: Int { Set(filtered.map(\.projectPath)).count }
    private var buckets: [DailyBucket] { store.dailyTokenBuckets(for: period) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PeriodPicker(selection: $period)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                StatCard(title: "Tokens", value: totalTokens.formatted())
                StatCard(title: "Cost", value: costString)
                StatCard(title: "Sessions", value: "\(filtered.count)")
                StatCard(title: "Projects", value: "\(activeProjects)")
            }

            if buckets.isEmpty {
                ContentUnavailableView("No data for this period", systemImage: "chart.bar")
                    .frame(height: 120)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Daily Token Usage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Chart(buckets) { bucket in
                        BarMark(
                            x: .value("Day", bucket.date, unit: .day),
                            y: .value("Tokens", bucket.totalInputTokens + bucket.totalOutputTokens)
                        )
                        .foregroundStyle(.blue)
                    }
                    .frame(height: 100)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day)) { _ in
                            AxisTick()
                            AxisGridLine()
                        }
                    }
                }
            }

            if let top = store.projects.first {
                HStack {
                    Text("Most active:").font(.caption).foregroundStyle(.secondary)
                    Text(top.name).font(.caption).fontWeight(.medium)
                }
            }

            Spacer()
        }
        .padding()
    }
}
