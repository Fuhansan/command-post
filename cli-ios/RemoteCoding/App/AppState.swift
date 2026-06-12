import SwiftUI

/// 全局应用状态:登录态 + 选中的会话。
@MainActor
final class AppState: ObservableObject {
    @Published var isLoggedIn: Bool
    @Published var userEmail: String?

    static let tokenKey = "auth_token"
    private let accountKey = "relay_account"

    /// 中转配对账号(= 登录邮箱)。RelayClient 据此与 Agent 配对,冷启动也能恢复。
    var account: String { userEmail ?? "demo" }

    /// 当前会话令牌(WS auth 时携带,服务器据此解析账号)。
    static var sessionToken: String? { KeychainStore.load(tokenKey) }

    init() {
        let token = KeychainStore.load(Self.tokenKey)
        self.isLoggedIn = token != nil
        self.userEmail = UserDefaults.standard.string(forKey: accountKey)
    }

    /// 登录成功(Google 等外部登录换到本系统 token 后调用)。
    func login(account: String, token: String) {
        userEmail = account
        UserDefaults.standard.set(account, forKey: accountKey)
        KeychainStore.save(token, for: Self.tokenKey)
        isLoggedIn = true
    }

    func logout() {
        KeychainStore.delete(Self.tokenKey)
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
    var suspended: Bool = false   // 被手机端「断开」挂起,可点重连恢复
}
