import SwiftUI

/// 项目导航路由(与「会话 id = String」区分,避免 NavigationStack 目标类型冲突)。
struct ProjectRoute: Hashable { let workdir: String }

/// 首页「项目区」一行:项目名 + 目录 + 进行中会话数 / 待处理。
struct ProjectRow: View {
    let project: ProjectInfo
    let sessions: [RelaySession]

    private var active: [RelaySession] {
        sessions.filter { $0.source == "console" && $0.cwd == project.workdir }
    }
    private var needsAction: Bool { active.contains { $0.needsAction } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.blueBtn.gradient)
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "folder.fill").font(.system(size: 18)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(shortMacPath(project.workdir))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSec)
                        .lineLimit(1).truncationMode(.head)
                }
                Spacer()
                if needsAction {
                    Text("需处理").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.coral).clipShape(Capsule())
                }
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textTer)
            }
            HStack(spacing: 8) {
                Label("\(active.count) 个会话", systemImage: "bubble.left.and.bubble.right")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSec)
                if !project.history.isEmpty {
                    Text("·").foregroundStyle(Theme.textTer)
                    Text("\(project.history.count) 条历史").font(.system(size: 12)).foregroundStyle(Theme.textTer)
                }
            }
        }
        .padding(16)
        .cardStyle(stroke: needsAction ? Theme.coral.opacity(0.7) : Theme.stroke)
    }
}

/// 屏:项目内会话列表。上=进行中的会话(点开进对话);下=新建(继续最近 / 全新 / 从历史恢复)。
struct ProjectSessionsView: View {
    let workdir: String
    @EnvironmentObject private var relay: RelayClient
    @Environment(\.dismiss) private var dismiss
    @State private var requested = false   // 已请求开会话 → 给个反馈

    private var project: ProjectInfo? { relay.projects.first { $0.workdir == workdir } }
    private var active: [RelaySession] {
        relay.sessions.filter { $0.source == "console" && $0.cwd == workdir }
    }
    private var name: String { project?.name ?? (workdir as NSString).lastPathComponent }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    navBar
                    if !active.isEmpty {
                        sectionTitle("进行中")
                        ForEach(active) { s in
                            NavigationLink(value: s.id) { SessionCard(session: s) }.buttonStyle(.plain)
                        }
                    }
                    sectionTitle("新建会话")
                    if requested {
                        Text("已请求,新会话会出现在上面「进行中」。")
                            .font(.system(size: 13)).foregroundStyle(Theme.green)
                    }
                    HStack(spacing: 10) {
                        startButton("继续最近", icon: "clock.arrow.circlepath", primary: true) {
                            relay.consoleContinue(workdir: workdir); requested = true
                        }
                        startButton("全新会话", icon: "plus.bubble", primary: false) {
                            relay.consoleNewSession(workdir: workdir); requested = true
                        }
                    }
                    if let history = project?.history, !history.isEmpty {
                        sectionTitle("从历史恢复")
                        ForEach(history) { h in
                            Button {
                                relay.consoleResume(workdir: workdir, historyId: h.id); requested = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.uturn.backward").font(.system(size: 12))
                                    Text(h.label).font(.system(size: 13)).lineLimit(1)
                                    Spacer()
                                }
                                .foregroundStyle(Theme.text)
                                .padding(.vertical, 12).padding(.horizontal, 14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .cardStyle(stroke: Theme.stroke)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer(minLength: 12)
                }
                .padding(16)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
    }

    private var navBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
                Text(shortMacPath(workdir)).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSec).lineLimit(1).truncationMode(.head)
            }
            Spacer()
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSec)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func startButton(_ title: String, icon: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 14))
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.vertical, 12).frame(maxWidth: .infinity)
            .background(primary ? Theme.blueBtn : Theme.purple)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
