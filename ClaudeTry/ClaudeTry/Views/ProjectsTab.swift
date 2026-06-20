import SwiftUI
import Charts

enum ProjectSort: String, CaseIterable {
    case cost = "Cost"; case sessions = "Sessions"; case recent = "Recent"
}

struct ProjectsTab: View {
    @Environment(UsageStore.self) private var store
    @State private var sortBy: ProjectSort = .cost
    @State private var expandedProject: String? = nil

    private var sorted: [ProjectSummary] {
        switch sortBy {
        case .cost:     return store.projects.sorted { projectCost($0) > projectCost($1) }
        case .sessions: return store.projects.sorted { $0.totalSessions > $1.totalSessions }
        case .recent:   return store.projects.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("Sort", selection: $sortBy) {
                ForEach(ProjectSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            if sorted.isEmpty {
                ContentUnavailableView("No projects found", systemImage: "folder").frame(maxHeight: .infinity)
            } else {
                List(sorted) { project in
                    ProjectRow(project: project, isExpanded: expandedProject == project.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedProject = expandedProject == project.id ? nil : project.id
                            }
                        }
                }
                .listStyle(.plain)
            }
        }
        .padding(.top)
    }

    private func projectCost(_ p: ProjectSummary) -> Double {
        p.sessions.compactMap { ModelPricing.cost(for: $0) }.reduce(0, +)
    }
}

private struct ProjectRow: View {
    let project: ProjectSummary
    let isExpanded: Bool

    private var totalCost: Double { project.sessions.compactMap { ModelPricing.cost(for: $0) }.reduce(0, +) }
    private var costString: String {
        let hasMissing = project.sessions.contains { ModelPricing.cost(for: $0) == nil }
        if hasMissing && totalCost == 0 { return "—" }
        return String(format: "$%.2f", totalCost)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.system(.body, design: .monospaced)).fontWeight(.medium)
                    if let last = project.lastActive {
                        Text("Last active \(last.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(costString).font(.caption.monospacedDigit().weight(.semibold))
                    Text("\(project.totalSessions) sessions").font(.caption2).foregroundStyle(.secondary)
                }
            }

            if isExpanded {
                Divider()
                let monthly = monthlyCostBuckets(project)
                if monthly.count > 1 {
                    Chart(monthly, id: \.date) { item in
                        BarMark(x: .value("Month", item.date, unit: .month), y: .value("Cost", item.cost))
                            .foregroundStyle(.blue)
                    }
                    .frame(height: 60)
                }
                let breakdown = modelBreakdown(project)
                if !breakdown.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model Mix").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(breakdown, id: \.model) { item in
                            HStack {
                                Text(item.model).font(.caption)
                                Spacer()
                                Text("\(item.tokens.formatted()) tokens")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func monthlyCostBuckets(_ project: ProjectSummary) -> [(date: Date, cost: Double)] {
        let cal = Calendar.current
        var map: [Date: Double] = [:]
        for session in project.sessions {
            guard let cost = ModelPricing.cost(for: session) else { continue }
            let month = cal.date(from: cal.dateComponents([.year, .month], from: session.startTime))!
            map[month, default: 0] += cost
        }
        return map.map { (date: $0.key, cost: $0.value) }.sorted { $0.date < $1.date }
    }

    private func modelBreakdown(_ project: ProjectSummary) -> [(model: String, tokens: Int)] {
        var counts: [String: Int] = [:]
        for session in project.sessions {
            for (model, tc) in session.modelBreakdown {
                counts[model, default: 0] += tc.input + tc.output
            }
        }
        return counts.map { (model: $0.key, tokens: $0.value) }.sorted { $0.tokens > $1.tokens }
    }
}
