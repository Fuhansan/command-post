import SwiftUI

/// 项目导航路由(与「会话 id = String」区分,避免 NavigationStack 目标类型冲突)。
struct ProjectRoute: Hashable { let workdir: String }

/// 会话导航(项目内点历史卡片 → resume 后程序化进入用)。
struct SessionRoute: Hashable, Identifiable { var id: String { sid }; let sid: String }

/// 首页「项目」一行:项目名 + 目录 + 会话数 / 待处理。
struct ProjectRow: View {
    let project: ProjectInfo
    let sessions: [RelaySession]

    // 调用方已按「最长前缀」筛好该项目的会话(console + 折叠进来的手动会话)。
    private var inProject: [RelaySession] { sessions }
    private var needsAction: Bool { inProject.contains { $0.needsAction } }

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
                Label("\(inProject.count) 进行中", systemImage: "bubble.left.and.bubble.right")
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

/// 屏:项目内会话列表。统一卡片:进行中的会话 + 可恢复的历史会话。点卡片即进入(历史先 resume 再进)。
struct ProjectSessionsView: View {
    let workdir: String
    @EnvironmentObject private var relay: RelayClient
    @Environment(\.dismiss) private var dismiss
    @State private var awaitingSids: Set<String>? = nil   // 开会话时快照已有 sid,等新会话出现再进入
    @State private var route: SessionRoute? = nil

    private var project: ProjectInfo? { relay.projects.first { $0.workdir == workdir } }
    private var name: String { project?.name ?? (workdir as NSString).lastPathComponent }

    /// 进行中的会话(归属本项目:cwd 等于或在 workdir 子目录下,最长前缀匹配)。
    private var active: [RelaySession] {
        relay.sessions.filter { relay.project(forCwd: $0.cwd)?.workdir == workdir }
    }
    /// 可恢复的历史(排除当前已在跑的 claude 会话,避免和「进行中」重复)。
    private var dormant: [ProjectHistory] {
        let liveIds = Set(active.map { $0.agentSessionId }.filter { !$0.isEmpty })
        return (project?.history ?? []).filter { !liveIds.contains($0.id) }
    }
    /// onChange 监听键:进行中会话集合变化时用它判断新会话是否到位。
    private var activeKey: String { active.map { $0.id }.sorted().joined(separator: ",") }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    navBar
                    if awaitingSids != nil {
                        Label("正在打开会话…", systemImage: "hourglass")
                            .font(.system(size: 13)).foregroundStyle(Theme.textSec)
                    }
                    if active.isEmpty && dormant.isEmpty {
                        Text("这个项目还没有会话。点右上角「+」开一个全新会话。")
                            .font(.system(size: 13)).foregroundStyle(Theme.textSec)
                            .padding(.vertical, 24).frame(maxWidth: .infinity)
                    }
                    // 进行中:点开即进对话
                    ForEach(active) { s in
                        NavigationLink(value: s.id) { SessionCard(session: s) }.buttonStyle(.plain)
                    }
                    // 历史:点卡片 → resume → 程序化进入
                    ForEach(dormant) { h in
                        Button { openHistory(h) } label: { HistoryCard(history: h) }.buttonStyle(.plain)
                    }
                    Spacer(minLength: 8)
                }
                .padding(16)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        // 历史 resume / 全新:等新会话出现后程序化进入。
        .navigationDestination(item: $route) { TaskDetailView(sessionId: $0.sid) }
        .onChange(of: activeKey) { _, _ in
            guard let snap = awaitingSids, let fresh = active.first(where: { !snap.contains($0.id) }) else { return }
            awaitingSids = nil
            route = SessionRoute(sid: fresh.id)
        }
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
            Button { startFresh() } label: {
                Image(systemName: "plus").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(Theme.blueBtn).clipShape(Circle())
            }
        }
    }

    // MARK: - 动作

    private func startFresh() {
        awaitingSids = Set(active.map { $0.id })
        relay.consoleNewSession(workdir: workdir)
    }
    private func openHistory(_ h: ProjectHistory) {
        awaitingSids = Set(active.map { $0.id })
        relay.consoleResume(workdir: workdir, historyId: h.id)
    }
}

/// 历史会话卡片:和普通任务卡片同款框样式,只用一个「可恢复」标签标识类型 + 展示 id。
struct HistoryCard: View {
    let history: ProjectHistory
    var body: some View {
        HStack(spacing: 12) {
            Avatar(letter: String(history.label.prefix(1)), color: Theme.textTer)
            VStack(alignment: .leading, spacing: 3) {
                Text(history.label).font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text).lineLimit(1)
                Text("id \(history.id.prefix(8))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textTer)
            }
            Spacer()
            Text("可恢复").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.gold)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.gold.opacity(0.15)).clipShape(Capsule())
        }
        .padding(16)
        .cardStyle(stroke: Theme.stroke)
    }
}
