import SwiftUI

struct PopoverRootView: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        TabView {
            OverviewTab()
                .tabItem { Label("Overview", systemImage: "chart.bar.fill") }
            UsageChartsTab()
                .tabItem { Label("Charts", systemImage: "chart.line.uptrend.xyaxis") }
            ProjectsTab()
                .tabItem { Label("Projects", systemImage: "folder") }
        }
        .padding(12)
        .frame(width: 560, height: 640)
    }
}
