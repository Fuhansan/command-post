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
        NotificationCenter.default.post(name: .relayCredentialsChanged, object: nil)
    }
}

extension Notification.Name {
    /// 配对成功/退出登录 → RelayAgent 用新身份重连。
    static let relayCredentialsChanged = Notification.Name("vibenotch.relayCredentialsChanged")
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

    private static let api = "http://127.0.0.1:8080/api/pair"
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
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let code = obj["code"] else { throw URLError(.badServerResponse) }
        return code
    }

    /// 认领完成返回凭据;仍在等待返回 nil;过期抛错。
    private static func poll(code: String) async throws -> (account: String, token: String)? {
        let (data, resp) = try await URLSession.shared.data(
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
