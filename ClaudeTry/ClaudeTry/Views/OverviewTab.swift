import SwiftUI
import Charts

struct OverviewTab: View {
    @Environment(UsageStore.self) private var store
    @State private var range = RangeState(mode: .today)

    private var interval: DateInterval { range.interval }
    private var filtered: [Session] { store.filteredSessions(in: interval) }
    private var totals: TokenCount { store.tokenTotals(in: interval) }
    private var buckets: [ModelBucket] { store.modelBuckets(in: interval) }
    private var unit: BucketUnit { store.bucketUnit(in: interval) }

    private var costString: String {
        if let cost = store.totalCost(in: interval) { return String(format: "$%.2f", cost) }
        return "—"
    }
    private var avgCostSubtitle: String? {
        guard !filtered.isEmpty, let cost = store.totalCost(in: interval), cost > 0 else { return nil }
        return String(format: "$%.2f / session", cost / Double(filtered.count))
    }
    private var cacheSubtitle: String? {
        totals.cacheRead > 0 ? "+\(totals.cacheRead.abbrev) cached" : nil
    }
    private var activeProjects: Int { Set(filtered.map(\.projectPath)).count }

    private var topProjects: [(name: String, cost: Double)] {
        Dictionary(grouping: filtered, by: \.projectName)
            .map { (name: $0.key, cost: $0.value.reduce(0) { $0 + (ModelPricing.cost(for: $1) ?? 0) }) }
            .sorted { $0.cost > $1.cost }
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RangePicker(range: $range)

            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 8) { statGrid }
            } else {
                statGrid
            }

            if buckets.isEmpty {
                ContentUnavailableView("No usage in this range", systemImage: "chart.bar")
                    .frame(maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cost by \(unit.label.lowercased())")
                        .font(.subheadline.weight(.semibold))
                    BucketBarChart(buckets: buckets, unit: unit, metric: .cost, height: 230)
                }

                if !topProjects.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Top projects").font(.subheadline.weight(.semibold))
                        ForEach(topProjects, id: \.name) { project in
                            HStack {
                                Image(systemName: "folder").font(.caption2).foregroundStyle(.secondary)
                                Text(project.name).font(.callout)
                                Spacer()
                                Text(String(format: "$%.2f", project.cost))
                                    .font(.callout.monospacedDigit().weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding()
    }

    private var statGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            StatCard(title: "Cost", value: costString, subtitle: avgCostSubtitle,
                     systemImage: "dollarsign.circle.fill", tint: .green)
            StatCard(title: "Tokens", value: (totals.input + totals.output).abbrev, subtitle: cacheSubtitle,
                     systemImage: "number", tint: .indigo)
            StatCard(title: "Sessions", value: "\(filtered.count)",
                     systemImage: "bubble.left.and.bubble.right.fill", tint: .teal)
            StatCard(title: "Projects", value: "\(activeProjects)",
                     systemImage: "folder.fill", tint: .orange)
        }
    }
}
