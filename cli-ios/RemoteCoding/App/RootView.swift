import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var relay: RelayClient

    var body: some View {
        Group {
            if appState.isLoggedIn {
                MainTabView()
            } else {
                LoginView()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if appState.isLoggedIn { relay.connect(account: appState.account) } }
        .onChange(of: appState.isLoggedIn) { _, loggedIn in
            if loggedIn { relay.connect(account: appState.account) }
            else { relay.disconnect() }
        }
    }
}
