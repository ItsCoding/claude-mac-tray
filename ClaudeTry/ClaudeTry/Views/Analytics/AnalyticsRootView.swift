import SwiftUI

/// Layout of the analytics window: toolbar, filters, prediction, canvas + inspector,
/// optional sessions drawer, brush timeline.
struct AnalyticsRootView: View {
    @Environment(UsageStore.self) private var store
    @Bindable var vm: AnalyticsViewModel
    @FocusState private var rootFocused: Bool

    /// Changes whenever the underlying sessions change; drives the dataset rebuild.
    private var signature: Int {
        var h = Hasher()
        h.combine(store.sessions.count)
        h.combine(store.sessions.reduce(0) { $0 + $1.messages.count })
        h.combine(store.isLoaded)
        return h.finalize()
    }

    var body: some View {
        VStack(spacing: 10) {
            AnalyticsToolbar(vm: vm)
            AnalyticsFilterBar(vm: vm)
            PredictionPanel(vm: vm)
            HStack(spacing: 10) {
                AnalyticsCanvas(vm: vm)
                AnalyticsInspector(vm: vm).frame(width: 300)
            }
            .frame(maxHeight: .infinity)
            if vm.showSessions {
                AnalyticsSessionsTable(vm: vm).frame(height: 250)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            AnalyticsMiniTimeline(vm: vm).frame(height: 104)
        }
        .padding(.top, 34).padding(.horizontal, 14).padding(.bottom, 12)
        .frame(minWidth: 1100, minHeight: 720)
        .background(
            LinearGradient(colors: [Color.indigo.opacity(0.10), Color.clear], startPoint: .top, endPoint: .center)
                .background(Color(nsColor: .windowBackgroundColor))
                .ignoresSafeArea()
        )
        .animation(.easeInOut(duration: 0.18), value: vm.showSessions)
        .overlay(alignment: .bottom) {
            if let toast = vm.toast {
                Text(toast).font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .glassCard(cornerRadius: 10)
                    .padding(.bottom, 126)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: vm.toast)
        .task(id: signature) { await vm.reloadDataset(sessions: store.sessions) }
        .onChange(of: vm.state) { _, _ in vm.scheduleQuery() }
        .focusable()
        .focused($rootFocused)
        .focusEffectDisabled()
        .onAppear { rootFocused = true }
        .onKeyPress(phases: .down) { press in handleKey(press) }
    }

    /// Single-key shortcuts; typing in the search field never reaches this.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if !press.modifiers.isEmpty && press.modifiers != .shift { return .ignored }
        let kinds: [Character: ChartKind] = ["1": .stacked, "2": .bars, "3": .share, "4": .lines, "5": .cumulative, "6": .heatmap]
        guard let ch = press.characters.lowercased().first else { return .ignored }
        if press.key == .escape { vm.pin = nil; vm.focus = nil; return .handled }
        if let k = kinds[ch] { vm.state.chart = k; return .handled }
        switch ch {
        case "/": vm.requestSearchFocus()
        case "l": vm.state.logScale.toggle()
        case "c": vm.state.overlays.comparePrevious.toggle()
        case "m": vm.state.overlays.movingAverage.toggle()
        case "f": vm.state.overlays.forecast.toggle()
        case "s": vm.showSessions.toggle()
        case "e": vm.export(.buckets)
        case "r": vm.resetZoom()
        case "h": vm.state.granularity = .hour; vm.pin = nil
        case "d": vm.state.granularity = .day; vm.pin = nil
        case "w": vm.state.granularity = .week; vm.pin = nil
        default: return .ignored
        }
        return .handled
    }
}

/// Chart panel: title, the chart (or heatmap), legend.
struct AnalyticsCanvas: View {
    @Bindable var vm: AnalyticsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let r = vm.result {
                AnalyticsChartHeader(vm: vm, result: r)
                Group {
                    if effectiveKind(r) == .heatmap {
                        AnalyticsHeatmapView(result: r)
                    } else if r.bucketCount == 0 || r.windowTotal == MetricAccumulator() {
                        Text("No data in this window")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        AnalyticsChartView(vm: vm, result: r, kind: effectiveKind(r))
                    }
                }
                .frame(maxHeight: .infinity)
                if effectiveKind(r) != .heatmap { AnalyticsLegend(vm: vm, result: r) }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .analyticsPanel(padding: 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Ratio metrics cannot be stacked, normalized or accumulated: draw them as lines.
    func effectiveKind(_ r: AnalyticsResult) -> ChartKind {
        if r.metric.isRatio, [.stacked, .bars, .share, .cumulative].contains(vm.state.chart) { return .lines }
        return vm.state.chart
    }
}

struct AnalyticsChartHeader: View {
    let vm: AnalyticsViewModel
    let result: AnalyticsResult

    var body: some View {
        let kind = result.metric.isRatio && [.stacked, .bars, .share, .cumulative].contains(vm.state.chart) ? ChartKind.lines : vm.state.chart
        let w = result.query.window
        HStack(alignment: .firstTextBaseline) {
            Text(kind == .heatmap ? "\(result.metric.title) by day and hour"
                                  : "\(result.metric.title) by \(result.query.groupBy.rawValue) · \(adjective(result.granularity))")
                .font(.title3.weight(.semibold))
            Spacer()
            Text(subtitle(w, kind: kind))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func adjective(_ g: Granularity) -> String {
        switch g { case .hour: return "hourly"; case .day: return "daily"; case .week: return "weekly" }
    }

    private func subtitle(_ w: DateInterval, kind: ChartKind) -> String {
        var s = "\(w.start.formatted(.dateTime.month(.abbreviated).day())) to \(w.end.addingTimeInterval(-1).formatted(.dateTime.month(.abbreviated).day()))"
        s += " · \(result.bucketCount) buckets · \(AnalyticsFormat.number(result.windowTotal.sessions)) sessions"
        if result.granularity != result.query.granularity { s += " · grain raised to \(result.granularity.title.lowercased())" }
        if result.metric.isRatio && kind == .lines && vm.state.chart != .lines { s += " · ratio metric, drawn as lines" }
        if (kind == .share || kind == .cumulative) && (vm.state.overlays.comparePrevious || vm.state.overlays.movingAverage || vm.state.overlays.forecast) {
            s += " · overlays hidden here"
        }
        if vm.state.logScale && ![.lines, .cumulative].contains(kind) && kind != .heatmap { s += " · log applies to lines" }
        return s
    }
}

struct AnalyticsLegend: View {
    @Bindable var vm: AnalyticsViewModel
    let result: AnalyticsResult

    var body: some View {
        let palette = SeriesPalette(names: result.series.map(\.key))
        FlowLayout(spacing: 5) {
            ForEach(result.series, id: \.key) { s in
                let off = vm.hiddenSeries.contains(s.key)
                Button { vm.toggleSeries(s.key) } label: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(palette.color(s.key)).frame(width: 8, height: 8)
                        Text(s.key).font(.caption)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                    .opacity(off ? 0.35 : 1)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
