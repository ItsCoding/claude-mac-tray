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
        popover.contentSize = NSSize(width: 460, height: 480)
        popover.behavior = .transient
        // Resize explicitly from the SwiftUI content's measured height. Setting
        // contentSize keeps the popover anchored to the status item (the arrow
        // stays put and it grows downward); `.preferredContentSize` auto-sizing
        // detaches it and makes it jump on expand/collapse.
        let root = PopoverRootView(onHeight: { [weak self] height in
            guard let self, abs(self.popover.contentSize.height - height) > 1 else { return }
            self.popover.contentSize = NSSize(width: 460, height: height)
        }).environment(store)
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
