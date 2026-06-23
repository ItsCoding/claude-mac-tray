import SwiftUI

/// One color language for models, shared by every chart so a hue always means
/// the same model. System colors keep it native rather than a rainbow.
enum ModelStyle {
    /// Stable legend/stack order (most expensive → cheapest, then synthetic, then profiles).
    static let order = ["Opus", "Sonnet", "Haiku", "Fable", "Synthetic", "Claude.ai", "Bedrock"]

    static func color(_ model: String) -> Color {
        switch model {
        case "Opus":      return .indigo
        case "Sonnet":    return .teal
        case "Haiku":     return .orange
        case "Fable":     return .pink
        case "Synthetic": return .gray
        case "Claude.ai": return .indigo
        case "Bedrock":   return .green
        default:          return .gray
        }
    }

    private static let palette: [Color] = [
        .blue, .green, .orange, .pink, .purple, .red, .cyan, .mint, .brown, .yellow
    ]

    /// Domain + matching colors for `chartForegroundStyleScale`, restricted to
    /// the models actually present and kept in a stable order.
    /// Known model names get their fixed color; everything else (tool names,
    /// project names) cycles through a palette so bars are always distinct.
    static func scale(for models: some Sequence<String>) -> (domain: [String], range: [Color]) {
        let present = Set(models)
        let known = order.filter(present.contains)
        let extra = present.subtracting(order).sorted()
        let domain = known + extra
        let range = known.map(color) + extra.enumerated().map { i, _ in palette[i % palette.count] }
        return (domain, range)
    }
}

extension View {
    /// Liquid Glass on Tahoe (26+), translucent material fallback below it.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

/// Tooltip / axis header for a bucket, formatted for its granularity.
func bucketHeader(_ date: Date, unit: BucketUnit) -> String {
    switch unit {
    case .hour: return date.formatted(.dateTime.hour().minute())
    case .day:  return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    case .week: return "Week of " + date.formatted(.dateTime.day().month(.abbreviated))
    }
}
