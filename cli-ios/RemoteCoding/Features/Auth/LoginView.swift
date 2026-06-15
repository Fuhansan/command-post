import SwiftUI
import GoogleSignIn

/// 登录页。账号体系:
///   注册 = 用 Google 验证邮箱(只此一次,需能访问 Google),首次登录后设置密码;
///   日常 = 邮箱 + 密码(只连自己的服务器,国内单 Tailscale 即可,不再碰 Google)。
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
    @State private var loading = false
    @State private var errorMessage: String?

    // 首次 Google 登录后设密码
    @State private var setPwToken: String?
    @State private var setPwAccount = ""
    @State private var newPassword = ""
    @State private var showSetPassword = false
    @State private var setPwError: String?

    // 忘记密码(邮箱验证码重置)
    @State private var showReset = false
    @State private var resetAccount = ""
    @State private var resetCode = ""
    @State private var resetNewPassword = ""
    @State private var resetCodeSent = false
    @State private var resetSending = false
    @State private var resetInfo: String?
    @State private var resetError: String?

    // 邮箱验证码注册(替代 Google,国内 VPS 可用)
    @State private var showRegister = false
    @State private var regAccount = ""
    @State private var regCode = ""
    @State private var regPassword = ""
    @State private var regCodeSent = false
    @State private var regSending = false
    @State private var regInfo: String?
    @State private var regError: String?

    // 分步流程(仿 App Store:先邮箱,下一步再密码;验证码同理单独一步)
    enum Step { case email, code, password }
    @State private var loginStep: Step = .email
    @State private var regStep: Step = .email
    @State private var resetStep: Step = .email

    private var port: Int { Int(portText) ?? 0 }
    private var serverValid: Bool { !RelayClient.sanitizeHost(host).isEmpty && (1...65535).contains(port) }
    private func isEmail(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).contains("@") }
    private var canLogin: Bool {
        reachable && !account.trimmingCharacters(in: .whitespaces).isEmpty && password.count >= 4
    }
    private var canSendReset: Bool {
        reachable && resetAccount.trimmingCharacters(in: .whitespaces).contains("@")
    }
    private var canReset: Bool {
        resetCodeSent && resetCode.trimmingCharacters(in: .whitespaces).count >= 4 && resetNewPassword.count >= 4
    }
    private var canSendReg: Bool {
        reachable && regAccount.trimmingCharacters(in: .whitespaces).contains("@")
    }
    private var canRegister: Bool {
        regCodeSent && regCode.trimmingCharacters(in: .whitespaces).count >= 4 && regPassword.count >= 4
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
            .dismissKeyboardOnTap()
        }
        .onAppear { host = serverHost; portText = String(serverPort) }
        .sheet(isPresented: $showSetPassword) { setPasswordSheet }
        .sheet(isPresented: $showReset) { resetSheet }
        .sheet(isPresented: $showRegister) { registerSheet }
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("中转服务器(电脑的局域网 / Tailscale IP)")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSec)
            HStack(spacing: 10) {
                field($host, prompt: "IP,如 100.84.170.113", keyboard: .URL, width: nil, secure: false)
                    .onChange(of: host) { _, _ in reachable = false; serverMsg = nil }
                field($portText, prompt: "端口", keyboard: .numberPad, width: 78, secure: false)
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

    private var loginCard: some View {
        VStack(spacing: 14) {
            if loginStep == .email {
                Text("登录").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
                field($account, prompt: "邮箱", keyboard: .emailAddress, width: nil, secure: false)
                    .textContentType(.username)
                Button {
                    errorMessage = nil
                    withAnimation { loginStep = .password }
                } label: { primaryLabel("下一步") }
                .buttonStyle(.plain).disabled(!reachable || !isEmail(account))

                if !reachable {
                    Text("请先在上方测试连接到服务器")
                        .font(.system(size: 12)).foregroundStyle(Theme.textTer)
                }

                HStack {
                    Rectangle().fill(Theme.stroke).frame(height: 1)
                    Text("首次使用").font(.system(size: 12)).foregroundStyle(Theme.textTer)
                    Rectangle().fill(Theme.stroke).frame(height: 1)
                }
                // 邮箱验证码注册(主路径,国内 VPS 可用)
                Button {
                    regAccount = account.trimmingCharacters(in: .whitespaces)
                    regCode = ""; regPassword = ""; regInfo = nil; regError = nil
                    regCodeSent = false; regStep = .email
                    showRegister = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "envelope.fill").font(.system(size: 16))
                        Text("用邮箱注册").font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(reachable ? Theme.text : Theme.textTer)
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(Theme.cardHi)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain).disabled(loading || !reachable)
                // Google 注册(次路径,需服务器能访问 Google)
                Button(action: signInGoogle) {
                    HStack(spacing: 6) {
                        Image(systemName: "g.circle.fill").font(.system(size: 15))
                        Text("或用 Google 注册").font(.system(size: 13))
                    }
                    .foregroundStyle(reachable ? Theme.textSec : Theme.textTer)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.plain).disabled(loading || !reachable)
                Text("用邮箱验证码创建账号;Google 注册需服务器能访问 Google(国内服务器不可用)")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTer)
                    .multilineTextAlignment(.center)
            } else {
                // 密码步:顶部显示邮箱,可点返回改邮箱
                accountHeader(account) {
                    withAnimation { loginStep = .email }
                    password = ""; errorMessage = nil
                }
                field($password, prompt: "密码", keyboard: .default, width: nil, secure: true)
                Button(action: doLogin) { primaryLabel("登录", loading: loading) }
                    .buttonStyle(.plain).disabled(!canLogin || loading)
                Button {
                    resetAccount = account.trimmingCharacters(in: .whitespaces)
                    resetCode = ""; resetNewPassword = ""; resetInfo = nil; resetError = nil
                    resetCodeSent = false; resetStep = .email
                    showReset = true
                } label: {
                    Text("忘记密码?").font(.system(size: 13)).foregroundStyle(Theme.blue)
                }
                .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(16).cardStyle()
    }

    /// 主操作按钮的统一样式(蓝底白字,可带 loading)。
    private func primaryLabel(_ title: String, loading: Bool = false) -> some View {
        HStack(spacing: 8) {
            if loading { ProgressView().tint(.white) }
            Text(title).font(.system(size: 16, weight: .semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity).padding(.vertical, 13)
        .background(Theme.blueBtn)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// 分步流程顶部的「‹ 邮箱」可点返回行。
    private func accountHeader(_ email: String, onBack: @escaping () -> Void) -> some View {
        Button(action: onBack) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                Text(email).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Spacer()
                Text("更改").font(.system(size: 12)).foregroundStyle(Theme.blue)
            }
            .foregroundStyle(Theme.textSec)
        }
        .buttonStyle(.plain)
    }

    private var setPasswordSheet: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text("设置密码").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                Text("账号 \(setPwAccount) 验证成功。设置一个密码,以后用邮箱密码登录(不再需要 Google)。")
                    .font(.system(size: 14)).foregroundStyle(Theme.textSec)
                field($newPassword, prompt: "新密码(至少 4 位)", keyboard: .default, width: nil, secure: true)
                if let setPwError {
                    Text(setPwError).font(.system(size: 13)).foregroundStyle(Theme.coral)
                }
                Button(action: doSetPassword) {
                    HStack(spacing: 8) {
                        if loading { ProgressView().tint(.white) }
                        Text("设置密码并进入").font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(newPassword.count >= 4 ? Theme.blueBtn : Theme.cardHi)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain).disabled(newPassword.count < 4 || loading)
                Spacer()
            }
            .padding(24)
        }
        .interactiveDismissDisabled(true)
    }

    private var registerSheet: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("邮箱注册").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)

                    switch regStep {
                    case .email:
                        Text("输入邮箱,我们会发送验证码。不依赖 Google。")
                            .font(.system(size: 14)).foregroundStyle(Theme.textSec)
                        field($regAccount, prompt: "邮箱", keyboard: .emailAddress, width: nil, secure: false)
                            .textContentType(.username)
                        Button(action: sendRegCode) { primaryLabel(regSending ? "发送中…" : "发送验证码", loading: regSending) }
                            .buttonStyle(.plain).disabled(!canSendReg || regSending)
                    case .code:
                        accountHeader(regAccount) { withAnimation { regStep = .email }; regCode = ""; regError = nil }
                        Text("验证码已发到 \(regAccount),请查收(可能在垃圾箱)。")
                            .font(.system(size: 13)).foregroundStyle(Theme.textSec)
                        field($regCode, prompt: "6 位验证码", keyboard: .numberPad, width: nil, secure: false)
                        Button { regError = nil; withAnimation { regStep = .password } } label: { primaryLabel("下一步") }
                            .buttonStyle(.plain).disabled(regCode.trimmingCharacters(in: .whitespaces).count < 4)
                        Button(action: sendRegCode) {
                            Text(regSending ? "发送中…" : "重新发送验证码").font(.system(size: 13)).foregroundStyle(Theme.blue)
                        }
                        .buttonStyle(.plain).disabled(regSending).frame(maxWidth: .infinity)
                    case .password:
                        accountHeader(regAccount) { withAnimation { regStep = .code }; regError = nil }
                        Text("设置登录密码,完成注册并进入。")
                            .font(.system(size: 14)).foregroundStyle(Theme.textSec)
                        field($regPassword, prompt: "设置密码(至少 4 位)", keyboard: .default, width: nil, secure: true)
                        Button(action: doRegister) { primaryLabel("注册并登录", loading: loading) }
                            .buttonStyle(.plain).disabled(regPassword.count < 4 || loading)
                    }

                    if let regInfo {
                        Text(regInfo).font(.system(size: 13)).foregroundStyle(Theme.green)
                    }
                    if let regError {
                        Text(regError).font(.system(size: 13)).foregroundStyle(Theme.coral)
                    }
                    Button("取消") { showRegister = false }
                        .font(.system(size: 14)).foregroundStyle(Theme.textSec).frame(maxWidth: .infinity)
                    Spacer(minLength: 8)
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .presentationDetents([.medium, .large])
    }

    private var resetSheet: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("重置密码").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)

                    switch resetStep {
                    case .email:
                        Text("输入注册邮箱,我们会把验证码发到该邮箱。")
                            .font(.system(size: 14)).foregroundStyle(Theme.textSec)
                        field($resetAccount, prompt: "邮箱", keyboard: .emailAddress, width: nil, secure: false)
                            .textContentType(.username)
                        Button(action: sendResetCode) { primaryLabel(resetSending ? "发送中…" : "发送验证码", loading: resetSending) }
                            .buttonStyle(.plain).disabled(!canSendReset || resetSending)
                    case .code:
                        accountHeader(resetAccount) { withAnimation { resetStep = .email }; resetCode = ""; resetError = nil }
                        Text("验证码已发到 \(resetAccount),请查收(可能在垃圾箱)。")
                            .font(.system(size: 13)).foregroundStyle(Theme.textSec)
                        field($resetCode, prompt: "6 位验证码", keyboard: .numberPad, width: nil, secure: false)
                        Button { resetError = nil; withAnimation { resetStep = .password } } label: { primaryLabel("下一步") }
                            .buttonStyle(.plain).disabled(resetCode.trimmingCharacters(in: .whitespaces).count < 4)
                        Button(action: sendResetCode) {
                            Text(resetSending ? "发送中…" : "重新发送验证码").font(.system(size: 13)).foregroundStyle(Theme.blue)
                        }
                        .buttonStyle(.plain).disabled(resetSending).frame(maxWidth: .infinity)
                    case .password:
                        accountHeader(resetAccount) { withAnimation { resetStep = .code }; resetError = nil }
                        Text("设置新密码,完成重置。")
                            .font(.system(size: 14)).foregroundStyle(Theme.textSec)
                        field($resetNewPassword, prompt: "新密码(至少 4 位)", keyboard: .default, width: nil, secure: true)
                        Button(action: doResetPassword) { primaryLabel("重置密码", loading: loading) }
                            .buttonStyle(.plain).disabled(resetNewPassword.count < 4 || loading)
                    }

                    if let resetInfo {
                        Text(resetInfo).font(.system(size: 13)).foregroundStyle(Theme.green)
                    }
                    if let resetError {
                        Text(resetError).font(.system(size: 13)).foregroundStyle(Theme.coral)
                    }
                    Button("取消") { showReset = false }
                        .font(.system(size: 14)).foregroundStyle(Theme.textSec).frame(maxWidth: .infinity)
                    Spacer(minLength: 8)
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func field(_ text: Binding<String>, prompt: String, keyboard: UIKeyboardType, width: CGFloat?, secure: Bool) -> some View {
        Group {
            if secure {
                SecureField("", text: text, prompt: Text(prompt).foregroundColor(Theme.textTer))
            } else {
                TextField("", text: text, prompt: Text(prompt).foregroundColor(Theme.textTer))
                    .keyboardType(keyboard)
            }
        }
        .font(.system(size: 15, design: keyboard == .URL ? .monospaced : .default))
        .foregroundStyle(Theme.text)
        .autocorrectionDisabled().textInputAutocapitalization(.never)
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

    private func doLogin() {
        errorMessage = nil; loading = true
        let acc = account.trimmingCharacters(in: .whitespaces), pwd = password
        Task {
            do {
                let r = try await AuthAPI.login(account: acc, password: pwd)
                appState.login(account: r.account, token: r.token)
            } catch { errorMessage = error.localizedDescription }
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
                    if r.hasPassword == "true" {
                        appState.login(account: r.account, token: r.token)   // 已设过密码,直接进
                    } else {
                        // 首次:引导设密码
                        setPwToken = r.token
                        setPwAccount = r.account
                        newPassword = ""; setPwError = nil
                        showSetPassword = true
                    }
                } catch { errorMessage = error.localizedDescription }
                loading = false
            }
        }
    }

    private func sendRegCode() {
        regError = nil; regInfo = nil; regSending = true
        let acc = regAccount.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await AuthAPI.registerCode(account: acc)
                regInfo = nil
                withAnimation { if regStep == .email { regStep = .code } }
            } catch { regError = error.localizedDescription }
            regSending = false
        }
    }

    private func doRegister() {
        regError = nil; regInfo = nil; loading = true
        let acc = regAccount.trimmingCharacters(in: .whitespaces)
        let code = regCode.trimmingCharacters(in: .whitespaces)
        let pwd = regPassword
        Task {
            do {
                let r = try await AuthAPI.register(account: acc, code: code, password: pwd)
                showRegister = false
                appState.login(account: r.account, token: r.token)   // 注册成功直接进
            } catch { regError = error.localizedDescription }
            loading = false
        }
    }

    private func sendResetCode() {
        resetError = nil; resetInfo = nil; resetSending = true
        let acc = resetAccount.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await AuthAPI.forgotPassword(account: acc)
                resetInfo = nil
                withAnimation { if resetStep == .email { resetStep = .code } }
            } catch { resetError = error.localizedDescription }
            resetSending = false
        }
    }

    private func doResetPassword() {
        resetError = nil; resetInfo = nil; loading = true
        let acc = resetAccount.trimmingCharacters(in: .whitespaces)
        let code = resetCode.trimmingCharacters(in: .whitespaces)
        let pwd = resetNewPassword
        Task {
            do {
                try await AuthAPI.resetPassword(account: acc, code: code, password: pwd)
                showReset = false
                account = acc; password = ""; loginStep = .password   // 回登录页密码步,预填邮箱
                errorMessage = "密码已重置,请用新密码登录"
            } catch { resetError = error.localizedDescription }
            loading = false
        }
    }

    private func doSetPassword() {
        guard let token = setPwToken else { return }
        setPwError = nil; loading = true
        let pwd = newPassword
        Task {
            do {
                try await AuthAPI.setPassword(token: token, password: pwd)
                showSetPassword = false
                appState.login(account: setPwAccount, token: token)   // 设好即登录
            } catch { setPwError = error.localizedDescription }
            loading = false
        }
    }
}
