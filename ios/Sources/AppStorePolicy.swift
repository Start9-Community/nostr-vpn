import Foundation

enum AppStorePolicy {
    static func allowsVpnStart(disclosureAccepted: Bool) -> Bool {
        disclosureAccepted
    }

    static func compatibilityPatch(for state: AppState) -> [String: Any] {
        var patch: [String: Any] = [:]
        if state.internetSource == "paid_automatic" || state.internetSource == "paid_manual" {
            patch["internetSource"] = "direct"
            patch["exitNode"] = ""
        }
        if state.paidExitSeller.enabled {
            patch["paidExitEnabled"] = false
        }
        if state.walletFiatEnabled {
            patch["walletFiatEnabled"] = false
        }
        return patch
    }

    static func blocks(_ action: [String: Any]) -> Bool {
        let type = action["type"] as? String ?? ""
        if type.contains("paid_route") || type.contains("paid_exit") {
            return true
        }
        guard type == "update_settings",
              let patch = action["patch"] as? [String: Any]
        else {
            return false
        }
        if let source = patch["internetSource"] as? String,
           source == "paid_automatic" || source == "paid_manual"
        {
            return true
        }
        return patch.keys.contains {
            $0.hasPrefix("paidExit") || $0.hasPrefix("walletFiat")
        }
    }
}
