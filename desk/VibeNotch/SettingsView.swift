import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var pairing = PairingController()
    /// Re-resolved on each render so language changes apply live without
    /// needing to close and reopen the window.
    private var locale: L10n.Locale { L10n.resolved(from: settings.language) }

    var body: some View {
        Form {
            // 账号:由手机授权配对(手机先 Google 登录,再输入这里显示的配对码)
            Section("账号(AI Coding Remote)") {
                accountRow
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
