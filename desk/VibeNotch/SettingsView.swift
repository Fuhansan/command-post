import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let relayAgent: RelayAgent?
    @StateObject private var pairing = PairingController()
    /// 中转服务器地址(本机=127.0.0.1;公网 VPS=填其公网 IP)。
    @State private var serverHost: String = AgentServer.host
    @State private var serverSaved = false
    /// Re-resolved on each render so language changes apply live without
    /// needing to close and reopen the window.
    private var locale: L10n.Locale { L10n.resolved(from: settings.language) }

    var body: some View {
        Form {
            // 账号:由手机授权配对(手机先 Google 登录,再输入这里显示的配对码)
            Section("账号(AI Coding Remote)") {
                accountRow
                if let relayAgent {
                    AgentConnStateRow(agent: relayAgent)
                }
            }

            // 中转服务器地址:服务器在本机时填 127.0.0.1;搬到公网 VPS 后填 VPS 公网 IP。
            // WS 走 8090、HTTP(登录/配对/图片)走 8080,端口固定,只填地址。
            Section("中转服务器") {
                TextField("服务器 IP / 域名", text: $serverHost)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: serverHost) { _ in serverSaved = false }
                HStack {
                    Button(serverSaved ? "✓ 已保存,正在重连" : "保存并重连") {
                        AgentServer.host = serverHost.trimmingCharacters(in: .whitespacesAndNewlines)
                        serverSaved = true   // 地址变更会经通知触发 RelayAgent 按新地址重连
                    }
                    .disabled(serverHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Text("WS 8090 / HTTP 8080").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(L10n.t(.settingsSectionGeneral, locale: locale)) {
                Picker(L10n.t(.settingsLanguage, locale: locale), selection: $settings.language) {
                    Text(L10n.t(.settingsLangSystem,  locale: locale)).tag(AppSettings.Language.system)
                    Text(L10n.t(.settingsLangEnglish, locale: locale)).tag(AppSettings.Language.english)
                    Text(L10n.t(.settingsLangChinese, locale: locale)).tag(AppSettings.Language.chinese)
                }
                .pickerStyle(.menu)

                Toggle(L10n.t(.settingsLaunchAtLogin, locale: locale), isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))

                Toggle(L10n.t(.settingsMuteSounds, locale: locale), isOn: $settings.muted)
            }

            // 手机「新建会话」用的默认工作目录 + 代理
            Section("新建会话") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("默认工作目录(如 ~/Projects)", text: $settings.defaultWorkdir)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Text("手机点「+」新建会话时,新终端先 cd 进此目录再运行命令。留空则用 ~ 。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("代理命令(大陆用户跑 claude 需要)", text: $settings.launchProxy, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1...3)
                    HStack(spacing: 6) {
                        Text("命令前自动执行,设代理后 claude 才能连上 Anthropic。留空则不设。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("填入默认") {
                            settings.launchProxy = "export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890 all_proxy=socks5://127.0.0.1:7890"
                        }
                        .font(.system(size: 11))
                    }
                }
            }

            Section {
                Text(L10n.t(.settingsConfigPath, locale: locale))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 360)
        .onDisappear { pairing.cancel() }
    }

    @ViewBuilder
    private var accountRow: some View {
        switch pairing.state {
        case .waiting(let code):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(code)
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .kerning(4)
                        .textSelection(.enabled)
                    ProgressView().controlSize(.small)
                    Button("取消") { pairing.cancel() }
                }
                Text("在手机 App「设备」页输入此配对码(10 分钟内有效)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .fetching:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在获取配对码…") }
        default:
            HStack {
                if let account = AgentCredentials.account, !account.isEmpty {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text(account).font(.system(size: 13, design: .monospaced))
                    Spacer()
                    Button("退出登录") { AgentCredentials.clear() }
                    Button("重新配对") { pairing.start() }
                } else {
                    Image(systemName: "iphone.radiowaves.left.and.right").foregroundStyle(.secondary)
                    Text("未配对 · 当前账号: \(RelayAgent.account)")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("配对手机") { pairing.start() }
                }
            }
            if case .failed(let msg) = pairing.state {
                Text(msg).font(.system(size: 11)).foregroundStyle(.red)
            } else if case .done(let account) = pairing.state {
                Text("✓ 配对成功: \(account),已以新账号重连")
                    .font(.system(size: 11)).foregroundStyle(.green)
            }
        }
    }
}


/// 与中转服务器的实时连接状态行(随 RelayAgent.connState 自动刷新)。
struct AgentConnStateRow: View {
    @ObservedObject var agent: RelayAgent

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch agent.connState {
        case .online:           return .green
        case .connecting:       return .yellow
        case .suspendedByPhone: return .orange
        case .rejected:         return .red
        case .unpaired, .offline: return .gray
        }
    }

    private var text: String {
        switch agent.connState {
        case .online:           return "已连接中转服务器"
        case .connecting:       return "连接中…"
        case .suspendedByPhone: return "已被手机端断开 —— 在手机「设备」页点「重连」恢复"
        case .rejected(let c):  return "被服务器拒绝(\(c)),请重新配对"
        case .unpaired:         return "未配对,离线"
        case .offline:          return "已断开,自动重连中…"
        }
    }
}
