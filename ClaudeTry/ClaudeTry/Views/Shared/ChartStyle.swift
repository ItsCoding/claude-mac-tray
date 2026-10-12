import SwiftUI

/// One color language for models, shared by every chart so a hue always means
/// the same model. System colors keep it native rather than a rainbow.
enum ModelStyle {
    /// Stable legend/stack order (most expensive → cheapest, then synthetic, then profiles).
    static let order = ["Opus", "Sonnet", "Haiku", "Fable", "Synthetic", "Claude.ai", "Bedrock", "Added", "Removed"]

    /// Family of a display name: "Sonnet 4.6" -> "Sonnet". Names outside `order` pass through.
    static func family(_ name: String) -> String {
        order.first { name == $0 || name.hasPrefix($0 + " ") } ?? name
    }

    static func rank(_ name: String) -> Int {
        order.firstIndex(of: family(name)) ?? order.count
    }

    static func color(_ model: String) -> Color {
        switch family(model) {
        case "Opus":      return .indigo
        case "Sonnet":    return .teal
        case "Haiku":     return .orange
        case "Fable":     return .pink
        case "Synthetic": return .gray
        case "Claude.ai": return .indigo
        case "Bedrock":   return .green
        case "Added":     return .green
        case "Removed":   return .red
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
        let known = present.filter { order.contains(family($0)) }.sorted { (rank($0), $0) < (rank($1), $1) }
        let extra = present.subtracting(known).sorted()
        let domain = known + extra
        // Versions of one family share a hue; fade the later ones so they stay distinguishable.
        var seen: [String: Int] = [:]
        let knownColors = known.map { name -> Color in
            let n = seen[family(name), default: 0]
            seen[family(name)] = n + 1
            return color(name).opacity(max(0.4, 1 - 0.25 * Double(n)))
        }
        let range = knownColors + extra.enumerated().map { i, _ in palette[i % palette.count] }
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
