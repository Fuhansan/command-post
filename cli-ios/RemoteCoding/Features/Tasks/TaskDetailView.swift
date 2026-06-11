import SwiftUI

/// 屏 2 —— 会话详情(对话流)。每条消息 = 左侧头像 + 悬浮内容卡;用户输入靠右蓝气泡。
/// 内容全部来自该 `sid` 会话的实时下行(agent 下发的组件树)。
struct TaskDetailView: View {
    let sessionId: String
    @EnvironmentObject private var relay: RelayClient
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    private var session: RelaySession? { relay.session(id: sessionId) }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                navBar
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 14) {
                            sessionHeader
                            if let msgs = session?.messages, !msgs.isEmpty {
                                ForEach(msgs) { msg in
                                    messageRow(msg).id(msg.id)
                                }
                            } else {
                                emptyState
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                    .onChange(of: session?.messages.count ?? 0) { _, _ in
                        if let last = session?.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                inputBar
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
    }

    /// 一条消息:agent → [头像 + 内容];工具 chip 紧凑无头像;user → 右对齐气泡。
    @ViewBuilder
    private func messageRow(_ msg: UIMessage) -> some View {
        let content = ComponentView(component: msg.root)
            .environment(\.onComponentAction) { relay.sendAction($0, for: msg.id, sessionId: sessionId) }
        if msg.role == "user" {
            HStack(spacing: 0) { Spacer(minLength: 44); content }   // 用户内容统一右对齐
        } else if msg.root.type == "toolchip" {
            content.padding(.leading, 44)   // 缩进对齐头像后的内容
        } else {
            HStack(alignment: .top, spacing: 10) {
                let style = messageAvatarStyle(for: msg.root)
                MessageAvatar(icon: style.icon, colors: style.colors)
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var navBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
            }
            Spacer()
            Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var sessionHeader: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Color(hex: 0x7C5CD6), Color(hex: 0xC061E0)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 52, height: 52)
                .overlay(Text(String((session?.title ?? "会").prefix(1)))
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 4) {
                Text(session?.title ?? "会话").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                let status = session?.status ?? "working"
                HStack(spacing: 6) {
                    Circle().fill(SessionStatusUI.color(status)).frame(width: 7, height: 7)
                    Text(SessionStatusUI.label(status))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(SessionStatusUI.color(status))
                    if let term = session?.terminal, !term.isEmpty, term != "?" {
                        Text("· \(term)").font(.system(size: 14)).foregroundStyle(Theme.textSec)
                    }
                }
                if let cwd = session?.cwd, !cwd.isEmpty, cwd != "?" {
                    HStack(spacing: 5) {
                        Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Theme.textTer)
                        Text(shortMacPath(cwd)).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textSec).lineLimit(1).truncationMode(.head)
                    }
                }
            }
            Spacer()
        }
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "ellipsis.bubble").font(.system(size: 34)).foregroundStyle(Theme.textTer)
            Text("等待下发内容…").font(.system(size: 14)).foregroundStyle(Theme.textSec)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("", text: $draft, prompt: Text("输入指令…").foregroundColor(Theme.textTer))
                .font(.system(size: 15))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Theme.field)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Theme.blueBtn)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(16)
        .background(Theme.bg)
    }

    private func send() {
        relay.sendInput(text: draft, sessionId: sessionId)
        draft = ""
    }
}
