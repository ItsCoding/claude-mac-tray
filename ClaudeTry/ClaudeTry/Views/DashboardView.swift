import SwiftUI
import Charts

struct DashboardView: View {
    @Environment(UsageStore.self) private var store
    var onHeight: (CGFloat) -> Void = { _ in }
    @State private var range = RangeState(mode: .today)
    @State private var activity: Activity = .cost
    @State private var hoverDate: Date?
    @State private var hoveredHeatmapDay: Date? = nil
    @State private var showingSettings = false
    @State private var showingRange = false
    @State private var galleryPage = 0
    @State private var showRunway = false
    private let installer = StatuslineInstaller.standard()

    private enum Activity: String, CaseIterable {
        case cost = "Cost", tokens = "Tokens", profile = "Profile", tools = "Tools", projects = "Projects", lines = "Lines"
    }
    private let galleryCount = 4

    private var interval: DateInterval { range.interval }
    private var filtered: [Session] { store.filteredSessions(in: interval) }
    private var totals: TokenCount { store.tokenTotals(in: interval) }
    private var buckets: [ModelBucket] { store.modelBuckets(in: interval) }
    private var profileBuckets: [ModelBucket] { store.profileBuckets(in: interval) }
    private var toolBuckets: [ModelBucket] { store.toolBuckets(in: interval) }
    private var projectBuckets: [ModelBucket] { store.projectBuckets(in: interval) }
    private var lineBuckets: [ModelBucket] { store.lineBuckets(in: interval) }
    private var unit: BucketUnit { store.bucketUnit(in: interval) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if !store.isLoaded {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Parsing").font(.subheadline.weight(.medium))
                    Text("Reading usage data…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
            } else {
                galleryView.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 460, height: 570)
        .animation(.easeInOut(duration: 0.2), value: store.isLoaded)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { onHeight(proxy.size.height) }
                .onChange(of: proxy.size.height) { _, h in onHeight(h) }
        })
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle").font(.callout).foregroundStyle(.indigo)
            Text("Claude Usage").font(.headline)
            Spacer()
            Button { showingRange = true } label: {
                Image(systemName: "calendar").font(.callout).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Time range · \(range.mode.rawValue)")
            .popover(isPresented: $showingRange, arrowEdge: .bottom) {
                RangePicker(range: $range).padding(16).frame(minWidth: 300)
            }
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape").font(.callout).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
            .popover(isPresented: $showingSettings, arrowEdge: .bottom) { SettingsView() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: Gallery

    private var galleryView: some View {
        VStack(spacing: 10) {
            ScrollView(.vertical, showsIndicators: false) {
                galleryCard.frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
            galleryNav
        }
    }

    @ViewBuilder
    private var galleryCard: some View {
        switch galleryPage {
        case 0: overviewPage
        case 1: breakdownPage
        case 2: heatmapPage
        default: detailsPage
        }
    }

    private var galleryNav: some View {
        HStack {
            Button {
                galleryPage = max(0, galleryPage - 1)
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .medium))
                    .padding(.vertical, 8).padding(.horizontal, 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(galleryPage == 0 ? Color.secondary.opacity(0.25) : Color.secondary)
            .disabled(galleryPage == 0)

            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<galleryCount, id: \.self) { i in
                    Circle()
                        .fill(i == galleryPage ? Color.primary.opacity(0.5) : Color.secondary.opacity(0.2))
                        .frame(width: 5, height: 5)
                        .onTapGesture { galleryPage = i }
                }
            }
            Spacer()

            Button {
                galleryPage = min(galleryCount - 1, galleryPage + 1)
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .medium))
                    .padding(.vertical, 8).padding(.horizontal, 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(galleryPage == galleryCount - 1 ? Color.secondary.opacity(0.25) : Color.secondary)
            .disabled(galleryPage == galleryCount - 1)
        }
        .padding(.horizontal, 4)
    }

    // MARK: Page 0 — Overview

    private var overviewPage: some View {
        VStack(spacing: 12) {
            heroCard
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                limitsOrRunwayCard
            }
            activityCard
        }
    }

