import SwiftUI

/// 会话状态字符串(来自协议 body.session.status)→ 展示标签/颜色。
enum SessionStatusUI {
    static func label(_ s: String) -> String {
        switch s {
        case "idle":      return "空闲"
        case "working":   return "运行中"
        case "waiting":   return "等待确认"   // 真有审批/选择待你处理(needsAction)
        case "suspended": return "会话挂起"   // 空闲等你输入,无待办 —— 不催你
        case "done":      return "完成"
        case "ended":     return "已结束"
        default:          return s
        }
    }
    static func color(_ s: String) -> Color {
        switch s {
        case "working":   return Theme.blue
        case "waiting":   return Theme.gold    // 黄:需要你处理
        case "suspended": return Theme.textSec // 灰:仅挂起,不需处理
        case "done":      return Theme.green
        case "ended":     return Theme.textTer
        default:          return Theme.textSec
        }
    }
}

/// 屏 1 —— 任务列表(首页)。每个 claude 终端会话 = 一个任务(来自服务器,非模拟数据)。
struct TasksView: View {
    @EnvironmentObject private var relay: RelayClient

    /// 手动会话(用户自己敲的 claude):平铺首页,带「锁屏不可控」标签。
    private var manualSessions: [RelaySession] { relay.sessions.filter { $0.isManual } }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        header
                        if relay.projects.isEmpty && manualSessions.isEmpty {
                            emptyState
                        } else {
                            if !relay.projects.isEmpty {
                                sectionTitle("项目", count: relay.projects.count)
                                ForEach(relay.projects) { proj in
                                    NavigationLink(value: ProjectRoute(workdir: proj.workdir)) {
                                        ProjectRow(project: proj, sessions: relay.sessions)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            if !manualSessions.isEmpty {
                                sectionTitle("手动会话", count: manualSessions.count)
                                ForEach(manualSessions) { s in
                                    NavigationLink(value: s.id) { SessionCard(session: s) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .refreshable {
                    // 下拉刷新:强制重连重新拉取(连接半死/代理干扰时手动恢复)
                    relay.reconnectToCurrentServer()
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
            }
            .navigationDestination(for: String.self) { sid in
                TaskDetailView(sessionId: sid)
            }
            .navigationDestination(for: ProjectRoute.self) { route in
                ProjectSessionsView(workdir: route.workdir)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func sectionTitle(_ t: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(t).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
            Text("\(count)").font(.system(size: 13)).foregroundStyle(Theme.textSec)
            Spacer()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.blueBtn.gradient)
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: "chevron.right").font(.system(size: 18, weight: .bold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Coding Remote").font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.text)
                connectionLine
            }
            Spacer()
        }
    }

    private var connectionLine: some View {
        HStack(spacing: 5) {
            Circle().fill(statusColor).frame(width: 6, height: 6)
            Text(statusText).font(.system(size: 13)).foregroundStyle(Theme.textSec)
        }
    }

    private var statusColor: Color {
        switch relay.connection {
        case .connected: return Theme.green
        case .connecting, .reconnecting: return Theme.gold
        default: return Theme.textTer
        }
    }
    private var statusText: String {
        let agentOnline = relay.agents.contains { $0.online }
        switch relay.connection {
        case .connected:    return agentOnline ? "已连接 · 电脑在线" : "已连接中转 · 等待电脑"
        case .connecting:   return "连接中…"
        case .reconnecting: return "重连中…"
        case .failed:       return "连接失败"
        case .disconnected: return "未连接"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 40)).foregroundStyle(Theme.textTer)
            Text("还没有项目或会话")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            Text("在电脑 VibeNotch「打开项目」,或在终端运行 Claude Code,就会出现在这里")
                .font(.system(size: 13)).foregroundStyle(Theme.textSec)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 48)
    }
}

/// 把 Mac 绝对路径里的 /Users/<name>/ 缩成 ~/。
func shortMacPath(_ p: String) -> String {
    p.replacingOccurrences(of: #"^/Users/[^/]+/"#, with: "~/", options: .regularExpression)
}

/// 任务行(一个 claude 会话):项目名 + 终端 + 目录。
struct SessionCard: View {
    let session: RelaySession
    private var hasTerminal: Bool { !session.terminal.isEmpty && session.terminal != "?" }
    private var hasCwd: Bool { !session.cwd.isEmpty && session.cwd != "?" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Avatar(letter: String(session.title.prefix(1)), color: Theme.purple)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                    HStack(spacing: 6) {
                        if hasTerminal {
                            Text(session.terminal).font(.system(size: 12)).foregroundStyle(Theme.textSec)
                            Text("·").font(.system(size: 12)).foregroundStyle(Theme.textTer)
                        }
                        Text(SessionStatusUI.label(session.status))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SessionStatusUI.color(session.status))
                    }
                }
                Spacer()
                if session.needsAction {
                    Text("需处理")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.coral).clipShape(Capsule())
                }
            }
            if session.isManual {
                // 手动会话:用户自己敲的 claude,反控走 GUI 模拟,电脑锁屏后无法操作。
                HStack(spacing: 5) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 10))
                    Text("手动 · 锁屏不可控").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.gold)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.gold.opacity(0.15)).clipShape(Capsule())
            }
            if hasCwd {
                HStack(spacing: 5) {
                    Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Theme.textTer)
                    Text(shortMacPath(session.cwd))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSec)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            if !session.subtitle.isEmpty {
                Text(session.subtitle)
                    .font(.system(size: 14)).foregroundStyle(Theme.textSec)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .cardStyle(stroke: session.needsAction ? Theme.coral.opacity(0.7) : Theme.stroke)
    }
}
