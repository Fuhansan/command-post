import Foundation

/// Agent 的登录凭据(手机配对授权后获得),存 UserDefaults。
enum AgentCredentials {
    private static let accountKey = "relay.account"
    private static let tokenKey = "relay.token"

    static var account: String? {
        get { UserDefaults.standard.string(forKey: accountKey) }
        set { UserDefaults.standard.set(newValue, forKey: accountKey) }
    }
    static var token: String? {
        get { UserDefaults.standard.string(forKey: tokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: tokenKey) }
    }

    static func save(account: String, token: String) {
        self.account = account
        self.token = token
        NotificationCenter.default.post(name: .relayCredentialsChanged, object: nil)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: accountKey)
        UserDefaults.standard.removeObject(forKey: tokenKey)
        // 旧的文件配置一并清掉,避免退出后又从文件回落到原账号
        try? FileManager.default.removeItem(
            atPath: NSString(string: "~/.vibenotch/account").expandingTildeInPath)
        NotificationCenter.default.post(name: .relayCredentialsChanged, object: nil)
    }
}

/// Agent 连接的中转服务器地址(host)。默认 127.0.0.1(服务器在本机时);
/// 服务器搬到公网 VPS 后,在设置里填 VPS 公网 IP,WS / 图片下载 / 配对都用它。
/// 用 UserDefaults 存 —— nonisolated,可在任意线程读(图片下载在后台线程要用)。
enum AgentServer {
    private static let hostKey = "relay.serverHost"

    static var host: String {
        get {
            let h = (UserDefaults.standard.string(forKey: hostKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return h.isEmpty ? "127.0.0.1" : h
        }
        set {
            UserDefaults.standard.set(
                newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: hostKey)
            // 地址变了 → 复用「凭据变更」通知让 RelayAgent 按新地址重连。
            NotificationCenter.default.post(name: .relayCredentialsChanged, object: nil)
        }
    }

    /// 中转 WebSocket 地址(8090)。
    static var wsURL: URL { URL(string: "ws://\(host):8090/ws")! }
    /// HTTP REST 基址(8080:登录 / 配对 / 图片上传下载)。
    static var httpBase: String { "http://\(host):8080" }
}

extension Notification.Name {
    /// 配对成功/退出登录/服务器地址变更 → RelayAgent 用新身份/新地址重连。
    static let relayCredentialsChanged = Notification.Name("vibenotch.relayCredentialsChanged")
}

extension URLSession {
    /// 直连会话:**禁用系统/环境代理**。
    /// VibeNotch 只连自己的中转服务器,绝不能被给 Claude/Google 用的代理
    /// (如 Clash 127.0.0.1:7890)劫持 —— 否则发往公网 VPS 的请求会被塞进代理,
    /// 报 ATS / 连接失败。配对、WS、图片下载都用这个会话。
    static let direct: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.connectionProxyDictionary = [
            "HTTPEnable": 0,
            "HTTPSEnable": 0,
            "SOCKSEnable": 0,
        ]
        return URLSession(configuration: cfg)
    }()
}

/// 电脑端账号登录(取代配对码):邮箱 + 密码或验证码 → token,存进 AgentCredentials。
/// 与手机同账号才能互发消息。电脑端签发的是普通令牌(不进单活动,不踢手机)。
/// 走 URLSession.direct,HTTP 直连绕开系统代理。
enum DeviceLogin {

    /// 查邮箱是否注册/有密码 —— 登录入口据此分流(密码登录 / 验证码登录 / 注册)。
    static func check(account: String) async throws -> (exists: Bool, hasPassword: Bool) {
        let obj = try await post(path: "/api/auth/check", body: ["account": account])
        return (obj["exists"] as? Bool ?? false, obj["hasPassword"] as? Bool ?? false)
    }

    /// 邮箱+密码登录。
    @discardableResult
    static func login(account: String, password: String) async throws -> String {
        try await auth(path: "/api/auth/device-login", body: ["account": account, "password": password])
    }

    /// 发送登录验证码(账号须已注册)。
    static func sendCode(account: String) async throws {
        _ = try await post(path: "/api/auth/login/code", body: ["account": account])
    }

    /// 邮箱+验证码登录。
    @discardableResult
    static func loginWithCode(account: String, code: String) async throws -> String {
        try await auth(path: "/api/auth/device-login/verify", body: ["account": account, "code": code])
    }

    /// 注册:发送验证码 → 提交(邮箱+码+密码)。注册成功直接得到 token 并登录。
    static func sendRegisterCode(account: String) async throws {
        _ = try await post(path: "/api/auth/register/code", body: ["account": account])
    }
    @discardableResult
    static func register(account: String, code: String, password: String) async throws -> String {
        try await auth(path: "/api/auth/register",
                       body: ["account": account, "code": code, "password": password])
    }

    /// 忘记密码:发码 → 重置(邮箱+码+新密码)。重置后用新密码登录。
    static func sendForgotCode(account: String) async throws {
        _ = try await post(path: "/api/auth/forgot", body: ["account": account])
    }
    static func resetPassword(account: String, code: String, password: String) async throws {
        _ = try await post(path: "/api/auth/reset",
                           body: ["account": account, "code": code, "password": password])
    }

    // ── 底层 ──────────────────────────────────────────────

    /// POST JSON,200 返回解析后的字典,非 200 抛带 server `error` 文案的错误。
    @discardableResult
    private static func post(path: String, body: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "\(AgentServer.httpBase)\(path)")!, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.direct.data(for: req)
        let obj = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "device.login", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: (obj["error"] as? String) ?? "请求失败(连不到服务器?)"])
        }
        return obj
    }

    /// 登录类:POST 后取 {account, token} 存盘并以新身份重连。
    @discardableResult
    private static func auth(path: String, body: [String: String]) async throws -> String {
        let obj = try await post(path: path, body: body)
        guard let acc = obj["account"] as? String, let tok = obj["token"] as? String else {
            throw NSError(domain: "device.login", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "登录返回缺少凭据"])
        }
        await MainActor.run { AgentCredentials.save(account: acc, token: tok) }
        return acc
    }
}

// 配对(PairingController)已移除:改为账号登录(见 DeviceLogin),不再用配对码。
