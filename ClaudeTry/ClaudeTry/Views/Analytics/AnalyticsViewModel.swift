import SwiftUI
import Observation
import UniformTypeIdentifiers

struct SavedView: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var state: AnalyticsViewState

    init(id: UUID = UUID(), name: String, state: AnalyticsViewState) {
        self.id = id; self.name = name; self.state = state
    }

    private enum CodingKeys: String, CodingKey { case id, name, state }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        state = (try? c.decodeIfPresent(AnalyticsViewState.self, forKey: .state)) ?? AnalyticsViewState()
    }
}

enum SessionColumn: String, CaseIterable, Identifiable {
    case started, project, model, type, profile, messages, tools, tokens, cost, added, removed, cacheHit, duration, session
    var id: String { rawValue }

    var title: String {
        switch self {
        case .started: return "Started"
        case .project: return "Project"
        case .model: return "Model"
        case .type: return "Type"
        case .profile: return "Profile"
        case .messages: return "Messages"
        case .tools: return "Tool calls"
        case .tokens: return "Tokens"
        case .cost: return "Cost"
        case .added: return "Lines +"
        case .removed: return "Lines -"
        case .cacheHit: return "Cache hit"
        case .duration: return "Duration"
        case .session: return "Session"
        }
    }
    var isNumeric: Bool {
        switch self {
        case .messages, .tools, .tokens, .cost, .added, .removed, .cacheHit, .duration: return true
        default: return false
        }
    }
    var width: CGFloat {
        switch self {
        case .started: return 120
        case .project, .model: return 130
        case .session: return 90
        case .type, .profile: return 80
        default: return 78
        }
    }
    func number(_ r: SessionRow) -> Double {
        switch self {
        case .started: return r.start.timeIntervalSince1970
        case .messages: return Double(r.messages)
        case .tools: return Double(r.toolCalls)
        case .tokens: return Double(r.tokens)
        case .cost: return r.cost
        case .added: return Double(r.linesAdded)
        case .removed: return Double(r.linesRemoved)
        case .cacheHit: return r.cacheHit
        case .duration: return r.durationSec
        case .type: return r.isSubagent ? 1 : 0
        case .profile: return r.profile == .bedrock ? 1 : 0
        default: return 0
        }
    }
    func text(_ r: SessionRow) -> String {
        switch self {
        case .project: return r.project
        case .model: return r.model
        case .session: return r.id
        default: return ""
        }
    }
    func display(_ r: SessionRow) -> String {
        switch self {
        case .started: return r.start.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        case .project: return r.project
        case .model: return r.model
        case .type: return r.isSubagent ? "Subagent" : "Main"
        case .profile: return r.profile.rawValue
        case .messages: return AnalyticsFormat.number(Double(r.messages))
        case .tools: return AnalyticsFormat.number(Double(r.toolCalls))
        case .tokens: return AnalyticsFormat.tokens(Double(r.tokens))
        case .cost: return AnalyticsFormat.money(r.cost)
        case .added: return AnalyticsFormat.number(Double(r.linesAdded))
        case .removed: return AnalyticsFormat.number(Double(r.linesRemoved))
        case .cacheHit: return AnalyticsFormat.percent(r.cacheHit)
        case .duration: return AnalyticsFormat.duration(seconds: r.durationSec)
        case .session: return r.shortID
        }
    }
}

enum BuiltInViews {
    static let all: [(name: String, make: () -> AnalyticsViewState)] = [
        ("Daily cost by model", {
            var s = AnalyticsViewState(); s.range = .month; s.granularity = .day; s.metric = .cost
            s.groupBy = .model; s.chart = .stacked; s.overlays = Overlays(comparePrevious: true, outliers: true); return s }),
        ("Cache efficiency", {
            var s = AnalyticsViewState(); s.range = .month; s.granularity = .day; s.metric = .cacheHit
            s.groupBy = .model; s.chart = .lines; s.overlays = Overlays(movingAverage: true, outliers: false); return s }),
        ("Cost per line by project", {
            var s = AnalyticsViewState(); s.range = .month; s.granularity = .day; s.metric = .costPerLine
            s.groupBy = .project; s.chart = .lines; s.overlays = Overlays(movingAverage: true, outliers: false); return s }),
        ("Weekly spend by project", {
            var s = AnalyticsViewState(); s.range = .all; s.granularity = .week; s.metric = .cost
            s.groupBy = .project; s.chart = .bars; return s }),
        ("Forecast the next week", {
            var s = AnalyticsViewState(); s.range = .month; s.granularity = .day; s.metric = .tokens
            s.groupBy = .tool; s.chart = .stacked; s.overlays = Overlays(forecast: true, outliers: false); return s }),
        ("Hour-of-day heatmap", {
            var s = AnalyticsViewState(); s.range = .month; s.granularity = .hour; s.metric = .sessions
            s.chart = .heatmap; s.overlays = Overlays(outliers: false); return s }),
    ]
}

