import SwiftUI

/// Range, chart type, granularity, metric, grouping, overlays, saved views, export.
struct AnalyticsToolbar: View {
    @Bindable var vm: AnalyticsViewModel
    @State private var naming = false
    @State private var newName = ""
    @State private var showKeys = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                label("Range")
                Seg(options: RangePreset.pickable, selection: vm.state.range, title: { $0.rawValue }) { vm.setRange($0) }
                if vm.state.range == .custom {
                    DatePicker("", selection: $vm.state.customFrom, displayedComponents: .date).labelsHidden()
                    Text("to").font(.caption).foregroundStyle(.secondary)
                    DatePicker("", selection: $vm.state.customTo, displayedComponents: .date).labelsHidden()
                }
                label("Chart").padding(.leading, 6)
                Seg(options: ChartKind.allCases, selection: vm.state.chart, title: { $0.rawValue }) { vm.state.chart = $0 }
                label("Grain").padding(.leading, 6)
                Seg(options: Granularity.allCases, selection: vm.state.granularity, title: { $0.title }) {
                    vm.state.granularity = $0; vm.pin = nil
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                label("Metric")
                Picker("Metric", selection: $vm.state.metric) {
                    ForEach(AnalyticsMetric.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 170)
                label("Group").padding(.leading, 6)
                Picker("Group by", selection: $vm.state.groupBy) {
                    ForEach(GroupBy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 100)
                label("Scale").padding(.leading, 6)
                Seg(options: [false, true], selection: vm.state.logScale, title: { $0 ? "Log" : "Linear" }) { vm.state.logScale = $0 }
                Spacer(minLength: 0)
                overlaysMenu
                viewsMenu
                Button { vm.showSessions.toggle() } label: {
                    Label("Sessions", systemImage: vm.showSessions ? "chevron.down" : "chevron.up")
                        .labelStyle(.titleAndIcon).font(.callout)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                exportMenu
                Button { showKeys.toggle() } label: { Image(systemName: "keyboard") }
                    .help("Keyboard shortcuts")
                    .popover(isPresented: $showKeys, arrowEdge: .bottom) { shortcutsList }
            }
        }
        .analyticsPanel(padding: 10)
        .alert("Name this view", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") { vm.saveCurrentView(named: newName); newName = "" }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary)
    }

    private var overlaysMenu: some View {
        Menu {
            Toggle("Compare to previous period", isOn: $vm.state.overlays.comparePrevious)
            Toggle("Moving average", isOn: $vm.state.overlays.movingAverage)
            Toggle("Forecast (linear trend)", isOn: $vm.state.overlays.forecast)
            Toggle("Highlight outliers (>2σ)", isOn: $vm.state.overlays.outliers)
        } label: { Text("Overlays") }
        .menuStyle(.button).fixedSize()
    }

    private var viewsMenu: some View {
        Menu {
            Section("Built-in") {
                ForEach(BuiltInViews.all, id: \.name) { v in
                    Button(v.name) { vm.apply(v.make()) }
                }
            }
            Section("Saved") {
                if vm.savedViews.isEmpty { Text("None yet") }
                ForEach(vm.savedViews) { v in
                    Button(v.name) { vm.apply(v.state) }
                }
            }
            Divider()
            Button("Save current view…") { naming = true }
            if !vm.savedViews.isEmpty {
                Menu("Delete saved view") {
                    ForEach(vm.savedViews) { v in Button(v.name, role: .destructive) { vm.deleteSavedView(v) } }
                }
            }
        } label: { Text("Views") }
        .menuStyle(.button).fixedSize()
    }

    private var exportMenu: some View {
        Menu {
            Button("Buckets as CSV (current view)") { vm.export(.buckets) }
            Button("Sessions as CSV (filtered)") { vm.export(.sessions) }
        } label: { Text("Export") }
        .menuStyle(.button).fixedSize()
    }

    private var shortcutsList: some View {
        let rows: [(String, String)] = [
            ("1 – 6", "chart: stacked, bars, 100%, lines, cumulative, day x hour"),
            ("h  d  w", "grain: hour, day, week"),
            ("l", "log / linear scale"),
            ("c  m  f", "compare, moving average, forecast"),
            ("/", "search"), ("s", "sessions table"), ("e", "export buckets CSV"),
            ("r", "reset zoom"), ("Esc", "clear pin and focus"),
        ]
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { k, d in
                GridRow {
                    Text(k).font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 5).background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 4))
                    Text(d).font(.caption)
                }
            }
        }
        .padding(14)
    }
}
