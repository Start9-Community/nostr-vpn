import Darwin
import Foundation
import UIKit

private struct DebugProcessCpuSample {
    let pid: Int
    let cpuSeconds: Double
}

extension AppModel {
    func runDebugIdleCpuProbe(arguments: [String]) async {
        #if DEBUG
        let previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        }
        let resultName = Self.argumentValue(after: "--nvpn-debug-idle-cpu-result", in: arguments)
            ?? "debug-idle-cpu.json"
        let sampleSeconds = Self.clampedDoubleArgument(
            "--nvpn-debug-idle-cpu-sample-seconds",
            in: arguments,
            defaultValue: 10,
            minValue: 0.1,
            maxValue: 120
        )
        let settleSeconds = Self.clampedDoubleArgument(
            "--nvpn-debug-idle-cpu-settle-seconds",
            in: arguments,
            defaultValue: 3,
            minValue: 0,
            maxValue: 120
        )
        let maxPercent = Self.clampedDoubleArgument(
            "--nvpn-debug-idle-cpu-max-percent",
            in: arguments,
            defaultValue: 5,
            minValue: 0,
            maxValue: 100
        )
        let process = Self.argumentValue(
            after: "--nvpn-debug-idle-cpu-process",
            in: arguments
        ) ?? "app"
        let label = process == "packet-tunnel" ? "iOS packet tunnel" : "iOS app"
        let requireConnected = arguments.contains("--nvpn-debug-idle-cpu-require-connected")
        let startedAt = Date()
        var result: [String: Any] = [
            "ok": false,
            "phase": "settling",
            "label": label,
            "process": process,
            "maxPercent": maxPercent,
            "sampleSeconds": sampleSeconds,
            "settleSeconds": settleSeconds,
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
        ]
        for (key, value) in Self.appBuildMetadata() {
            result[key] = value
        }
        writeDebugProbeResult(result, name: resultName)
        if settleSeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(settleSeconds * 1_000_000_000))
        }
        guard let start = await debugProcessCpuSample(process: process) else {
            result["phase"] = "finished"
            result["error"] = "idle CPU process metrics unavailable"
            result["finishedAt"] = ISO8601DateFormatter().string(from: Date())
            writeDebugProbeResult(result, name: resultName)
            return
        }
        let sampleStartedAt = Date()
        result["phase"] = "sampling"
        result["pid"] = start.pid
        result["sampleStartedAt"] = ISO8601DateFormatter().string(from: sampleStartedAt)
        writeDebugProbeResult(result, name: resultName)
        var connectionSamples: [[String: Any]] = []
        if requireConnected {
            repeat {
                guard let sample = await debugConnectedCpuSample(since: sampleStartedAt) else {
                    result["phase"] = "finished"
                    result["error"] = "connected VPN runtime unavailable during CPU sampling"
                    writeDebugProbeResult(result, name: resultName)
                    return
                }
                connectionSamples.append(sample)
                let remaining = sampleSeconds - Date().timeIntervalSince(sampleStartedAt)
                if remaining <= 0 { break }
                try? await Task.sleep(nanoseconds: UInt64(min(5, remaining) * 1_000_000_000))
            } while true
            result["connectionSamples"] = connectionSamples
        } else {
            try? await Task.sleep(nanoseconds: UInt64(sampleSeconds * 1_000_000_000))
        }
        let elapsed = max(0.001, Date().timeIntervalSince(sampleStartedAt))
        guard let end = await debugProcessCpuSample(process: process) else {
            result["phase"] = "finished"
            result["error"] = "idle CPU process exited during sampling"
            result["finishedAt"] = ISO8601DateFormatter().string(from: Date())
            writeDebugProbeResult(result, name: resultName)
            return
        }
        guard end.pid == start.pid, end.cpuSeconds >= start.cpuSeconds else {
            result["phase"] = "finished"
            result["error"] = "idle CPU process restarted during sampling"
            result["finishedAt"] = ISO8601DateFormatter().string(from: Date())
            writeDebugProbeResult(result, name: resultName)
            return
        }
        let cpuSeconds = end.cpuSeconds - start.cpuSeconds
        let cpuPercent = cpuSeconds * 100.0 / elapsed
        result["phase"] = "finished"
        result["ok"] = cpuPercent <= maxPercent
        result["cpuPercent"] = cpuPercent
        result["elapsedSeconds"] = elapsed
        result["cpuSeconds"] = cpuSeconds
        result["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        result["debugProbeElapsedMs"] = Self.elapsedMilliseconds(since: startedAt)
        writeDebugProbeResult(result, name: resultName)
        #endif
    }

    private func debugProcessCpuSample(process: String) async -> DebugProcessCpuSample? {
        if process == "packet-tunnel" {
            guard let metrics = await vpnController.packetTunnelProcessMetrics() else {
                return nil
            }
            return DebugProcessCpuSample(pid: metrics.pid, cpuSeconds: metrics.cpuSeconds)
        }
        guard process == "app", let cpuSeconds = Self.processCpuSeconds() else {
            return nil
        }
        return DebugProcessCpuSample(pid: Int(getpid()), cpuSeconds: cpuSeconds)
    }

    nonisolated private static func processCpuSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return nil
        }
        return Double(usage.ru_utime.tv_sec)
            + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec)
            + Double(usage.ru_stime.tv_usec) / 1_000_000
    }

    private func debugConnectedCpuSample(since start: Date) async -> [String: Any]? {
        guard let metrics = await vpnController.packetTunnelProcessMetrics(),
              let json = await vpnController.runtimeStateJson(),
              let data = json.data(using: .utf8),
              let runtime = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let relays = runtime["relays"] as? [[String: Any]] ?? []
        return [
            "elapsedSeconds": Date().timeIntervalSince(start),
            "pid": metrics.pid,
            "vpnActive": runtime["vpnActive"] as? Bool ?? false,
            "fipsPeerCount": (runtime["fipsDirectRosterPeerCount"] as? Int ?? 0)
                + (runtime["fipsOtherPeerCount"] as? Int ?? 0),
            "connectedRelayCount": relays.filter {
                ($0["enabled"] as? Bool == true) && ($0["status"] as? String == "connected")
            }.count,
        ]
    }
}
