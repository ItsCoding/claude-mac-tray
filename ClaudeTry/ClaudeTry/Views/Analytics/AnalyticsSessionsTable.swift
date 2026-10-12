import SwiftUI

/// Collapsible drawer listing the filtered sessions: sortable headers, column
/// picker, paged rows. Rows are pre-sorted in the view model, not per frame.
struct AnalyticsSessionsTable: View {
    @Bindable var vm: AnalyticsViewModel

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("\(AnalyticsFormat.number(Double(vm.sortedRows.count))) sessions · sorted by \(vm.sortColumn.title) \(vm.sortAscending ? "↑" : "↓") · click a row to search it")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu("Columns") {
                    ForEach(SessionColumn.allCases) { c in
                        Toggle(c.title, isOn: Binding(get: { vm.columns.contains(c) }, set: { _ in vm.toggleColumn(c) }))
                    }
                }
                .menuStyle(.button).fixedSize().controlSize(.small)
                Button("Export CSV") { vm.export(.sessions) }.controlSize(.small)
            }
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(vm.sortedRows.prefix(vm.rowLimit)) { row in
                            Button { vm.state.filters.search = row.id } label: {
                                rowView(row)
                            }
                            .buttonStyle(.plain)
                        }
                        if vm.sortedRows.count > vm.rowLimit {
                            Button("Show 25 more (\(vm.sortedRows.count - vm.rowLimit) left)") { vm.rowLimit += 25 }
                                .controlSize(.small).padding(8)
                        }
                    } header: { header }
                }
            }
        }
        .analyticsPanel(padding: 10)
    }

    private var header: some View {
        HStack(spacing: 0) {
            ForEach(vm.columns) { c in
                Button { vm.setSort(c) } label: {
                    Text(c.title + (vm.sortColumn == c ? (vm.sortAscending ? " ↑" : " ↓") : ""))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: c.width, alignment: c.isNumeric ? .trailing : .leading)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .background(.regularMaterial)
    }

    private func rowView(_ row: SessionRow) -> some View {
        HStack(spacing: 0) {
            ForEach(vm.columns) { c in
                Text(c.display(row))
                    .font(.caption.monospacedDigit()).lineLimit(1)
                    .frame(width: c.width, alignment: c.isNumeric ? .trailing : .leading)
                    .padding(.horizontal, 6).padding(.vertical, 3)
            }
        }
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }
}
