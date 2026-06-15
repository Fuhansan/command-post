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

/// 配对流程(设置窗口里使用):取码 → 展示 → 轮询 → 拿到 Agent token。
@MainActor
final class PairingController: ObservableObject {
    enum State: Equatable {
        case idle
        case fetching
        case waiting(code: String)
        case done(account: String)
        case failed(String)
    }
    @Published var state: State = .idle

    private static var api: String { "\(AgentServer.httpBase)/api/pair" }
    private var pollTask: Task<Void, Never>?

    func start() {
        pollTask?.cancel()
        state = .fetching
        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let code = try await Self.fetchCode()
                self.state = .waiting(code: code)
                // 轮询认领结果(2s 间隔,10 分钟由服务端过期)
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    if let result = try await Self.poll(code: code) {
                        AgentCredentials.save(account: result.account, token: result.token)
                        self.state = .done(account: result.account)
                        return
                    }
                }
            } catch {
                self.state = .failed("配对失败: \(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        if case .waiting = state { state = .idle }
    }

    private static func fetchCode() async throws -> String {
        var req = URLRequest(url: URL(string: "\(api)/start")!, timeoutInterval: 8)
        req.httpMethod = "POST"
        let (data, _) = try await URLSession.direct.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let code = obj["code"] else { throw URLError(.badServerResponse) }
        return code
    }

    /// 认领完成返回凭据;仍在等待返回 nil;过期抛错。
    private static func poll(code: String) async throws -> (account: String, token: String)? {
        let (data, resp) = try await URLSession.direct.data(
            from: URL(string: "\(api)/poll?code=\(code)")!)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "pair", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "配对码已过期,请重新开始"])
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw URLError(.badServerResponse)
        }
        if obj["status"] == "ok", let a = obj["account"], let t = obj["token"] { return (a, t) }
        return nil
    }
}
