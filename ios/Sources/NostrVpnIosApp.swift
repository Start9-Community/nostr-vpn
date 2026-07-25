import SwiftUI

@main
struct NostrVpnIosApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onOpenURL { url in
                    model.handle(url: url)
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.handleScenePhase(phase)
                }
        }
    }
}
