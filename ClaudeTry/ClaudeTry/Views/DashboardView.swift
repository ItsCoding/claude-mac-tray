import SwiftUI
import Charts

/// Single-screen usage dashboard. Replaces the old three-tab layout: one shared
/// range drives every section, and a ScrollView lets the content fill the popover
/// instead of leaving dead space below a fixed frame.
struct DashboardView: View {
    @Environment(UsageStore.self) private var store
    var onHeight: (CGFloat) -> Void = { _ in }
    @State private var range = RangeState(mode: .today)
    @State private var activity: Activity = .cost
    @State private var hoverDate: Date?
    @State private var expandedProject: String?
    @State private var expanded = false

    private enum Activity: String, CaseIterable { case cost = "Cost", tokens = "Tokens" }

    private var interval: DateInterval { range.interval }
    private var filtered: [Session] { store.filteredSessions(in: interval) }
    private var totals: TokenCount { store.tokenTotals(in: interval) }
    private var buckets: [ModelBucket] { store.modelBuckets(in: interval) }
    private var unit: BucketUnit { store.bucketUnit(in: interval) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        heroCard(compact: false)
                        if buckets.isEmpty {
                            ContentUnavailableView("No usage in this range", systemImage: "chart.bar")
                                .frame(height: 260)
                        } else {
                            activitySection
                            HStack(alignment: .top, spacing: 12) {
                                compositionSection.frame(maxWidth: .infinity)
                                insightsSection.frame(width: 150)
                            }
                            cumulativeSection
                            toolsSection
                            projectsSection
                        }
                        expandToggle
                    }
                    .padding(16)
                }
                .frame(height: 520)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    heroCard(compact: true)
                    if buckets.isEmpty {
                        ContentUnavailableView("No usage today", systemImage: "chart.bar")
                            .frame(height: 200)
                    } else {
                        activitySection
                    }
                    expandToggle
                }
                .padding(16)
            }
        }
        .frame(width: 460)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { onHeight(proxy.size.height) }
                .onChange(of: proxy.size.height) { _, h in onHeight(h) }
        })
    }

    /// Subtle bottom control: dots reveal the full dashboard + range controls;
    /// a chevron collapses back to the glance view.
    private var expandToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() }
        } label: {
            Image(systemName: expanded ? "chevron.compact.up" : "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Show less" : "Show details")
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.callout).foregroundStyle(.indigo)
                Text("Claude Usage").font(.headline)
                Spacer()
            }
            if expanded { RangePicker(range: $range) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: Hero

    private var costString: String {
        store.totalCost(in: interval).map { String(format: "$%.2f", $0) } ?? "—"
    }
    private var avgCostSubtitle: String? {
        guard !filtered.isEmpty, let cost = store.totalCost(in: interval), cost > 0 else { return nil }
        return String(format: "$%.2f per session", cost / Double(filtered.count))
    }

    private func heroCard(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Total cost · \(range.mode.rawValue)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(costString)
                    .font(.system(size: compact ? 27 : 38, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let avgCostSubtitle {
                    Text(avgCostSubtitle).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Divider()
            HStack(spacing: 0) {
                heroMetric("Tokens", (totals.input + totals.output).abbrev,
                           sub: totals.cacheRead > 0 ? "+\(totals.cacheRead.abbrev) cached" : nil,
                           compact: compact)
                heroDivider
                heroMetric("Sessions", "\(filtered.count)", compact: compact)
                heroDivider
                heroMetric("Projects", "\(Set(filtered.map(\.projectPath)).count)", compact: compact)
            }
        }
        .padding(compact ? 13 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: compact ? 16 : 18)
    }

    private func heroMetric(_ title: String, _ value: String, sub: String? = nil, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font((compact ? Font.body : .title3).weight(.semibold).monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
            if let sub { Text(sub).font(.caption2).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroDivider: some View {
        Rectangle().fill(.secondary.opacity(0.15)).frame(width: 1, height: 24)
    }

    // MARK: Sections

    private var activitySection: some View {
        section("Activity") {
            Picker("", selection: $activity) {
                ForEach(Activity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)
            .controlSize(.small)
        } content: {
            BucketBarChart(buckets: buckets, unit: unit,
                           metric: activity == .cost ? .cost : .tokens, height: 200)
        }
    }

    private var compositionSection: some View {
        section("Token mix") {
            let t = totals
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
                        Text(total.abbrev).font(.callout.weight(.semibold).monospacedDigit())
                        Text("tokens").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .chartLegend(position: .bottom, spacing: 8)
                .frame(height: 180)
            }
        }
    }

    private var insightsSection: some View {
        section("Insights") {
            VStack(spacing: 8) {
                InsightTile(icon: "bolt.fill", tint: .green, title: "Cache saved",
                            value: String(format: "$%.0f", store.cacheSavings(in: interval)))
                InsightTile(icon: "clock.fill", tint: .teal, title: "Peak hour",
                            value: store.busiestHour(in: interval).map { String(format: "%02d:00", $0.hour) } ?? "—")
                InsightTile(icon: "timer", tint: .orange, title: "Avg session",
                            value: store.avgSessionMinutes(in: interval).map { $0 >= 1 ? "\(Int($0))m" : "<1m" } ?? "—")
            }
        }
    }

    @ViewBuilder private var cumulativeSection: some View {
        let growth = store.cumulativeCost(in: interval)
        if growth.count >= 2 {
            section("Cumulative cost") {
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
                    if let hoverDate, let point = nearest(growth, to: hoverDate) {
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
                                .padding(8).glassCard(cornerRadius: 10)
                            }
                    }
                }
                .chartYAxis { AxisMarks(format: .currency(code: "USD").precision(.fractionLength(0))) }
                .frame(height: 140)
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
                                        hoverDate = date
                                    }
                                case .ended: hoverDate = nil
                                }
                            }
                    }
                }
            }
        }
    }

    @ViewBuilder private var toolsSection: some View {
        let tools = store.topToolCalls(in: interval)
        if !tools.isEmpty {
            section("Top tools") {
                let maxCount = tools.first?.count ?? 1
                VStack(spacing: 5) {
                    ForEach(tools.prefix(6), id: \.name) { tool in
                        HStack(spacing: 8) {
                            Text(tool.name).font(.caption).frame(width: 90, alignment: .leading)
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(.indigo.gradient)
                                    .frame(width: max(4, geo.size.width * CGFloat(tool.count) / CGFloat(maxCount)))
                            }
                            .frame(height: 12)
                            Text("\(tool.count)").font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private var projectsSection: some View {
        section("Projects") {
            let projects = store.projects.sorted { projectCost($0) > projectCost($1) }
            if projects.isEmpty {
                empty("folder")
            } else {
                VStack(spacing: 0) {
                    ForEach(projects) { project in
                        ProjectRow(
                            project: project,
                            cost: projectCost(project),
                            isExpanded: expandedProject == project.id,
                            buckets: store.modelBuckets(fromSessions: project.sessions),
                            unit: store.bucketUnit(forSessions: project.sessions)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                expandedProject = expandedProject == project.id ? nil : project.id
                            }
                        }
                        if project.id != projects.last?.id { Divider().opacity(0.4) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .glassCard(cornerRadius: 14)
            }
        }
    }

    // MARK: Helpers

    private func projectCost(_ p: ProjectSummary) -> Double {
        p.sessions.reduce(0) { $0 + (ModelPricing.cost(for: $1) ?? 0) }
    }

    private func nearest(_ points: [(date: Date, cumulative: Double)], to date: Date) -> (date: Date, cumulative: Double)? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    /// Section with a title, an optional trailing accessory, and its content.
    @ViewBuilder
    private func section(_ title: String,
                         @ViewBuilder accessory: () -> some View = { EmptyView() },
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                accessory()
            }
            content()
        }
    }

    private func empty(_ symbol: String) -> some View {
        ContentUnavailableView("No data", systemImage: symbol).frame(height: 120)
    }
}

/// One project row; tapping reveals its cost-over-time chart and model mix.
private struct ProjectRow: View {
    let project: ProjectSummary
    let cost: Double
    let isExpanded: Bool
    let buckets: [ModelBucket]
    let unit: BucketUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2).foregroundStyle(.tertiary).frame(width: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name).font(.system(.callout, design: .rounded)).fontWeight(.medium)
                    if let last = project.lastActive {
                        Text("Last active \(last.formatted(.relative(presentation: .named)))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "$%.2f", cost))
                        .font(.callout.monospacedDigit().weight(.semibold))
                    Text("\(project.totalSessions) sessions")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if isExpanded {
                if buckets.isEmpty {
                    Text("No cost data for this project")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    BucketBarChart(buckets: buckets, unit: unit, metric: .cost, height: 110)
                }
                let breakdown = modelBreakdown
                if !breakdown.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(breakdown, id: \.model) { item in
                            HStack {
                                Circle().fill(ModelStyle.color(item.model)).frame(width: 7, height: 7)
                                Text(item.model).font(.caption2)
                                Spacer()
                                Text("\(item.tokens.abbrev) tokens")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var modelBreakdown: [(model: String, tokens: Int)] {
        var counts: [String: Int] = [:]
        for session in project.sessions {
            for (model, tc) in session.modelBreakdown {
                counts[model, default: 0] += tc.input + tc.output
            }
        }
        return counts.map { (model: $0.key, tokens: $0.value) }.sorted { $0.tokens > $1.tokens }
    }
}
