import SwiftUI

struct PopoverRootView: View {
    @Environment(UsageStore.self) private var store
    var onHeight: (CGFloat) -> Void = { _ in }

    var body: some View {
        DashboardView(onHeight: onHeight)
    }
}