    private var limitsOrRunwayCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Toggle button in top-right corner
            HStack {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showRunway.toggle() }
                } label: {
                    Image(systemName: showRunway ? "gauge.with.dots.needle.67percent" : "timer")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(showRunway ? "Show usage bars" : "Show runway forecast")
            }
            .padding(.bottom, -4)

            if showRunway {
                runwayContent
            } else {
                if installer.isInstalled {
                    let limits = store.limits
                    HStack(alignment: .top, spacing: 12) {
                        LimitBar(title: "Session · 5h", bar: limits.session)
                        Divider().frame(height: 40)
                        LimitBar(title: "Weekly · 7d", bar: limits.weekly)
                    }
                    timingLine(limits: limits)
                } else {
                    connectPrompt
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12)
    }

    private func timingLine(limits: LimitsModel) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "timer").font(.caption2).foregroundStyle(.secondary)
            if limits.timing.activeSessions == 0 {
                Text("No active sessions").font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("API \(TimeFormat.compactDuration(ms: limits.timing.apiMs)) · Wall \(TimeFormat.compactDuration(ms: limits.timing.wallMs))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(limits.timing.activeSessions) active").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var connectPrompt: some View {
        Button(action: { showingSettings = true }) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.horizontal.circle")
                Text("Connect live usage").font(.caption.weight(.medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2)
            }
            .foregroundStyle(.indigo)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var runwayContent: some View {
        let limits = store.limits
        let runway = store.forecastRunway()
        if limits.mode != .anthropic {
            Text("Runway requires the statusline hook (Claude.ai subscription).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .top, spacing: 12) {
                InlineRunwayBar(title: "Session · 5h",
                                fraction: limits.session.fraction,
                                runwayHours: runway.fiveHour,
                                detail: limits.session.detailLabel)
                Divider().frame(height: 40)
                InlineRunwayBar(title: "Weekly · 7d",
                                fraction: limits.weekly.fraction,
                                runwayHours: runway.weekly,
                                detail: limits.weekly.detailLabel)
            }
            timingLine(limits: limits)
        }
    }

    private var costString: String {
        store.totalCost(in: interval).map { String(format: "$%.2f", $0) } ?? "—"
    }
    private var avgCostSubtitle: String? {
        guard !filtered.isEmpty, let cost = store.totalCost(in: interval), cost > 0 else { return nil }
        return String(format: "$%.2f per session", cost / Double(filtered.count))
    }

    private var totalLinesAdded: Int   { filtered.reduce(0) { $0 + $1.linesAdded } }
    private var totalLinesRemoved: Int { filtered.reduce(0) { $0 + $1.linesRemoved } }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Total cost · \(range.mode.rawValue)")
                .font(.caption).foregroundStyle(.secondary)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(costString)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(LinearGradient(
                            colors: [.indigo, .purple],
                            startPoint: .leading, endPoint: .trailing))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if let avgCostSubtitle {
                        Text(avgCostSubtitle).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\((totals.input + totals.output).abbrev) tokens")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    if totals.cacheRead > 0 {
                        Text("+\(totals.cacheRead.abbrev) cached")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            HStack(spacing: 6) {
                HeroStatBadge(icon: "terminal",         color: .teal,   value: "\(filtered.count)",                       label: "sessions")
                HeroStatBadge(icon: "folder.fill",      color: .orange, value: "\(Set(filtered.map(\.projectPath)).count)", label: "projects")
                HeroStatBadge(icon: "plus.square.fill", color: .green,  value: totalLinesAdded.abbrev,                    label: "added")
                HeroStatBadge(icon: "minus.square.fill",color: .red,    value: totalLinesRemoved.abbrev,                   label: "removed")
            }

            if let breakdown = store.profileBreakdown(in: interval) {
                Divider().opacity(0.4)
                profileRow(breakdown)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16)
    }

    private func profileRow(_ breakdown: [(profile: ClaudeProfile, cost: Double, sessions: Int)]) -> some View {
        HStack(spacing: 14) {
            ForEach(breakdown, id: \.profile.rawValue) { item in
                HStack(spacing: 5) {
                    Circle()
                        .fill(item.profile == .anthropic ? Color.indigo : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(item.profile.rawValue).font(.caption2).foregroundStyle(.secondary)
                    Text(String(format: "$%.2f", item.cost))
                        .font(.caption2.monospacedDigit().weight(.medium))
                    Text("·").font(.caption2).foregroundStyle(.tertiary)
                    Text("\(item.sessions) sessions").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity").font(.subheadline.weight(.semibold))
            Picker("", selection: $activity) {
                ForEach(Activity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            switch activity {
            case .cost:     BucketBarChart(buckets: buckets, unit: unit, metric: .cost, height: 130)
            case .tokens:   BucketBarChart(buckets: buckets, unit: unit, metric: .tokens, height: 130)
            case .profile:  BucketBarChart(buckets: profileBuckets, unit: unit, metric: .cost, height: 130)
            case .tools:    BucketBarChart(buckets: toolBuckets, unit: unit, metric: .count, height: 130)
            case .projects:
                if projectBuckets.isEmpty {
                    ContentUnavailableView("No project data", systemImage: "folder").frame(height: 130)
                } else {
                    BucketBarChart(buckets: projectBuckets, unit: unit, metric: .cost, height: 130)
                }
            case .lines:
                if lineBuckets.isEmpty {
                    ContentUnavailableView("No edit data", systemImage: "pencil.and.outline").frame(height: 130)
                } else {
                    BucketBarChart(buckets: lineBuckets, unit: unit, metric: .count, height: 130)
                }
            }
        }
        .padding(13)
        .glassCard(cornerRadius: 16)
    }

    // MARK: Page 1 — Breakdown

    private var breakdownPage: some View {
        VStack(spacing: 12) {
            compositionCard
            cumulativeCard
        }
    }

    private var compositionCard: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Token mix").font(.subheadline.weight(.semibold))
                let t = totals
                let parts: [(String, Int, Color)] = [
                    ("Input", t.input, .blue), ("Output", t.output, .green),
                    ("Cache read", t.cacheRead, .teal), ("Cache write", t.cacheWrite, .orange),
                ].filter { $0.1 > 0 }
                let total = parts.reduce(0) { $0 + $1.1 }
                if parts.isEmpty {
                    ContentUnavailableView("No data", systemImage: "chart.pie").frame(height: 120)
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
                    .frame(height: 170)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                Text("Insights").font(.subheadline.weight(.semibold))
                VStack(spacing: 8) {
                    InsightTile(icon: "bolt.fill", tint: .green, title: "Cache saved",
                                value: String(format: "$%.0f", store.cacheSavings(in: interval)))
                    InsightTile(icon: "clock.fill", tint: .teal, title: "Peak hour",
                                value: store.busiestHour(in: interval).map { String(format: "%02d:00", $0.hour) } ?? "—")
                    InsightTile(icon: "timer", tint: .orange, title: "Avg session",
                                value: store.avgSessionMinutes(in: interval).map { $0 >= 1 ? "\(Int($0))m" : "<1m" } ?? "—")
                }
            }
            .frame(width: 150)
        }
        .padding(13)
        .glassCard(cornerRadius: 16)
    }

    @ViewBuilder private var cumulativeCard: some View {
        let growth = store.cumulativeCost(in: interval)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cumulative cost").font(.subheadline.weight(.semibold))
                Spacer()
                if growth.count >= 2 {
                    Text(String(format: "$%.2f total", growth.last?.cumulative ?? 0))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if growth.count < 2 {
                ContentUnavailableView("Not enough data", systemImage: "chart.line.uptrend.xyaxis")
                    .frame(height: 130)
            } else {
                Chart {
                    ForEach(growth, id: \.date) { item in
                        LineMark(x: .value("Date", item.date), y: .value("Cost", item.cumulative))
                            .interpolationMethod(.monotone).foregroundStyle(.indigo)
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
                .frame(height: 130)
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
        .padding(13)
        .glassCard(cornerRadius: 16)
    }

    // MARK: Page 2 — Heatmap

    private var heatmapInterval: DateInterval {
        guard range.mode == .today else { return interval }
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: Date()))!
        return DateInterval(start: start, end: Date())
    }

    private var dailyCosts: [(date: Date, cost: Double)] {
        let cal = Calendar.current
        var byDay: [Date: Double] = [:]
        for s in store.filteredSessions(in: heatmapInterval) {
            let day = cal.startOfDay(for: s.startTime)
            byDay[day, default: 0] += ModelPricing.cost(for: s) ?? 0
        }
        var current = cal.startOfDay(for: heatmapInterval.start)
        let end = cal.startOfDay(for: min(heatmapInterval.end, Date()))
        var result: [(date: Date, cost: Double)] = []
        while current <= end {
            result.append((date: current, cost: byDay[current] ?? 0))
            current = cal.date(byAdding: .day, value: 1, to: current)!
        }
        return result
    }

    private var heatmapDaySummary: [Date: (cost: Double, tokens: Int, sessions: Int)] {
        let cal = Calendar.current
        var result: [Date: (cost: Double, tokens: Int, sessions: Int)] = [:]
        for s in store.filteredSessions(in: heatmapInterval) {
            let day = cal.startOfDay(for: s.startTime)
            let c = ModelPricing.cost(for: s) ?? 0
            let tok = s.totalInputTokens + s.totalOutputTokens
            let prev = result[day] ?? (0, 0, 0)
            result[day] = (prev.cost + c, prev.tokens + tok, prev.sessions + 1)
        }
        return result
    }

    @ViewBuilder private var heatmapPage: some View {
        VStack(spacing: 12) {
            // Daily activity heatmap
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Daily activity").font(.subheadline.weight(.semibold))
                    Spacer()
                    Group {
                        if let day = hoveredHeatmapDay, let s = heatmapDaySummary[day], s.sessions > 0 {
                            Text("\(day.formatted(.dateTime.day().month(.abbreviated))): \(String(format: "$%.2f", s.cost)) · \((s.tokens).abbrev) tok · \(s.sessions) sess")
                        } else {
                            Text(range.mode == .today ? "Last 30 days" : range.mode.rawValue)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .animation(.easeInOut(duration: 0.1), value: hoveredHeatmapDay)
                }
                if dailyCosts.isEmpty {
                    ContentUnavailableView("No data", systemImage: "calendar").frame(height: 120)
                } else {
                    ActivityHeatmap(days: dailyCosts, onHover: { day in hoveredHeatmapDay = day })
                }
            }
            .padding(13)
            .glassCard(cornerRadius: 16)

            // Hourly spend last 24h
            let hours = store.last24hHourlyCost()
            VStack(alignment: .leading, spacing: 8) {
                Text("Hourly spend · last 24h").font(.subheadline.weight(.semibold))
                if hours.allSatisfy({ $0.cost == 0 }) {
                    ContentUnavailableView("No activity", systemImage: "chart.bar").frame(height: 90)
                } else {
                    Chart(hours, id: \.hour) { item in
                        BarMark(x: .value("Hour", item.hour, unit: .hour),
                                y: .value("Cost", item.cost))
                        .foregroundStyle(.indigo.gradient)
                        .cornerRadius(3)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .omitted)))
                        }
                    }
                    .chartYAxis { AxisMarks(format: .currency(code: "USD").precision(.fractionLength(2))) }
                    .frame(height: 90)
                }
            }
            .padding(13)
            .glassCard(cornerRadius: 16)
        }
    }

    // MARK: Page 3 — Details

    private var detailsPage: some View {
        VStack(spacing: 12) {
            topToolsCard
            topProjectsCard
        }
    }

    @ViewBuilder private var topToolsCard: some View {
        let tools = store.topToolCalls(in: interval)
        VStack(alignment: .leading, spacing: 8) {
            Text("Top tools").font(.subheadline.weight(.semibold))
            if tools.isEmpty {
                ContentUnavailableView("No data", systemImage: "wrench.and.screwdriver").frame(height: 80)
            } else {
                let maxCount = tools.first?.count ?? 1
                VStack(spacing: 5) {
                    ForEach(tools.prefix(6), id: \.name) { tool in
                        HStack(spacing: 8) {
                            Text(tool.name).font(.caption).lineLimit(1).frame(width: 90, alignment: .leading)
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
        .padding(13)
        .glassCard(cornerRadius: 16)
    }

    @ViewBuilder private var topProjectsCard: some View {
        let items = topProjectItems
        VStack(alignment: .leading, spacing: 8) {
            Text("Top projects").font(.subheadline.weight(.semibold))
            if items.isEmpty {
                ContentUnavailableView("No data", systemImage: "folder").frame(height: 80)
            } else {
                let maxCost = items.first?.cost ?? 1
                VStack(spacing: 5) {
                    ForEach(items.prefix(7)) { item in
                        HStack(spacing: 8) {
                            Text(item.name).font(.caption).lineLimit(1)
                                .truncationMode(.middle).frame(width: 90, alignment: .leading)
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(.teal.gradient)
                                    .frame(width: max(4, geo.size.width * CGFloat(item.cost) / CGFloat(maxCost)))
                            }
                            .frame(height: 12)
                            Text(String(format: "$%.2f", item.cost))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                        }
                    }
                    if items.count > 7 {
                        Text("and \(items.count - 7) more")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(13)
        .glassCard(cornerRadius: 16)
    }

    // MARK: Helpers

    private struct ProjectItem: Identifiable {
        let id: String
        let name: String
        let cost: Double
    }

    private var topProjectItems: [ProjectItem] {
        var byCost: [String: Double] = [:]
        for s in filtered {
            byCost[s.projectName, default: 0] += ModelPricing.cost(for: s) ?? 0
        }
        var agentTotal = 0.0
        var named: [ProjectItem] = []
        for (name, cost) in byCost.sorted(by: { $0.value > $1.value }) {
            if name.hasPrefix("agent-") {
                agentTotal += cost
            } else {
                named.append(ProjectItem(id: name, name: name, cost: cost))
            }
        }
        var result = Array(named)
        if agentTotal > 0.001 {
            result.append(ProjectItem(id: "__agents__", name: "Subagents", cost: agentTotal))
        }
        return result.sorted { $0.cost > $1.cost }
    }

    private func nearest(_ points: [(date: Date, cumulative: Double)], to date: Date) -> (date: Date, cumulative: Double)? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }
}

// MARK: – Hero Stat Badge

private struct HeroStatBadge: View {
    let icon: String
    let color: Color
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(value).font(.caption.weight(.semibold).monospacedDigit())
            }
            .foregroundStyle(color)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(color.opacity(0.12), in: .rect(cornerRadius: 9))
    }
}

// MARK: – Activity Heatmap

private struct ActivityHeatmap: View {
    let days: [(date: Date, cost: Double)]
    var onHover: ((Date?) -> Void)? = nil
    private let gap: CGFloat = 3

    private var maxCost: Double { max(days.map(\.cost).max() ?? 0, 0.001) }

    private var weeks: [[(date: Date, cost: Double)?]] {
        guard !days.isEmpty else { return [] }
        let cal = Calendar.current
        let first = days.first!.date
        let last = days.last!.date
        var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: first)
        comps.weekday = cal.firstWeekday
        let weekStart = cal.date(from: comps) ?? first
        let costMap = Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0.cost) })

        var result: [[(date: Date, cost: Double)?]] = []
        var cursor = weekStart
        while cursor <= last {
            var week: [(date: Date, cost: Double)?] = []
            for d in 0..<7 {
                let day = cal.date(byAdding: .day, value: d, to: cursor)!
                week.append(day < first || day > last ? nil : (date: day, cost: costMap[day] ?? 0))
            }
            result.append(week)
            cursor = cal.date(byAdding: .weekOfYear, value: 1, to: cursor)!
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let nw = max(1, weeks.count)
                let labelW: CGFloat = 12
                let available = geo.size.width - labelW - gap - CGFloat(nw - 1) * gap
                let cell = min(22, max(8, available / CGFloat(nw)))

                HStack(alignment: .top, spacing: gap) {
                    VStack(alignment: .trailing, spacing: gap) {
                        ForEach(Array(["S","M","T","W","T","F","S"].enumerated()), id: \.offset) { _, d in
                            Text(d)
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .frame(width: labelW, height: cell)
                        }
                    }
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(weeks.indices, id: \.self) { wi in
                            VStack(spacing: gap) {
                                ForEach(0..<7, id: \.self) { di in
                                    if let c = weeks[wi][di] {
                                        let intensity = min(1, c.cost / maxCost)
                                        RoundedRectangle(cornerRadius: max(2, cell * 0.15))
                                            .fill(heatColor(intensity))
                                            .frame(width: cell, height: cell)
                                            .onContinuousHover { phase in
                                                switch phase {
                                                case .active: onHover?(c.date)
                                                case .ended:  onHover?(nil)
                                                }
                                            }
                                    } else {
                                        Color.clear.frame(width: cell, height: cell)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: 7 * 22 + 6 * gap) // 154 + 18 = 172

            // Legend
            HStack(spacing: 4) {
                Text("Less").font(.system(size: 8)).foregroundStyle(.tertiary)
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2).fill(heatColor(i)).frame(width: 10, height: 10)
                }
                Text("More").font(.system(size: 8)).foregroundStyle(.tertiary)
            }
        }
    }

    private func heatColor(_ intensity: Double) -> Color {
        intensity < 0.001 ? Color.secondary.opacity(0.15) : Color.indigo.opacity(0.18 + intensity * 0.82)
    }

}

// MARK: – Inline Runway Bar (matches LimitBar sizing for the toggle)

private struct InlineRunwayBar: View {
    let title: String
    let fraction: Double
    let runwayHours: Double?
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text(runwayText).font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(barColor)
                    .contentTransition(.numericText())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.15))
                    Capsule().fill(barColor.gradient)
                        .frame(width: max(4, geo.size.width * min(1, fraction)))
                }
            }
            .frame(height: 8)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var runwayText: String {
        guard let h = runwayHours else { return fraction >= 0.98 ? "Exhausted" : "—" }
        if h < 1 { return String(format: "%.0fm", h * 60) }
        if h < 24 { return String(format: "%.1fh", h) }
        return String(format: "%.0fd", h / 24)
    }

    private var barColor: Color {
        guard let h = runwayHours else { return fraction >= 0.9 ? .red : .indigo }
        if h < 1 { return .red }
        if h < 3 { return .orange }
        return .indigo
    }
}

// MARK: – Limit Bar (mirrors LimitsSection's private LimitBar for the toggle card)

private struct LimitBar: View {
    let title: String
    let bar: BarState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text(bar.primaryLabel).font(.caption.monospacedDigit().weight(.semibold))
                    .contentTransition(.numericText())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.15))
                    Capsule().fill(LimitsSection.barColor(for: bar.fraction).gradient)
                        .frame(width: max(4, geo.size.width * bar.fraction))
                }
            }
            .frame(height: 8)
            if let detail = bar.detailLabel {
                Text(detail).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
