import Foundation

/// USD budgets the Bedrock-mode bars fill toward. A value <= 0 means "unset".
struct Budgets: Equatable {
    var weeklyUSD: Double
    var sessionUSD: Double
}

/// `UserDefaults`-backed app settings: the configurable budgets and a backup of
/// any statusline command we replaced at install time (so uninstall can restore it).
final class AppConfig {
    private let defaults: UserDefaults
    private enum Key {
        static let weekly = "budget.weeklyUSD"
        static let session = "budget.sessionUSD"
        static let prevStatusLine = "statusline.previous"
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var budgets: Budgets {
        get {
            Budgets(
                weeklyUSD: defaults.object(forKey: Key.weekly) as? Double ?? 50,
                sessionUSD: defaults.object(forKey: Key.session) as? Double ?? 10
            )
        }
        set {
            defaults.set(newValue.weeklyUSD, forKey: Key.weekly)
            defaults.set(newValue.sessionUSD, forKey: Key.session)
        }
    }

    var previousStatusLine: String? {
        get { defaults.string(forKey: Key.prevStatusLine) }
        set {
            if let newValue { defaults.set(newValue, forKey: Key.prevStatusLine) }
            else { defaults.removeObject(forKey: Key.prevStatusLine) }
        }
    }
}
