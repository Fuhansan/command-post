import SwiftUI
import GoogleSignIn

/// 登录页:只走 Google 外部登录。
/// 流程:GoogleSignIn SDK 拿 idToken → 服务器 /api/auth/google 校验 →
/// 换本系统 {account, token} → 进入主界面,WS 用该 token 配对 Agent。
struct LoginView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage(RelayClient.hostKey) private var serverHost: String = RelayClient.defaultHost
    @AppStorage(RelayClient.portKey) private var serverPort: Int = RelayClient.defaultPort
    @State private var hostDraft = ""
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var showServer = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                RoundedRectangle(cornerRadius: 22)
                    .fill(Theme.blueBtn.gradient)
                    .frame(width: 88, height: 88)
                    .overlay(Image(systemName: "terminal.fill")
                        .font(.system(size: 40)).foregroundStyle(.white))
                Text("AI Coding Remote")
                    .font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)
                Text("登录后,你的电脑代理会自动出现")
                    .font(.system(size: 14)).foregroundStyle(Theme.textSec)

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
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(loading)
                .padding(.horizontal, 8)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13)).foregroundStyle(Theme.coral)
                        .multilineTextAlignment(.center)
                }

                // 服务器地址(首次使用需先指向自己的中转服务器,登录 REST 也走它)
                VStack(spacing: 8) {
                    Button {
                        withAnimation { showServer.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "server.rack").font(.system(size: 12))
                            Text("服务器: \(serverHost)")
                                .font(.system(size: 13, design: .monospaced))
                            Image(systemName: showServer ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(Theme.textSec)
                    }
                    if showServer {
                        HStack(spacing: 8) {
                            TextField("", text: $hostDraft,
                                      prompt: Text("IP / 主机名").foregroundColor(Theme.textTer))
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundStyle(Theme.text)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(Theme.field)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            Button("保存") {
                                let h = RelayClient.sanitizeHost(hostDraft)
                                if !h.isEmpty { serverHost = h }
                                hostDraft = serverHost
                                withAnimation { showServer = false }
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.blue)
                        }
                        .padding(.horizontal, 8)
                    }
                }
                Spacer()
            }
            .padding(24)
        }
        .onAppear { hostDraft = serverHost }
    }

    private func signIn() {
        guard let rootVC = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first?.rootViewController else { return }
        errorMessage = nil
        loading = true
        GIDSignIn.sharedInstance.signIn(withPresenting: rootVC) { result, error in
            Task { @MainActor in
                if let error {
                    loading = false
                    // 用户主动取消不算错误
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
