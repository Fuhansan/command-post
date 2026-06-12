import SwiftUI

/// 设备页:在线电脑列表 + 配对新电脑(输入 VibeNotch 设置里显示的配对码)。
struct DevicesView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var relay: RelayClient
    @State private var code = ""
    @State private var claiming = false
    @State private var result: (ok: Bool, message: String)? = nil

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("设备").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)

                    // 已连接的电脑
                    VStack(alignment: .leading, spacing: 12) {
                        Text("电脑代理").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textSec)
                        if relay.agents.isEmpty {
                            Text("暂无在线电脑").font(.system(size: 14)).foregroundStyle(Theme.textTer)
                        } else {
                            ForEach(relay.agents) { agent in
                                HStack(spacing: 10) {
                                    Image(systemName: "desktopcomputer")
                                        .font(.system(size: 18))
                                        .foregroundStyle(agent.online ? Theme.green : Theme.textTer)
                                    Text(agent.name).font(.system(size: 15)).foregroundStyle(Theme.text)
                                    Spacer()
                                    Text(agent.online ? "在线" : "离线")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(agent.online ? Theme.green : Theme.textTer)
                                }
                            }
                        }
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading).cardStyle()

                    // 配对新电脑
                    VStack(alignment: .leading, spacing: 10) {
                        Text("配对新电脑").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textSec)
                        Text("在电脑上打开 VibeNotch 设置 → 点「配对手机」,把显示的 6 位码填到这里")
                            .font(.system(size: 12)).foregroundStyle(Theme.textTer)
                        HStack(spacing: 10) {
                            TextField("", text: $code,
                                      prompt: Text("6 位配对码").foregroundColor(Theme.textTer))
                                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.text)
                                .keyboardType(.numberPad)
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .background(Theme.field)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            Button {
                                claiming = true; result = nil
                                let c = code.trimmingCharacters(in: .whitespaces)
                                Task {
                                    do {
                                        try await AuthAPI.claimPair(code: c)
                                        result = (true, "✓ 配对成功,电脑将自动以你的账号上线")
                                        code = ""
                                    } catch {
                                        result = (false, error.localizedDescription)
                                    }
                                    claiming = false
                                }
                            } label: {
                                Text(claiming ? "配对中…" : "配对")
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 18).padding(.vertical, 12)
                                    .background(Theme.blueBtn)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .disabled(claiming || code.trimmingCharacters(in: .whitespaces).count != 6)
                        }
                        if let r = result {
                            Text(r.message).font(.system(size: 13))
                                .foregroundStyle(r.ok ? Theme.green : Theme.coral)
                        }
                    }
                    .padding(16).cardStyle()
                }
                .padding(16)
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var relay: RelayClient
    @AppStorage(RelayClient.hostKey) private var savedHost: String = RelayClient.defaultHost
    @AppStorage(RelayClient.portKey) private var savedPort: Int = RelayClient.defaultPort
    @State private var host: String = ""
    @State private var portText: String = ""
    @State private var savedFlash = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)? = nil

    private var port: Int { Int(portText) ?? 0 }
    private var inputValid: Bool {
        !RelayClient.sanitizeHost(host).isEmpty && (1...65535).contains(port)
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("设置").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)

                    // 中转服务器:只填 IP + 端口,地址内部拼接
                    VStack(alignment: .leading, spacing: 10) {
                        Text("中转服务器").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textSec)
                        HStack(spacing: 10) {
                            settingField($host, prompt: "IP / 主机名,如 100.64.0.5", keyboard: .URL)
                            settingField($portText, prompt: "端口", keyboard: .numberPad)
                                .frame(width: 90)
                        }
                        if let url = RelayClient.buildURL(host: host, port: port) {
                            Text("实际连接: \(url.absoluteString)")
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textTer)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        HStack(spacing: 10) {
                            // 测试连通性
                            Button {
                                testing = true; testResult = nil
                                let h = host, p = port
                                Task {
                                    let r = await RelayClient.testServer(host: h, port: p)
                                    testing = false; testResult = r
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    if testing { ProgressView().controlSize(.mini) }
                                    Text(testing ? "测试中…" : "测试连通")
                                }
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(Theme.cardHi)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .disabled(!inputValid || testing)

                            // 保存并重连
                            Button {
                                savedHost = RelayClient.sanitizeHost(host)
                                savedPort = port
                                host = savedHost
                                relay.reconnectToCurrentServer()
                                savedFlash = true
                                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); savedFlash = false }
                            } label: {
                                Text(savedFlash ? "✓ 已保存" : "保存并重连")
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                    .background(savedFlash ? Theme.green : Theme.blueBtn)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .disabled(!inputValid)

                            connectionBadge
                        }
                        if let r = testResult {
                            HStack(spacing: 5) {
                                Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: 13))
                                Text(r.message).font(.system(size: 13))
                            }
                            .foregroundStyle(r.ok ? Theme.green : Theme.coral)
                        }
                    }
                    .padding(16).cardStyle()

                    // 账号
                    VStack(alignment: .leading, spacing: 8) {
                        Text("账号").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textSec)
                        Text(appState.account)
                            .font(.system(size: 15, design: .monospaced)).foregroundStyle(Theme.text)
                        Button("退出登录") { appState.logout() }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.coral)
                            .padding(.top, 4)
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                }
                .padding(16)
            }
        }
        .onAppear { host = savedHost; portText = String(savedPort) }
    }

    private func settingField(_ text: Binding<String>, prompt: String, keyboard: UIKeyboardType) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundColor(Theme.textTer))
            .font(.system(size: 15, design: .monospaced))
            .foregroundStyle(Theme.text)
            .keyboardType(keyboard)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.field)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var connectionBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(statusText).font(.system(size: 13)).foregroundStyle(Theme.textSec)
        }
    }
    private var statusColor: Color {
        switch relay.connection {
        case .connected: return Theme.green
        case .connecting, .reconnecting: return Theme.gold
        default: return Theme.coral
        }
    }
    private var statusText: String {
        switch relay.connection {
        case .connected:    return "已连接"
        case .connecting:   return "连接中…"
        case .reconnecting: return "重连中…"
        case .failed:       return "连接失败"
        case .disconnected: return "未连接"
        }
    }
}

private func placeholder(icon: String, title: String, subtitle: String) -> some View {
    ZStack {
        Theme.bg.ignoresSafeArea()
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(Theme.textTer)
            Text(title).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(Theme.textSec)
        }
    }
}
