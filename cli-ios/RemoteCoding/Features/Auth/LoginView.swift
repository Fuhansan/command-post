import SwiftUI
import GoogleSignIn

/// 登录页:先配好并连通中转服务器,再走 Google 登录。
/// 真机默认 127.0.0.1 连不到电脑,所以服务器配置常驻可见、必须先「测试连接」通过,
/// Google 登录按钮才可点(登录的 REST 校验也走这台服务器)。
struct LoginView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage(RelayClient.hostKey) private var serverHost: String = RelayClient.defaultHost
    @AppStorage(RelayClient.portKey) private var serverPort: Int = RelayClient.defaultPort
    @State private var host = ""
    @State private var portText = ""
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var testing = false
    @State private var reachable = false
    @State private var testResult: (ok: Bool, message: String)?

    private var port: Int { Int(portText) ?? 0 }
    private var inputValid: Bool {
        !RelayClient.sanitizeHost(host).isEmpty && (1...65535).contains(port)
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    Spacer(minLength: 40)
                    RoundedRectangle(cornerRadius: 22)
                        .fill(Theme.blueBtn.gradient)
                        .frame(width: 80, height: 80)
                        .overlay(Image(systemName: "terminal.fill")
                            .font(.system(size: 36)).foregroundStyle(.white))
                    Text("AI Coding Remote")
                        .font(.system(size: 23, weight: .bold)).foregroundStyle(Theme.text)
                    Text("先连接你的中转服务器,再登录")
                        .font(.system(size: 14)).foregroundStyle(Theme.textSec)

                    serverCard

                    Button(action: signIn) {
                        HStack(spacing: 10) {
                            if loading {
                                ProgressView().tint(.black)
                            } else {
                                Image(systemName: "g.circle.fill").font(.system(size: 20))
                            }
                            Text(loading ? "登录中…" : "使用 Google 登录")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundStyle(reachable ? .black : Theme.textTer)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(reachable ? Color.white : Theme.cardHi)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(loading || !reachable)

                    if !reachable {
                        Text("请先填写并测试连接到服务器")
                            .font(.system(size: 12)).foregroundStyle(Theme.textTer)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 13)).foregroundStyle(Theme.coral)
                            .multilineTextAlignment(.center)
                    }
                    Spacer(minLength: 20)
                }
                .padding(24)
            }
        }
        .onAppear {
            host = serverHost
            portText = String(serverPort)
        }
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("中转服务器(电脑的局域网 / Tailscale IP)")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSec)
            HStack(spacing: 10) {
                TextField("", text: $host,
                          prompt: Text("IP,如 100.84.194.43").foregroundColor(Theme.textTer))
                    .font(.system(size: 15, design: .monospaced)).foregroundStyle(Theme.text)
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onChange(of: host) { _, _ in reachable = false; testResult = nil }
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .background(Theme.field)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                TextField("", text: $portText,
                          prompt: Text("端口").foregroundColor(Theme.textTer))
                    .font(.system(size: 15, design: .monospaced)).foregroundStyle(Theme.text)
                    .keyboardType(.numberPad)
                    .onChange(of: portText) { _, _ in reachable = false; testResult = nil }
                    .frame(width: 78)
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .background(Theme.field)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Button {
                testing = true; testResult = nil; reachable = false
                let h = RelayClient.sanitizeHost(host), p = port
                Task {
                    let r = await RelayClient.testServer(host: h, port: p)
                    if r.ok {            // 连通 → 落盘地址,放开登录
                        serverHost = h
                        serverPort = p
                        reachable = true
                    }
                    testResult = r
                    testing = false
                }
            } label: {
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
            .buttonStyle(.plain)
            .disabled(testing || !inputValid)

            if let r = testResult, !r.ok {
                Text("✗ \(r.message) —— 检查 IP/端口、电脑服务器是否在运行、手机与电脑是否在同一网络/Tailscale")
                    .font(.system(size: 12)).foregroundStyle(Theme.coral)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func signIn() {
        guard reachable else { return }
        guard let rootVC = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first?.rootViewController else { return }
        errorMessage = nil
        loading = true
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
                    loading = false
                    errorMessage = "未取得 Google 凭证,请重试"
                    return
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
