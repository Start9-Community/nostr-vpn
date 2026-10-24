import AppKit
import SwiftUI

@main
struct NostrVpnMacApp: App {
    @StateObject private var manager: AppManager
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    init() {
        runUpdateE2ECommandIfRequested()
        _manager = StateObject(wrappedValue: AppManager())
    }

    var body: some Scene {
        WindowGroup("Nostr VPN", id: "main") {
            GeometryReader { proxy in
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                        .ignoresSafeArea()
                    RootView(manager: manager)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
                .frame(minWidth: 880, minHeight: 620)
                .onAppear {
                    appDelegate.configure(manager: manager)
                    manager.start()
                }
                .onOpenURL { url in
                    manager.handle(url: url)
                    appDelegate.showMainWindow()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        manager.refresh()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 760)
        .windowResizability(.automatic)

        // The menubar tray is owned by AppDelegate (NSStatusItem-based) so
        // submenus stay open across AppManager state refreshes — SwiftUI's
        // MenuBarExtra would tear down the menu hierarchy on every publish.
    }
}
