import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var relay: RelayClient
    @EnvironmentObject private var updater: UpdateChecker

    var body: some View {
        Group {
            if case .forceUpdate(let info) = updater.status {
                ForceUpdateView(info: info)   // 低于最低可用版本:全屏拦截
            } else if appState.isLoggedIn {
                MainTabView()
            } else {
                LoginView()
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $updater.showAnnouncement) {
            if case .updateAvailable(let info) = updater.status {
                AnnouncementSheet(info: info)
            }
        }
        .task { await updater.check() }   // 启动静默检查版本/公告
        .onAppear { if appState.isLoggedIn { relay.connect(account: appState.account) } }
        .onChange(of: appState.isLoggedIn) { _, loggedIn in
            if loggedIn { relay.connect(account: appState.account) }
            else { relay.disconnect() }
        }
    }
}
