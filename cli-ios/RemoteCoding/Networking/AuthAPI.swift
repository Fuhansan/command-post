import Foundation

/// 登录 REST(服务器 8080)。Google idToken → 本系统 {account, token}。
enum AuthAPI {
    struct AuthResult: Decodable {
        let account: String
        let token: String
        let name: String?
        let hasPassword: String?   // Google 返回:"true"/"false"(是否已设密码)
    }

    enum AuthError: LocalizedError {
        case server(String)
        var errorDescription: String? {
            if case .server(let m) = self { return m }
            return nil
        }
    }

    /// REST 基地址:沿用设置页的服务器 IP,端口固定 8080(Spring MVC)。
    @MainActor
    static var baseURL: String { "http://\(RelayClient.savedHost):8080/api/auth" }

    /// 认领电脑端的配对码:把 VibeNotch 绑到当前登录账号下。
    @MainActor
    static func claimPair(code: String) async throws {
        guard let token = AppState.sessionToken else { throw AuthError.server("请先登录") }
        guard let url = URL(string: "http://\(RelayClient.savedHost):8080/api/pair/claim") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["code": code, "token": token])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw AuthError.server(msg ?? "配对失败(\(http.statusCode))")
        }
    }

    /// 用 Google idToken 换本系统会话令牌。
    @MainActor
    static func loginWithGoogle(idToken: String) async throws -> AuthResult {
        guard let url = URL(string: "\(baseURL)/google") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["idToken": idToken])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw AuthError.server(msg ?? "登录失败(\(http.statusCode))")
        }
        return try JSONDecoder().decode(AuthResult.self, from: data)
    }

    /// 邮箱密码登录(日常主力:不依赖 Google,只连你自己的服务器)。
    @MainActor
    static func login(account: String, password: String) async throws -> AuthResult {
        guard let url = URL(string: "\(baseURL)/login") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["account": account, "password": password])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw AuthError.server(msg ?? "登录失败(\(http.statusCode))")
        }
        return try JSONDecoder().decode(AuthResult.self, from: data)
    }

    /// 忘记密码 - 第一步:请求把验证码发到该邮箱。
    @MainActor
    static func forgotPassword(account: String) async throws {
        guard let url = URL(string: "\(baseURL)/forgot") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["account": account])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw AuthError.server(msg ?? "发送失败(\(http.statusCode))")
        }
    }

    /// 忘记密码 - 第二步:用验证码重设密码。
    @MainActor
    static func resetPassword(account: String, code: String, password: String) async throws {
        guard let url = URL(string: "\(baseURL)/reset") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["account": account, "code": code, "password": password])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw AuthError.server(msg ?? "重置失败(\(http.statusCode))")
        }
    }

    /// 设置密码:用 Google 登录拿到的 token 给账号设密码,之后可邮箱密码登录。
    @MainActor
    static func setPassword(token: String, password: String) async throws {
        guard let url = URL(string: "\(baseURL)/set-password") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["token": token, "password": password])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw AuthError.server(msg ?? "设置密码失败(\(http.statusCode))")
        }
    }
}
