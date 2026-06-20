import SwiftUI

struct ConversationsTab: View {
    @Environment(UsageStore.self) private var store
    @State private var expandedSessionID: UUID? = nil
    @State private var searchText = ""

    private var filtered: [Session] {
        guard !searchText.isEmpty else { return store.sessions }
        return store.sessions.filter {
            $0.projectName.localizedCaseInsensitiveContains(searchText) ||
            ($0.primaryModel ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Filter by project or model", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            if filtered.isEmpty {
                ContentUnavailableView("No conversations", systemImage: "bubble.left.and.bubble.right")
                    .frame(maxHeight: .infinity)
            } else {
                List(filtered) { session in
                    SessionRow(session: session, isExpanded: expandedSessionID == session.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedSessionID = expandedSessionID == session.id ? nil : session.id
                            }
                        }
                }
                .listStyle(.plain)
            }
        }
        .padding(.top)
    }
}

private struct SessionRow: View {
    let session: Session
    let isExpanded: Bool

    private var costString: String {
        if let cost = ModelPricing.cost(for: session) { return String(format: "$%.4f", cost) }
        return "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.projectName)
                        .font(.system(.body, design: .monospaced)).fontWeight(.medium)
                    Text(session.startTime.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(costString).font(.caption.monospacedDigit()).fontWeight(.medium)
                    Text("\((session.totalInputTokens + session.totalOutputTokens).formatted()) tok")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let model = session.primaryModel {
                    Text(shortModel(model))
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.blue.opacity(0.15), in: Capsule())
                        .foregroundStyle(.blue)
                }
            }

            if isExpanded {
                Divider()
                if !session.toolCallCounts.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tool Calls").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(session.toolCallCounts.sorted { $0.value > $1.value }, id: \.key) { tool, count in
                            HStack {
                                Text(tool).font(.caption.monospaced())
                                Spacer()
                                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if session.modelBreakdown.count > 1 {
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model Split").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(session.modelBreakdown.sorted { $0.value.input > $1.value.input }, id: \.key) { model, tc in
                            HStack {
                                Text(shortModel(model)).font(.caption)
                                Spacer()
                                Text("\((tc.input + tc.output).formatted()) tok")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func shortModel(_ model: String) -> String {
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        if model.contains("fable") { return "Fable" }
        return String(model.prefix(12))
    }
}
