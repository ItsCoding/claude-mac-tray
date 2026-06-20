import SwiftUI

struct PopoverRootView: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        TabView {
            OverviewTab()
                .tabItem { Label("Overview", systemImage: "chart.bar.fill") }
            UsageChartsTab()
                .tabItem { Label("Charts", systemImage: "chart.line.uptrend.xyaxis") }
            ConversationsTab()
                .tabItem { Label("Conversations", systemImage: "bubble.left.and.bubble.right") }
            ProjectsTab()
                .tabItem { Label("Projects", systemImage: "folder") }
            MemoryTab()
                .tabItem { Label("Memory", systemImage: "brain") }
        }
        .padding(12)
        .frame(width: 560, height: 640)
    }
}
