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
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "gearshape").font(.system(size: 40)).foregroundStyle(Theme.textTer)
                Text("设置").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
                Button("退出登录") { appState.logout() }
                    .foregroundStyle(Theme.coral)
                    .padding(.top, 8)
            }
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
