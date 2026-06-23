import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var labelTask: Task<Void, Never>?
    private let store = UsageStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = StatusBarIcon.image()
            button.imagePosition = .imageLeft
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover = NSPopover()
        // Fixed size, set once and never changed while shown. NSPopover re-derives
        // its window frame from the positioning rect on every contentSize change
        // (and on a far-right status item that re-derivation drifts horizontally) —
        // there is no API to pin it. So instead of resizing live, the content is a
        // constant height and pages scroll within it. This removes the drift at its
        // source rather than trying to counteract AppKit's re-anchoring.
        popover.contentSize = NSSize(width: 460, height: 570)
        popover.behavior = .transient
        popover.animates = false
        let root = PopoverRootView().environment(store)
        popover.contentViewController = NSHostingController(rootView: root)

        store.startPolling()

        labelTask = Task { @MainActor in
            while !Task.isCancelled {
                self.updateStatusLabel()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        labelTask?.cancel()
    }

    @MainActor
    private func updateStatusLabel() {
        // Skip while the popover is open: the status item is variableLength, so
        // changing the title's width reflows the button and drags the anchored
        // popover sideways. Refresh once it's closed.
        guard !popover.isShown else { return }
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
            // Accessory (LSUIElement) apps aren't active when the status item is
            // clicked, so the popover never becomes key (no focus) and .transient
            // dismissal can't see outside clicks. Activating fixes both.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
