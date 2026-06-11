import SwiftUI

/// 全局应用状态:登录态 + 选中的会话。
@MainActor
final class AppState: ObservableObject {
    @Published var isLoggedIn: Bool
    @Published var userEmail: String?

    private let tokenKey = "auth_token"
    private let accountKey = "relay_account"

    /// 中转配对账号(= 登录邮箱)。RelayClient 据此与 Agent 配对,冷启动也能恢复。
    var account: String { userEmail ?? "demo" }

    init() {
        let token = KeychainStore.load(tokenKey)
        self.isLoggedIn = token != nil
        self.userEmail = UserDefaults.standard.string(forKey: accountKey)
    }

    /// 登录(脚手架版:本地置位 + 存假 token;真实实现走 PROTOCOL §8.1 auth)。
    func login(email: String) {
        userEmail = email
        UserDefaults.standard.set(email, forKey: accountKey)
        KeychainStore.save("dev-token-\(UUID().uuidString)", for: tokenKey)
        isLoggedIn = true
    }

    func logout() {
        KeychainStore.delete(tokenKey)
        UserDefaults.standard.removeObject(forKey: accountKey)
        userEmail = nil
        isLoggedIn = false
    }
}

/// 一个在线的电脑代理(会话入口)。PROTOCOL §8.1 auth_ok.agents。
struct AgentInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let online: Bool
}
