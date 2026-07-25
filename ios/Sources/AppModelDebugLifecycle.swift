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
        lifecycleProbeRunId = Self.argumentValue(
            after: "--nvpn-debug-lifecycle-run-id",
            in: arguments
        ) ?? ""
        lifecycleProbeTransition = 0
        lifecycleProbeHistory.removeAll(keepingCapacity: true)
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
        let event: [String: Any] = [
            "monotonicMilliseconds": Int64(ProcessInfo.processInfo.systemUptime * 1_000),
            "nativeCoreAvailable": coreAvailable,
            "phase": phase,
            "processIdentifier": ProcessInfo.processInfo.processIdentifier,
            "transition": lifecycleProbeTransition,
            "wallClockMilliseconds": Int64(Date().timeIntervalSince1970 * 1_000),
        ]
        lifecycleProbeHistory.append(event)
        writeDebugProbeResult(
            [
                "ok": phase == "background" ? !coreAvailable : coreAvailable,
                "history": lifecycleProbeHistory,
                "phase": phase,
                "nativeCoreAvailable": coreAvailable,
                "runId": lifecycleProbeRunId,
                "transition": lifecycleProbeTransition,
            ],
            name: lifecycleProbeResultName
        )
        #endif
    }
}
