import Foundation
import SwiftUI

/// 客户端版本检测:启动时 + 设置页手动触发。
/// 服务器 data/app-version.json 是唯一事实源:
///   latest > 当前 → 弹更新公告(每个版本只弹一次,可稍后)
///   minimum > 当前 → 强制更新,全屏拦截直到升级
@MainActor
final class UpdateChecker: ObservableObject {
    struct VersionInfo: Decodable, Equatable {
        let latest: String
        let minimum: String
        let notes: String
        let url: String
    }

    enum Status: Equatable {
        case unknown
        case upToDate
        case updateAvailable(VersionInfo)   // 可选更新(公告)
        case forceUpdate(VersionInfo)       // 必须更新才能用
    }

    @Published private(set) var status: Status = .unknown
    /// 本次是否应弹公告(同一版本看过/点过稍后就不再弹;强更不受此限制)。
    @Published var showAnnouncement = false

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
    static var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// 启动时静默检查;手动检查时 manual=true(无新版本也要给反馈)。
    func check(manual: Bool = false) async {
        guard let url = URL(string: "http://\(RelayClient.savedHost):8080/api/app/version") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: URL(string: url.absoluteString)!)
            let info = try JSONDecoder().decode(VersionInfo.self, from: data)
            apply(info, manual: manual)
        } catch {
            if manual { status = .unknown }
        }
    }

    private func apply(_ info: VersionInfo, manual: Bool) {
        let cur = Self.currentVersion
        if Self.older(cur, than: info.minimum) {
            status = .forceUpdate(info)
            return
        }
        if Self.older(cur, than: info.latest) {
            status = .updateAvailable(info)
            let seenKey = "announce.seen.\(info.latest)"
            if manual || !UserDefaults.standard.bool(forKey: seenKey) {
                UserDefaults.standard.set(true, forKey: seenKey)
                showAnnouncement = true
            }
        } else {
            status = .upToDate
        }
    }

    /// 语义化版本比较:a < b ?
    static func older(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}

/// 强制更新全屏拦截页:低于最低可用版本时替换整个界面。
struct ForceUpdateView: View {
    let info: UpdateChecker.VersionInfo

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 56)).foregroundStyle(Theme.blue)
                Text("需要更新").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                Text("当前版本 \(UpdateChecker.currentVersion) 已停用,请升级到 \(info.latest) 后继续使用")
                    .font(.system(size: 14)).foregroundStyle(Theme.textSec)
                    .multilineTextAlignment(.center)
                if !info.notes.isEmpty {
                    ScrollView {
                        Text(info.notes)
                            .font(.system(size: 13)).foregroundStyle(Theme.textSec)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                    .padding(12).cardStyle()
                }
                updateButton(info: info)
            }
            .padding(28)
        }
    }
}

/// 更新公告弹层(可选更新):重大功能说明 + 稍后/去更新。
struct AnnouncementSheet: View {
    let info: UpdateChecker.VersionInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.system(size: 22)).foregroundStyle(Theme.gold)
                    Text("新版本 \(info.latest)").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                }
                ScrollView {
                    Text(info.notes.isEmpty ? "修复与体验优化。" : info.notes)
                        .font(.system(size: 15)).foregroundStyle(Theme.text).lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                updateButton(info: info)
                Button("稍后再说") { dismiss() }
                    .font(.system(size: 14)).foregroundStyle(Theme.textSec)
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
        }
        .presentationDetents([.medium, .large])
    }
}

/// 「去更新」按钮:有 URL 则跳转(TestFlight 等),无则提示连线安装。
@MainActor @ViewBuilder
func updateButton(info: UpdateChecker.VersionInfo) -> some View {
    if let u = URL(string: info.url), !info.url.isEmpty {
        Link(destination: u) {
            Text("去更新")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(Theme.blueBtn).clipShape(RoundedRectangle(cornerRadius: 13))
        }
    } else {
        Text("请将手机连接电脑,用 Xcode 安装最新构建")
            .font(.system(size: 13)).foregroundStyle(Theme.gold)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(Theme.gold.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
