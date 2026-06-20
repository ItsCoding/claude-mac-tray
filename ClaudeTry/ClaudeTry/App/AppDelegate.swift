import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    @MainActor private let store = UsageStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Claude Usage")
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 560, height: 640)
        popover.behavior = .transient
        // PopoverRootView is wired in Task 6; placeholder until then
        popover.contentViewController = NSHostingController(
            rootView: Text("Loading...").frame(width: 560, height: 200)
        )

        store.startPolling()

        Task { @MainActor in
            while true {
                self.updateStatusLabel()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    @MainActor
    private func updateStatusLabel() {
        if let cost = store.totalCost(for: .today) {
            statusItem.button?.title = String(format: " $%.2f", cost)
        } else {
            let count = store.filteredSessions(for: .today).count
            statusItem.button?.title = count > 0 ? " \(count)" : ""
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
