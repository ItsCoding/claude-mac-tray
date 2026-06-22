import SwiftUI

/// Session (5h) + weekly (7d) usage bars and an API/wall-time line. Shown in both
/// the minimal and expanded dashboard layouts. When the statusline integration
/// isn't installed, shows a slim "connect" prompt instead.
struct LimitsSection: View {
    let limits: LimitsModel
    var compact: Bool = false
    var showConnectPrompt: Bool = false
    var onConnect: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showConnectPrompt {
                connectPrompt
            } else {
                HStack(alignment: .top, spacing: 12) {
                    LimitBar(title: "Session · 5h", bar: limits.session)
                    Divider().frame(height: 40)
                    LimitBar(title: "Weekly · 7d", bar: limits.weekly)
                }
                timingLine
            }
        }
        .padding(compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: compact ? 12 : 14)
    }

    private var timingLine: some View {
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
        Button(action: onConnect) {
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

    static func barColor(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.75: return .indigo
        case ..<0.9:  return .orange
        default:      return .red
        }
    }
}

/// One labelled progress bar with a primary value and an optional caption.
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
