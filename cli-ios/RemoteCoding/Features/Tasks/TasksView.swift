import SwiftUI

/// 会话状态字符串(来自协议 body.session.status)→ 展示标签/颜色。
enum SessionStatusUI {
    static func label(_ s: String) -> String {
        switch s {
        case "idle":    return "空闲"
        case "working": return "运行中"
        case "waiting": return "等待确认"
        case "done":    return "完成"
        case "ended":   return "已结束"
        default:        return s
        }
    }
    static func color(_ s: String) -> Color {
        switch s {
        case "working": return Theme.blue
        case "waiting": return Theme.gold
        case "done":    return Theme.green
        case "ended":   return Theme.textTer
        default:        return Theme.textSec
        }
    }
}

/// 屏 1 —— 任务列表(首页)。每个 claude 终端会话 = 一个任务(来自服务器,非模拟数据)。
struct TasksView: View {
    @EnvironmentObject private var relay: RelayClient
    @State private var showLaunch = false
    @State private var launchCmd = "claude"
    @State private var launched = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        header
                        if relay.sessions.isEmpty {
                            emptyState
                        } else {
                            ForEach(relay.sessions) { s in
                                NavigationLink(value: s.id) {
                                    SessionCard(session: s)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationDestination(for: String.self) { sid in
                TaskDetailView(sessionId: sid)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showLaunch) { launchSheet }
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
            // 新建会话:电脑端开一个终端跑命令
            Button {
                launchCmd = "claude"; launched = false; showLaunch = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Theme.blueBtn).clipShape(Circle())
            }
            .disabled(!relay.agents.contains { $0.online })
        }
    }

    /// 新建会话弹层:在电脑上开一个 Terminal.app 跑命令(默认 claude)。
    private var launchSheet: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text("在电脑上新建会话").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                Text("电脑会打开一个终端窗口运行下面的命令。想进某个项目就带上 cd,例如:\ncd ~/proj && claude")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSec)
                TextField("", text: $launchCmd, prompt: Text("要运行的命令").foregroundColor(Theme.textTer), axis: .vertical)
                    .font(.system(size: 15, design: .monospaced)).foregroundStyle(Theme.text)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .lineLimit(1...4)
                    .padding(12).background(Theme.field)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Button {
                    relay.launchCommand(launchCmd)
                    launched = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { showLaunch = false }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: launched ? "checkmark.circle.fill" : "play.fill")
                        Text(launched ? "已发送,等终端启动…" : "在电脑上运行")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(launchCmd.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.cardHi
                                : (launched ? Theme.green : Theme.blueBtn))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(launchCmd.trimmingCharacters(in: .whitespaces).isEmpty || launched)
                Spacer()
            }
            .padding(24)
        }
        .presentationDetents([.medium])
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
            Text("暂无进行中的任务")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            Text("在电脑上打开终端运行 Claude Code,会话会作为任务出现在这里")
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
