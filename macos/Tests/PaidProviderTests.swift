import AppKit
import SwiftUI

@main
struct PaidProviderTests {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .darkAqua)
        UserDefaults.standard.set(true, forKey: "updates.autoCheck")
        let manager = AppManager()
        precondition(manager.fixtureMode)
        precondition(UserDefaults.standard.bool(forKey: "updates.autoCheck"), "Fixture mode must preserve update preferences")
        // Exercise URL routing while another action holds the queue.
        manager.actionInFlight = true
        let link = URL(string: "nvpn://paid-exit/@npub1example?maxMsatPerGb=1000")!
        manager.handle(url: link)
        precondition(manager.paidExitChooserRequested)
        precondition(manager.pendingPaidExitLink == link.absoluteString)
        manager.actionInFlight = false
        manager.openPendingPaidExitLink()
        precondition(manager.pendingPaidExitLink == nil)
        manager.paidExitChooserRequested = false
        var offer = manager.state.paidRouteMarket.offers[1]
        offer.acceptedMints = ["https://testnut.cashu.space", "https://mint.example/Bitcoin"]
        manager.state.paidRouteMarket.offers[1] = offer
        manager.state.paidRouteMarket.visibleOffers = manager.state.paidRouteMarket.offers
        let session = manager.state.paidRouteMarket.sessions[0]
        let channel = manager.state.paidRouteMarket.channels[0]
        let reasons = [
            "Seller did not acknowledge the session within 30 seconds",
            "Payment setup failed at https://mint.example/Bitcoin: connection refused",
            "Cannot resolve payment mint mint.example: hostname not found",
        ]
        manager.state.paidRouteMarket.sessions = reasons.enumerated().map { index, reason in
            var failed = session
            failed.sessionId = "failed-session-\(index)"
            failed.channelId = "failed-channel-\(index)"
            failed.lifecycleStatus = "failed"
            failed.titleText = "Connection failed"
            failed.statusText = reason
            failed.allowRouting = false
            failed.paymentChannelReady = false
            failed.canRate = false
            failed.usageText = "0 B used"
            failed.paidText = "0 sat paid"
            return failed
        }
        manager.state.paidRouteMarket.channels = reasons.enumerated().map { index, reason in
            var failed = channel
            failed.channelId = "failed-channel-\(index)"
            failed.status = "failed"
            failed.error = reason
            return failed
        }
        manager.state.exitNodeActive = false
        manager.state.exitNodeBlocked = true
        manager.state.exitNodeStatusText = "Automatic paid exit · Payment unavailable · mint.example · Connection refused · Trying another provider · Internet paused by nvpn to prevent leaks"
        let view = NSHostingView(rootView: RootView(manager: manager))
        let rect = NSRect(x: 0, y: 0, width: 1100, height: 900)
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = rect
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        view.layoutSubtreeIfNeeded()
        guard CommandLine.arguments.count > 1 else {
            print("Provider URL queue passed")
            return
        }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("Provider URL queue and failure-reason UI rendering passed")
    }
}
