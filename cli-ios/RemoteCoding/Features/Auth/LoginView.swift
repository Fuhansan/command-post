import SwiftUI
import GoogleSignIn

/// 登录页。主力为账号密码(只连你自己的服务器,国内单 Tailscale 即可);
/// Google 登录作为可选(需能访问 Google,与 Tailscale 在 iOS 上互斥)。
struct LoginView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage(RelayClient.hostKey) private var serverHost: String = RelayClient.defaultHost
    @AppStorage(RelayClient.portKey) private var serverPort: Int = RelayClient.defaultPort

    @State private var host = ""
    @State private var portText = ""
    @State private var reachable = false
    @State private var testing = false
    @State private var serverMsg: String?

    @State private var account = ""
    @State private var password = ""
    @State private var isRegister = false
    @State private var loading = false
    @State private var errorMessage: String?

    private var port: Int { Int(portText) ?? 0 }
    private var serverValid: Bool { !RelayClient.sanitizeHost(host).isEmpty && (1...65535).contains(port) }
    private var canSubmit: Bool {
        reachable && !account.trimmingCharacters(in: .whitespaces).isEmpty && password.count >= 4
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    Spacer(minLength: 28)
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Theme.blueBtn.gradient)
                        .frame(width: 68, height: 68)
                        .overlay(Image(systemName: "terminal.fill").font(.system(size: 30)).foregroundStyle(.white))
                    Text("AI Coding Remote")
                        .font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)

                    serverCard
                    loginCard

                    if let errorMessage {
                        Text(errorMessage).font(.system(size: 13)).foregroundStyle(Theme.coral)
                            .multilineTextAlignment(.center)
                    }
                    Spacer(minLength: 20)
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear { host = serverHost; portText = String(serverPort) }
    }

    // MARK: - 服务器

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("中转服务器(电脑的局域网 / Tailscale IP)")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSec)
            HStack(spacing: 10) {
                field($host, prompt: "IP,如 100.84.170.113", keyboard: .URL, width: nil)
                    .onChange(of: host) { _, _ in reachable = false; serverMsg = nil }
                field($portText, prompt: "端口", keyboard: .numberPad, width: 78)
                    .onChange(of: portText) { _, _ in reachable = false; serverMsg = nil }
            }
            Button(action: testConnection) {
                HStack(spacing: 6) {
                    if testing { ProgressView().controlSize(.mini) }
                    else { Image(systemName: reachable ? "checkmark.circle.fill" : "wifi") }
                    Text(testing ? "测试中…" : (reachable ? "连接正常" : "测试连接"))
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(reachable ? Theme.green : Theme.blueBtn)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain).disabled(testing || !serverValid)
            if let m = serverMsg {
                Text(m).font(.system(size: 12)).foregroundStyle(reachable ? Theme.green : Theme.coral)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }

    // MARK: - 登录 / 注册

    private var loginCard: some View {
        VStack(spacing: 12) {
            Picker("", selection: $isRegister) {
                Text("登录").tag(false)
                Text("注册").tag(true)
            }
            .pickerStyle(.segmented)

            field($account, prompt: "账号(任意字符,如邮箱或昵称)", keyboard: .default, width: nil)
                .textContentType(.username)
            SecureField("", text: $password, prompt: Text("密码(至少 4 位)").foregroundColor(Theme.textTer))
                .font(.system(size: 15)).foregroundStyle(Theme.text)
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(Theme.field)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            Button(action: submitCredentials) {
                HStack(spacing: 8) {
                    if loading { ProgressView().tint(.white) }
                    Text(isRegister ? "注册并登录" : "登录")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(canSubmit ? Theme.blueBtn : Theme.cardHi)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain).disabled(!canSubmit || loading)

            if !reachable {
                Text("请先在上方测试连接到服务器")
                    .font(.system(size: 12)).foregroundStyle(Theme.textTer)
            }

            // 分隔 + Google(可选)
            HStack {
                Rectangle().fill(Theme.stroke).frame(height: 1)
                Text("或").font(.system(size: 12)).foregroundStyle(Theme.textTer)
                Rectangle().fill(Theme.stroke).frame(height: 1)
            }
            Button(action: signInGoogle) {
                HStack(spacing: 8) {
                    Image(systemName: "g.circle.fill").font(.system(size: 18))
                    Text("使用 Google 登录").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(reachable ? Theme.text : Theme.textTer)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(Theme.cardHi)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain).disabled(loading || !reachable)
            Text("Google 需能访问 Google 服务(国内须额外代理,与 Tailscale 互斥)")
                .font(.system(size: 11)).foregroundStyle(Theme.textTer)
                .multilineTextAlignment(.center)
        }
        .padding(16).cardStyle()
    }

    private func field(_ text: Binding<String>, prompt: String, keyboard: UIKeyboardType, width: CGFloat?) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundColor(Theme.textTer))
            .font(.system(size: 15, design: keyboard == .URL ? .monospaced : .default))
            .foregroundStyle(Theme.text)
            .keyboardType(keyboard).autocorrectionDisabled().textInputAutocapitalization(.never)
            .frame(width: width)
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(Theme.field)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 动作

    private func testConnection() {
        testing = true; serverMsg = nil; reachable = false
        let h = RelayClient.sanitizeHost(host), p = port
        Task {
            let r = await RelayClient.testServer(host: h, port: p)
            if r.ok { serverHost = h; serverPort = p; reachable = true }
            serverMsg = r.ok ? r.message
                : "✗ \(r.message) —— 检查 IP/端口、电脑服务器是否运行、手机 Tailscale 是否连接"
            testing = false
        }
    }

    private func submitCredentials() {
        errorMessage = nil; loading = true
        let acc = account.trimmingCharacters(in: .whitespaces), pwd = password
        let reg = isRegister
        Task {
            do {
                let r = reg ? try await AuthAPI.register(account: acc, password: pwd)
                            : try await AuthAPI.login(account: acc, password: pwd)
                appState.login(account: r.account, token: r.token)
            } catch {
                errorMessage = error.localizedDescription
            }
            loading = false
        }
    }

    private func signInGoogle() {
        guard reachable else { return }
        guard let rootVC = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first?.rootViewController else { return }
        errorMessage = nil; loading = true
        GIDSignIn.sharedInstance.signIn(withPresenting: rootVC) { result, error in
            Task { @MainActor in
                if let error {
                    loading = false
                    if (error as NSError).code != GIDSignInError.canceled.rawValue {
                        errorMessage = "Google 登录失败: \(error.localizedDescription)"
                    }
                    return
                }
                guard let idToken = result?.user.idToken?.tokenString else {
                    loading = false; errorMessage = "未取得 Google 凭证,请重试"; return
                }
                do {
                    let r = try await AuthAPI.loginWithGoogle(idToken: idToken)
                    appState.login(account: r.account, token: r.token)
                } catch {
                    errorMessage = error.localizedDescription
                }
                loading = false
            }
        }
    }
}