@Observable
@MainActor
final class AnalyticsViewModel {
    var state = AnalyticsViewState()
    var pin: Int?
    var focus: String?
    var hiddenSeries: Set<String> = []
    var showSessions = false
    var predictionCollapsed = false
    var sortColumn: SessionColumn = .started
    var sortAscending = false
    var columns: [SessionColumn] = [.started, .project, .model, .type, .messages, .tools, .tokens, .cost, .added, .cacheHit, .duration]
    var rowLimit = 25
    var toast: String?
    var savedViews: [SavedView] = []
    var focusSearchRequest = 0

    // Prediction what-if state
    var predictionWindow: PredictionWindow = .fiveHour
    var predictionOptions = RunwayPredictor.Options()

    enum PredictionWindow: String, CaseIterable { case fiveHour = "5-hour", sevenDay = "7-day"
        var hours: Double { self == .fiveHour ? 5 : 168 }
    }

    private(set) var result: AnalyticsResult?
    private(set) var dataset = AnalyticsDataset()
    private(set) var sortedRows: [SessionRow] = []
    private(set) var availableModels: [String] = []
    private(set) var availableProjects: [String] = []
    private(set) var availableTools: [String] = []
    private(set) var isWorking = false

    /// Forecasts are cached per window and recomputed only when an input changes
    /// (dataset, options, rate window, or the 30 s clock tick), not on every body pass.
    private struct PredictionKey: Equatable {
        var generation: Int
        var options: RunwayPredictor.Options
        var used: Double
        var resetsAt: Date
        var calibratedAt: Date?
        var tick: Int
    }
    @ObservationIgnored
    private var predictionCache: [PredictionWindow: (key: PredictionKey, value: RunwayPredictor.Forecast?)] = [:]

    func prediction(window: PredictionWindow, rate: RateWindow?, calibratedAt: Date?, now: Date) -> RunwayPredictor.Forecast? {
        guard let rate else { return nil }
        let key = PredictionKey(generation: dataVersion, options: predictionOptions, used: rate.usedPercentage,
                                resetsAt: rate.resetsAt, calibratedAt: calibratedAt,
                                tick: Int(now.timeIntervalSince1970 / 30))
        if let hit = predictionCache[window], hit.key == key { return hit.value }
        let value = RunwayPredictor.forecast(
            .init(usedPercent: rate.usedPercentage, resetsAt: rate.resetsAt, windowHours: window.hours, now: now,
                  index: dataset.costIndex, calibratedAt: calibratedAt),
            options: predictionOptions)
        predictionCache[window] = (key, value)
        return value
    }

