import SwiftUI

/// Search box, filter popover button and removable chips mirroring the active filters.
struct AnalyticsFilterBar: View {
    @Bindable var vm: AnalyticsViewModel
    @State private var showFilters = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("Search project, model, tool, session id   ( / )", text: $vm.state.filters.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { searchFocused = false }
                    .onExitCommand { searchFocused = false }
                if !vm.state.filters.search.isEmpty {
                    Button { vm.state.filters.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(width: 290)
            .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 7))

            Button { showFilters.toggle() } label: { Label("Filter", systemImage: "plus") }
                .popover(isPresented: $showFilters, arrowEdge: .bottom) { FilterPopover(vm: vm) }

            FlowLayout { ForEach(chips, id: \.label) { c in FilterChip(label: c.label, onRemove: c.remove) } }
                .frame(maxWidth: .infinity, alignment: .leading)

            if !chips.isEmpty || !vm.state.filters.search.isEmpty {
                Button("Clear all") { vm.clearFilters() }.controlSize(.small)
            }
        }
        .analyticsPanel(padding: 8)
        .onChange(of: vm.focusSearchRequest) { _, _ in searchFocused = true }
    }

    private struct ChipSpec { let label: String; let remove: () -> Void }

    private var chips: [ChipSpec] {
        let f = vm.state.filters
        var out: [ChipSpec] = []
        for m in f.models.sorted() { out.append(.init(label: "Model: \(m)") { vm.state.filters.models.remove(m) }) }
        for p in f.projects.sorted() { out.append(.init(label: "Project: \(p)") { vm.state.filters.projects.remove(p) }) }
        for t in f.tools.sorted() { out.append(.init(label: "Tool: \(t)") { vm.state.filters.tools.remove(t) }) }
        if f.profile != .all { out.append(.init(label: "Profile: \(f.profile.rawValue)") { vm.state.filters.profile = .all }) }
        if f.agent != .all { out.append(.init(label: f.agent.rawValue) { vm.state.filters.agent = .all }) }
        if f.size != .any { out.append(.init(label: "Messages: \(f.size.rawValue)") { vm.state.filters.size = .any }) }
        if f.weekday != .all { out.append(.init(label: f.weekday.rawValue) { vm.state.filters.weekday = .all }) }
        if f.minCost > 0 { out.append(.init(label: "Cost ≥ $\(f.minCost.formatted())") { vm.state.filters.minCost = 0 }) }
        if f.hoursActive { out.append(.init(label: "Hours \(f.hourFrom)–\(f.hourTo)") { vm.state.filters.hourFrom = 0; vm.state.filters.hourTo = 23 }) }
        if let focus = vm.focus { out.append(.init(label: "Focus: \(focus)") { vm.focus = nil }) }
        return out
    }
}

private struct FilterPopover: View {
    @Bindable var vm: AnalyticsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                multi("Model version", vm.availableModels, \.models)
                multi("Project", vm.availableProjects, \.projects)
                multi("Tool used", vm.availableTools, \.tools)
                single("Profile", ProfileFilter.allCases, \.profile)
                single("Subagents", AgentFilter.allCases, \.agent)
                single("Session size (messages)", SizeFilter.allCases, \.size)
                single("Weekday", WeekdayFilter.allCases, \.weekday)
                VStack(alignment: .leading, spacing: 4) {
                    SectionCaption("Cost at least (USD)")
                    TextField("0", value: $vm.state.filters.minCost, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                }
                VStack(alignment: .leading, spacing: 4) {
                    SectionCaption("Hour of day, local")
                    HStack {
                        Stepper(value: $vm.state.filters.hourFrom, in: 0...23) { Text("\(vm.state.filters.hourFrom)").monospacedDigit() }
                        Text("to").foregroundStyle(.secondary)
                        Stepper(value: $vm.state.filters.hourTo, in: 0...23) { Text("\(vm.state.filters.hourTo)").monospacedDigit() }
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 300, height: 470)
    }

    private func multi(_ title: String, _ items: [String], _ kp: WritableKeyPath<AnalyticsFilters, Set<String>>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionCaption(title)
            if items.isEmpty { Text("None").font(.caption).foregroundStyle(.tertiary) }
            ForEach(items, id: \.self) { item in
                Toggle(item, isOn: Binding(
                    get: { vm.state.filters[keyPath: kp].contains(item) },
                    set: { on in
                        if on { vm.state.filters[keyPath: kp].insert(item) } else { vm.state.filters[keyPath: kp].remove(item) }
                    }))
                .toggleStyle(.checkbox).font(.callout)
            }
        }
    }

    private func single<T: Hashable & RawRepresentable>(_ title: String, _ all: [T], _ kp: WritableKeyPath<AnalyticsFilters, T>) -> some View where T.RawValue == String {
        VStack(alignment: .leading, spacing: 4) {
            SectionCaption(title)
            Seg(options: all, selection: vm.state.filters[keyPath: kp], title: { $0.rawValue }) { vm.state.filters[keyPath: kp] = $0 }
        }
    }
}
