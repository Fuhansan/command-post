import SwiftUI

/// 全局应用状态:登录态 + 选中的会话。
@MainActor
final class AppState: ObservableObject {
    @Published var isLoggedIn: Bool
    @Published var userEmail: String?
    /// 被服务器判为「登录已过期」(账号在别的手机登录,单活动踢下线)→ 回登录页时提示一次。
    @Published var sessionExpiredNotice = false

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
        sessionExpiredNotice = false
        isLoggedIn = true
    }

    func logout() {
        KeychainStore.delete(Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: accountKey)
        userEmail = nil
        isLoggedIn = false
    }

    /// 服务器判定登录已过期(账号在其它手机登录)→ 清登录态并标记提示。
    func sessionExpired() {
        guard isLoggedIn else { return }
        logout()
        sessionExpiredNotice = true
    }
}

/// 一个在线的电脑代理(会话入口)。PROTOCOL §8.1 auth_ok.agents。
struct AgentInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let online: Bool             // WS 是否连着中转(电脑是否开机联网)
    var suspended: Bool = false  // 被手机端「暂停」(软暂停):电脑保持连接,点「恢复」即继续
}

/// 一台登录此账号的设备(电脑或手机;来自服务器全量登录记录)。
struct DeviceRec: Identifiable, Hashable {
    let id: String
    let name: String
    let role: String             // "AGENT"=电脑 / "CLIENT"=手机
    let online: Bool
    var isComputer: Bool { role == "AGENT" }
}
