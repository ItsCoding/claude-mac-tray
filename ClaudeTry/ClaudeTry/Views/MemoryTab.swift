import SwiftUI
import Charts

struct MemoryTab: View {
    @Environment(UsageStore.self) private var store

    private var events: [MemoryEvent] { store.memoryEvents }
    private var totalWrites: Int { events.filter { $0.operation == .write || $0.operation == .create }.count }
    private var totalReads: Int { events.filter { $0.operation == .read }.count }
    private var totalCreates: Int { events.filter { $0.operation == .create }.count }

    private var perProjectCounts: [(project: String, count: Int)] {
        Dictionary(grouping: events, by: \.projectPath)
            .map { (project: URL(fileURLWithPath: $0.key).lastPathComponent, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    private var topReadFiles: [(file: String, count: Int)] {
        Dictionary(grouping: events.filter { $0.operation == .read }, by: \.memoryFilePath)
            .map { (file: URL(fileURLWithPath: $0.key).lastPathComponent, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(10).map { $0 }
    }

    private var topWriteFiles: [(file: String, count: Int)] {
        Dictionary(grouping: events.filter { $0.operation == .write || $0.operation == .create }, by: \.memoryFilePath)
            .map { (file: URL(fileURLWithPath: $0.key).lastPathComponent, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(10).map { $0 }
    }

    private var growthBuckets: [(date: Date, cumulative: Int)] {
        let creates = events.filter { $0.operation == .create }.sorted { $0.timestamp < $1.timestamp }
        return creates.enumerated().map { (date: $0.element.timestamp, cumulative: $0.offset + 1) }
    }

    var body: some View {
        ScrollView {
            if events.isEmpty {
                ContentUnavailableView("No memory activity", systemImage: "brain")
                    .frame(maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                        StatCard(title: "Reads", value: "\(totalReads)")
                        StatCard(title: "Writes", value: "\(totalWrites)")
                        StatCard(title: "Created", value: "\(totalCreates)")
                    }

                    if growthBuckets.count > 1 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Memory File Growth").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Chart(growthBuckets, id: \.date) { item in
                                LineMark(x: .value("Date", item.date), y: .value("Files", item.cumulative))
                                    .interpolationMethod(.stepEnd)
                                AreaMark(x: .value("Date", item.date), y: .value("Files", item.cumulative))
                                    .foregroundStyle(.purple.opacity(0.15)).interpolationMethod(.stepEnd)
                            }
                            .frame(height: 100)
                        }
                    }

                    if !perProjectCounts.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("By Project").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(perProjectCounts, id: \.project) { item in
                                HStack {
                                    Text(item.project).font(.caption.monospaced())
                                    Spacer()
                                    Text("\(item.count) events").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if !topReadFiles.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Most Read").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(topReadFiles, id: \.file) { item in
                                HStack {
                                    Text(item.file).font(.caption.monospaced()).lineLimit(1)
                                    Spacer()
                                    Text("\(item.count)×").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if !topWriteFiles.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Most Written").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(topWriteFiles, id: \.file) { item in
                                HStack {
                                    Text(item.file).font(.caption.monospaced()).lineLimit(1)
                                    Spacer()
                                    Text("\(item.count)×").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
    }
}
