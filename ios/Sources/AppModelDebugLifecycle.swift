import Foundation

extension AppModel {
    func armDebugLifecycleProbeIfRequested(arguments: [String]) -> Bool {
        #if DEBUG
        guard let requestedName = Self.argumentValue(
            after: "--nvpn-debug-lifecycle-result",
            in: arguments
        ) else {
            return false
        }
        let safeName = requestedName
            .split(separator: "/")
            .last
            .map(String.init) ?? ""
        guard !safeName.isEmpty else {
            return false
        }
        lifecycleProbeResultName = safeName
        lifecycleProbeTransition = 0
        writeDebugLifecycleProbe(phase: "armed")
        return true
        #else
        return false
        #endif
    }

    func writeDebugLifecycleProbe(phase: String) {
        #if DEBUG
        guard let lifecycleProbeResultName else {
            return
        }
        lifecycleProbeTransition += 1
        let coreAvailable = core != nil
        writeDebugProbeResult(
            [
                "ok": phase == "background" ? !coreAvailable : coreAvailable,
                "phase": phase,
                "nativeCoreAvailable": coreAvailable,
                "transition": lifecycleProbeTransition,
            ],
            name: lifecycleProbeResultName
        )
        #endif
    }
}
