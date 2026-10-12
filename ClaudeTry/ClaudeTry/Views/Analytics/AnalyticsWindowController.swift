import AppKit
import SwiftUI

/// Owns the single "ClaudeTry Analytics" window. The app is an accessory
/// (LSUIElement) menu-bar app, which cannot show a menu bar or reliably take key
/// focus, so the activation policy is raised to `.regular` while the window is
/// open and dropped back to `.accessory` when it closes. While closed, the SwiftUI
/// content is torn down so no dataset rebuilds or timers keep running.
@MainActor
final class AnalyticsWindowController: NSObject, NSWindowDelegate {
    static let shared = AnalyticsWindowController()

    private var window: NSWindow?
    private var viewModel: AnalyticsViewModel?

    func show(store: UsageStore) {
        if window == nil { build() }
        guard let window else { return }
        if window.contentViewController == nil {
            let host = NSHostingController(rootView: AnalyticsRootView(vm: viewModel ?? AnalyticsViewModel()).environment(store))
            host.sizingOptions = []   // window size is user-driven, not content-driven
            let frame = window.frame
            window.contentViewController = host
            window.setFrame(frame, display: false)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func build() {
        viewModel = AnalyticsViewModel()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 900),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "ClaudeTry Analytics"
        w.titlebarAppearsTransparent = true
        w.contentMinSize = NSSize(width: 1100, height: 720)
        w.collectionBehavior = [.fullScreenPrimary]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("ClaudeTryAnalytics")
        if !w.setFrameUsingName("ClaudeTryAnalytics") { w.center() }
        window = w
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Drop the SwiftUI tree (stops .task / TimelineView); the view model keeps the user's state.
        DispatchQueue.main.async { [weak self] in self?.window?.contentViewController = nil }
    }
}
