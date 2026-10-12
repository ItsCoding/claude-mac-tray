import SwiftUI
import Charts

/// Brush: daily totals over the full history. Drag to zoom the main chart.
struct AnalyticsMiniTimeline: View {
    @Bindable var vm: AnalyticsViewModel
    @State private var dragStart: CGFloat?
    @State private var dragEnd: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Timeline · drag to zoom · daily totals").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset zoom") { vm.resetZoom() }.controlSize(.small)
            }
            if let r = vm.result, !r.mini.starts.isEmpty {
                let win = r.query.window
                let peak = max(r.mini.values.max() ?? 0, 1)
                Chart {
                    ForEach(Array(r.mini.starts.enumerated()), id: \.offset) { i, d in
                        BarMark(x: .value("Day", d, unit: .day), y: .value("v", r.mini.values[i]))
                            .foregroundStyle(Color.secondary.opacity(0.35))
                    }
                    RectangleMark(xStart: .value("From", max(win.start, r.mini.starts[0])),
                                  xEnd: .value("To", min(win.end, Date())),
                                  yStart: .value("lo", 0), yEnd: .value("hi", peak))
                        .foregroundStyle(Color.accentColor.opacity(0.18))
                }
                .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                .chartYScale(domain: 0...peak)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        let frame = proxy.plotFrame.map { geo[$0] } ?? .zero
                        ZStack(alignment: .topLeading) {
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 3)
                                    .onChanged { g in
                                        dragStart = g.startLocation.x
                                        dragEnd = g.location.x
                                    }
                                    .onEnded { g in
                                        defer { dragStart = nil; dragEnd = nil }
                                        let a = min(g.startLocation.x, g.location.x) - frame.minX
                                        let b = max(g.startLocation.x, g.location.x) - frame.minX
                                        guard let d0: Date = proxy.value(atX: a), let d1: Date = proxy.value(atX: b) else { return }
                                        let cal = Calendar.current
                                        let start = cal.startOfDay(for: d0)
                                        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: d1)) ?? d1
                                        vm.applyZoom(start: start, end: end)
                                    })
                            if let s = dragStart, let e = dragEnd {
                                Rectangle().fill(Color.accentColor.opacity(0.25))
                                    .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.8)))
                                    .frame(width: abs(e - s), height: frame.height)
                                    .offset(x: min(s, e), y: frame.minY)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
            } else {
                Spacer()
            }
        }
        .analyticsPanel(padding: 10)
    }
}
