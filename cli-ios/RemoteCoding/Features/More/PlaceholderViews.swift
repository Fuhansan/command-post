import SwiftUI

/// 设备 / 设置(占位,后续展开)。
struct DevicesView: View {
    @EnvironmentObject private var appState: AppState
    var body: some View {
        placeholder(icon: "desktopcomputer", title: "设备", subtitle: "管理已连接的电脑代理")
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var relay: RelayClient
    @AppStorage(RelayClient.urlDefaultsKey) private var serverURL: String = RelayClient.defaultURLString
    @State private var draft: String = ""
    @State private var savedFlash = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("设置").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)

                    // 服务器地址
                    VStack(alignment: .leading, spacing: 10) {
                        Text("中转服务器").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textSec)
                        TextField("", text: $draft,
                                  prompt: Text("如 192.168.1.5 或 wss://example.com")
                                      .foregroundColor(Theme.textTer))
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundStyle(Theme.text)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(Theme.field)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Text("实际连接: \(RelayClient.normalizeURL(draft.isEmpty ? serverURL : draft))")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textTer)
                            .lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 10) {
                            Button {
                                serverURL = RelayClient.normalizeURL(draft.isEmpty ? serverURL : draft)
                                draft = serverURL
                                relay.reconnectToCurrentServer()
                                savedFlash = true
                                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); savedFlash = false }
                            } label: {
                                Text(savedFlash ? "✓ 已保存并重连" : "保存并重连")
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 16).padding(.vertical, 10)
                                    .background(savedFlash ? Theme.green : Theme.blueBtn)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            connectionBadge
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
        .onAppear { draft = serverURL }
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
