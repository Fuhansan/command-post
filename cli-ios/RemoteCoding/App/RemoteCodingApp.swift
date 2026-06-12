import SwiftUI
import GoogleSignIn

@main
struct RemoteCodingApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var relay = RelayClient()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(relay)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }   // Google 登录回调
        }
    }
}
