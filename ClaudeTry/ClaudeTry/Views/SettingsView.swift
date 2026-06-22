import SwiftUI

/// Budgets + statusline integration. Presented from the dashboard header gear.
struct SettingsView: View {
    private let config: AppConfig
    private let installer: StatuslineInstaller

    @State private var weekly: Double
    @State private var session: Double
    @State private var installed: Bool
    @State private var errorText: String?

    init(config: AppConfig = AppConfig(), installer: StatuslineInstaller = .standard()) {
        self.config = config
        self.installer = installer
        let b = config.budgets
        _weekly = State(initialValue: b.weeklyUSD)
        _session = State(initialValue: b.sessionUSD)
        _installed = State(initialValue: installer.isInstalled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Budgets (Bedrock mode)").font(.subheadline.weight(.semibold))
                budgetField("Weekly budget", value: $weekly)
                budgetField("Session budget (5h)", value: $session)
                Text("Used when no Claude.ai rate-limit data is available.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Live usage integration").font(.subheadline.weight(.semibold))
                Text(installed ? "Installed — capturing usage from Claude Code's statusline."
                               : "Not installed. Captures live usage and chains to any existing statusline.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button(installed ? "Uninstall" : "Install statusline integration") {
                    toggleInstall()
                }
                .controlSize(.small)
                if let errorText {
                    Text(errorText).font(.caption2).foregroundStyle(.red)
                }
            }
        }
        .padding(18)
        .frame(width: 320)
    }

    private func budgetField(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 80).multilineTextAlignment(.trailing)
                .onChange(of: value.wrappedValue) { _, _ in
                    config.budgets = Budgets(weeklyUSD: weekly, sessionUSD: session)
                }
            Stepper("", value: value, in: 0...100_000, step: 5).labelsHidden()
        }
    }

    private func toggleInstall() {
        errorText = nil
        do {
            if installed { try installer.uninstall() } else { try installer.install() }
            installed = installer.isInstalled
        } catch {
            errorText = "Could not update ~/.claude/settings.json."
        }
    }
}
