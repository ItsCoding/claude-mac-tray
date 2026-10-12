import SwiftUI

/// Small segmented control in the mock's style (works with any Hashable option,
/// including values that must not appear as a tag in a system Picker).
struct Seg<T: Hashable>: View {
    let options: [T]
    let selection: T?
    let title: (T) -> String
    let onSelect: (T) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { opt in
                Button { onSelect(opt) } label: {
                    Text(title(opt))
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .foregroundStyle(opt == selection ? Color.primary : Color.secondary)
                        .background(opt == selection ? Color.primary.opacity(0.14) : .clear, in: .rect(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8))
    }
}

/// Removable filter chip.
struct FilterChip: View {
    let label: String
    let onRemove: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 9).padding(.trailing, 4).padding(.vertical, 2)
        .background(Color.primary.opacity(0.08), in: Capsule())
    }
}

/// Wrapping row layout for chips and legends.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: maxX, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

extension View {
    /// Padded glass panel used for every section of the analytics window.
    func analyticsPanel(padding: CGFloat = 12) -> some View {
        self.padding(padding).glassCard(cornerRadius: 12)
    }
}

/// Uppercase section caption used in the inspector and popovers.
struct SectionCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

/// Colors for series names: families share ModelStyle hues, long tails fall to gray.
struct SeriesPalette {
    let domain: [String]
    let range: [Color]
    private let lookup: [String: Color]

    init(names: [String]) {
        let scale = ModelStyle.scale(for: names)
        var colors = scale.range
        for (i, n) in scale.domain.enumerated() where n == AnalyticsEngine.otherKey || n == AnalyticsEngine.noToolKey {
            colors[i] = .gray
        }
        domain = scale.domain
        range = colors
        lookup = Dictionary(uniqueKeysWithValues: zip(scale.domain, colors))
    }

    func color(_ name: String) -> Color { lookup[name] ?? .gray }
}
