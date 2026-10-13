import SwiftUI

/// Day-of-week x hour-of-day heatmap of the selected metric over the window
/// (ignores grouping; filters still apply).
struct AnalyticsHeatmapView: View {
    let result: AnalyticsResult
    private static let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        let metric = result.metric
        let values = result.heat.map { $0.map(metric.value) }
        let peak = max(values.flatMap { $0 }.max() ?? 0, 1e-9)
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                Color.clear.frame(width: 36, height: 14)
                ForEach(0..<24, id: \.self) { h in
                    Text(h % 3 == 0 ? String(format: "%02d", h) : "")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<7, id: \.self) { d in
                GridRow {
                    Text(Self.days[d]).font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                    ForEach(0..<24, id: \.self) { h in
                        let v = values[d][h]
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(v > 0 ? 0.12 + 0.88 * v / peak : 0.05))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .help("\(Self.days[d]) \(String(format: "%02d", h)):00 · \(metric.title) \(metric.format(v)) · \(AnalyticsFormat.number(result.heat[d][h].sessions)) sessions")
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}
