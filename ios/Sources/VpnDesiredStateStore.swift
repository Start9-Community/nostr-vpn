import Foundation

struct VpnDesiredStateStore {
    static let key = "vpnDesiredEnabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func restore(runtimeEnabled: Bool) -> Bool {
        if defaults.object(forKey: Self.key) != nil {
            return defaults.bool(forKey: Self.key)
        }
        if runtimeEnabled {
            defaults.set(true, forKey: Self.key)
        }
        return runtimeEnabled
    }

    func recordRequest(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.key)
    }

    func presentationEnabled(runtimeEnabled: Bool) -> Bool {
        return restore(runtimeEnabled: runtimeEnabled)
    }

    func permitsAutomaticStart() -> Bool {
        defaults.object(forKey: Self.key) == nil
            || defaults.bool(forKey: Self.key)
    }
}
