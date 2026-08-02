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

    func recordStartRequest() {
        defaults.set(true, forKey: Self.key)
    }

    func recordConfirmedExplicitStop() {
        defaults.set(false, forKey: Self.key)
    }
}
