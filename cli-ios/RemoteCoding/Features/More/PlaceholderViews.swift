import SwiftUI


struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var relay: RelayClient
    @EnvironmentObject private var updater: UpdateChecker
    @State private var checkingUpdate = false
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
                        // 手动断开 / 重连
                        Button {
                            if relay.connection == .connected {
                                relay.manualDisconnect()
                            } else {
                                relay.reconnectToCurrentServer()
                            }
                        } label: {
                            Text(relay.connection == .connected ? "断开连接" : "重新连接")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(relay.connection == .connected ? Theme.coral : Theme.blue)
                        }
                        .padding(.top, 2)
                    }
                    .padding(16).cardStyle()

                    // 账号 + 登录设备(同账户登录的电脑;不再单独「设备」页)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("账号").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textSec)
                        Text(appState.account)
                            .font(.system(size: 15, design: .monospaced)).foregroundStyle(Theme.text)

                        Divider().overlay(Theme.stroke).padding(.vertical, 2)
                        Text("登录设备").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSec)
                        if relay.devices.isEmpty {
                            Text("暂无登录设备").font(.system(size: 13)).foregroundStyle(Theme.textTer)
                        } else {
                            ForEach(relay.devices) { d in
                                HStack(spacing: 9) {
                                    Image(systemName: d.isComputer ? "desktopcomputer" : "iphone")
                                        .font(.system(size: 15))
                                        .foregroundStyle(d.online ? Theme.green : Theme.textTer)
                                    Text(d.name).font(.system(size: 14)).foregroundStyle(Theme.text).lineLimit(1)
                                    if d.id == RelayClient.deviceId {
                                        Text("本机").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.blue)
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(Theme.blue.opacity(0.15)).clipShape(Capsule())
                                    }
                                    Spacer()
                                    Text(d.online ? "在线" : "离线")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(d.online ? Theme.green : Theme.textTer)
                                }
                            }
                        }

                        Button("退出登录") { appState.logout() }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.coral)
                            .padding(.top, 6)
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading).cardStyle()

                    // 关于 / 版本
                    VStack(alignment: .leading, spacing: 10) {
                        Text("关于").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textSec)
                        HStack {
                            Text("版本 \(UpdateChecker.currentVersion) (\(UpdateChecker.currentBuild))")
                                .font(.system(size: 15)).foregroundStyle(Theme.text)
                            Spacer()
                            Button {
                                checkingUpdate = true
                                Task {
                                    await updater.check(manual: true)
                                    checkingUpdate = false
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    if checkingUpdate { ProgressView().controlSize(.mini) }
                                    Text(checkingUpdate ? "检查中…" : "检查更新")
                                }
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.blue)
                            }
                            .disabled(checkingUpdate)
                        }
                        switch updater.status {
                        case .upToDate:
                            Label("已是最新版本", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 13)).foregroundStyle(Theme.green)
                        case .updateAvailable(let info):
                            Label("发现新版本 \(info.latest),点上方「检查更新」查看公告", systemImage: "arrow.up.circle.fill")
                                .font(.system(size: 13)).foregroundStyle(Theme.gold)
                        case .unknown, .forceUpdate:
                            EmptyView()
                        }
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
