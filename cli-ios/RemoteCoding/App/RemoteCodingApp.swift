import SwiftUI

@main
struct RemoteCodingApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var relay = RelayClient()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(relay)
        }
    }
}