    private var persistBlocked = false
    private var datasetGeneration = 0
    @ObservationIgnored private var dataVersion = 0
    private var queryTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private static let savedKey = "analytics.savedViews"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.savedKey) {
            if let items = try? JSONDecoder().decode([Lossy<SavedView>].self, from: data) {
                savedViews = items.compactMap(\.value)
                if savedViews.count != items.count {
                    // Keep the original bytes so unreadable entries are never lost for good.
                    defaults.set(data, forKey: Self.savedKey + ".backup")
                }
            } else {
                // Unreadable storage: keep it untouched and never overwrite it.
                defaults.set(data, forKey: Self.savedKey + ".backup")
                persistBlocked = true
            }
        }
    }

    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    // MARK: Data

    /// Rebuilds the flat dataset off the main thread, then re-runs the query.
    func reloadDataset(sessions: [Session]) async {
        let catalog = ModelPricing.catalog
        datasetGeneration += 1
        let gen = datasetGeneration
        let ds = await Task.detached(priority: .userInitiated) {
            AnalyticsDataset.build(from: sessions, pricing: catalog)
        }.value
        // A newer build may have started (or this task been cancelled) while we waited.
        guard gen == datasetGeneration, !Task.isCancelled else { return }
        dataset = ds
        dataVersion += 1
        availableModels = Array(Set(ds.fragments.map(\.model))).sorted { (ModelStyle.rank($0), $0) < (ModelStyle.rank($1), $1) }
        availableProjects = Array(Set(ds.sessions.map(\.project))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        availableTools = Array(Set(ds.sessions.flatMap(\.tools))).sorted()
        scheduleQuery(debounce: 0)
    }

    func scheduleQuery(debounce ms: Int = 60) {
        queryTask?.cancel()
        let cal = Calendar.current
        let now = Date()
        let q = AnalyticsQuery(window: state.window(now: now, dataStart: dataset.minDate, calendar: cal),
                               granularity: state.granularity, metric: state.metric,
                               groupBy: state.groupBy, filters: state.filters)
        let ds = dataset
        isWorking = true
        queryTask = Task { [weak self] in
            if ms > 0 { try? await Task.sleep(for: .milliseconds(ms)) }
            if Task.isCancelled { return }
            let r = await Task.detached(priority: .userInitiated) {
                AnalyticsEngine(dataset: ds, calendar: cal, now: now).run(q)
            }.value
            if Task.isCancelled { return }
            guard let self else { return }
            self.result = r
            if let p = self.pin, p >= r.bucketCount { self.pin = nil }
            self.resort()
            self.isWorking = false
        }
    }

    // MARK: State changes

    func setRange(_ r: RangePreset) {
        state.range = r
        state.zoomStart = nil; state.zoomEnd = nil
        if r != .custom { state.granularity = AnalyticsViewState.defaultGranularity(for: r) }
        pin = nil
    }

    func applyZoom(start: Date, end: Date) {
        state.zoomStart = start; state.zoomEnd = end
        state.range = .zoom
        let days = end.timeIntervalSince(start) / 86_400
        state.granularity = days <= 3 ? .hour : days <= 120 ? .day : .week
        pin = nil
    }

    func resetZoom() {
        setRange(.week)
        focus = nil
    }

    func clearFilters() {
        state.filters = AnalyticsFilters()
        focus = nil
    }

    func toggleSeries(_ key: String) {
        if hiddenSeries.contains(key) { hiddenSeries.remove(key) } else { hiddenSeries.insert(key) }
    }

    func requestSearchFocus() { focusSearchRequest += 1 }

    func showTable(searching id: String) {
        state.filters.search = id
        showSessions = true
    }

    // MARK: Sessions table

    func setSort(_ c: SessionColumn) {
        if sortColumn == c { sortAscending.toggle() } else { sortColumn = c; sortAscending = false }
        resort()
    }

    func resort() {
        guard let rows = result?.sessions else { sortedRows = []; return }
        let c = sortColumn, asc = sortAscending
        sortedRows = rows.sorted { a, b in
            let less: Bool
            if c.isNumeric || c == .started || c == .type || c == .profile {
                let x = c.number(a), y = c.number(b)
                if x == y { return a.start > b.start }
                less = x < y
            } else {
                let x = c.text(a), y = c.text(b)
                if x == y { return a.start > b.start }
                less = x.localizedCaseInsensitiveCompare(y) == .orderedAscending
            }
            return asc ? less : !less
        }
        rowLimit = 25
    }

    func toggleColumn(_ c: SessionColumn) {
        if let i = columns.firstIndex(of: c) { if columns.count > 1 { columns.remove(at: i) } }
        else { columns = SessionColumn.allCases.filter { columns.contains($0) || $0 == c } }
    }

    // MARK: Saved views

    func saveCurrentView(named name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        savedViews.append(SavedView(name: n, state: state))
        persistViews()
        flash("Saved view: \(n)")
    }

    func deleteSavedView(_ v: SavedView) {
        savedViews.removeAll { $0.id == v.id }
        persistViews()
    }

    func apply(_ s: AnalyticsViewState) {
        state = s
        pin = nil; focus = nil; hiddenSeries = []
    }

    private func persistViews() {
        guard !persistBlocked else { return }
        if let data = try? JSONEncoder().encode(savedViews) { defaults.set(data, forKey: Self.savedKey) }
    }

    // MARK: Export

    enum ExportKind { case buckets, sessions }

    func export(_ kind: ExportKind) {
        guard let r = result else { flash("Nothing to export"); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let csv: String
        switch kind {
        case .buckets:
            csv = AnalyticsCSV.buckets(r)
            panel.nameFieldStringValue = "claudetry-\(r.query.metric.rawValue)-\(r.query.groupBy.rawValue).csv"
        case .sessions:
            csv = AnalyticsCSV.sessions(sortedRows)
            panel.nameFieldStringValue = "claudetry-sessions.csv"
        }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
                Task { @MainActor in self?.flash("Exported \(url.lastPathComponent)") }
            } catch {
                Task { @MainActor in self?.flash("Export failed: \(error.localizedDescription)") }
            }
        }
    }

    func flash(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self?.toast = nil }
        }
    }
}
