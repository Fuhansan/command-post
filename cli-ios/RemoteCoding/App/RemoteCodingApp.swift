import SwiftUI
import GoogleSignIn

@main
struct RemoteCodingApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var relay = RelayClient()
    @StateObject private var updater = UpdateChecker()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(relay)
                .environmentObject(updater)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }   // Google 登录回调
        }
    }
}
