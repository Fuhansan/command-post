import SwiftUI

/// 屏 3 —— 通知 / 跨会话待办中心。
/// 「待审批」聚合所有会话的命令审批,可逐个或一键批量允许/拒绝;
/// 「待选择」(选择题/计划确认)必须逐个作答,点击跳进对应会话。
struct NotificationsView: View {
    @EnvironmentObject private var relay: RelayClient

    private var permSessions: [RelaySession] { relay.sessions.filter { $0.pendingKind == "perm" } }
    private var questionSessions: [RelaySession] { relay.sessions.filter { $0.pendingKind == "question" } }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        if permSessions.isEmpty && questionSessions.isEmpty {
                            emptyState
                        } else {
                            if !permSessions.isEmpty { permSection }
                            if !questionSessions.isEmpty { questionSection }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationDestination(for: String.self) { sid in
                TaskDetailView(sessionId: sid)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        HStack {
            Text("通知").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
            Spacer()
            if relay.pendingCount > 0 {
                Text("\(relay.pendingCount) 项待处理")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.gold)
            }
        }
    }

    // MARK: - 待审批(可批量)

    private var permSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("待审批").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textSec)
                Spacer()
                if permSessions.count > 1 {
                    Button("全部拒绝") { permSessions.forEach { deny($0) } }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSec)
                    Button { permSessions.forEach { allow($0) } } label: {
                        Text("全部允许")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Theme.coral).clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            ForEach(permSessions) { s in
                VStack(alignment: .leading, spacing: 8) {
                    NavigationLink(value: s.id) {
                        HStack(spacing: 8) {
                            Avatar(letter: String(s.title.prefix(1)), color: Theme.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                                Text("请求执行命令").font(.system(size: 12)).foregroundStyle(Theme.gold)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.textTer)
                        }
                    }
                    .buttonStyle(.plain)
                    if !s.pendingDetail.isEmpty {
                        Text(s.pendingDetail)
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSec)
                            .lineLimit(3)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.field)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    HStack(spacing: 10) {
                        Button { deny(s) } label: {
                            Text("拒绝").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(Theme.cardHi)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                        Button { allow(s) } label: {
                            Text("允许").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(Theme.coral)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(14).cardStyle(stroke: Theme.coral.opacity(0.5))
            }
        }
    }

    // MARK: - 待选择(逐个作答,跳进会话)

    private var questionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("待选择(需逐个作答)").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textSec)
            ForEach(questionSessions) { s in
                NavigationLink(value: s.id) {
                    HStack(spacing: 10) {
                        Avatar(letter: String(s.title.prefix(1)), color: Theme.purple)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(s.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                            Text(s.pendingDetail.isEmpty ? "等待你选择" : s.pendingDetail)
                                .font(.system(size: 13)).foregroundStyle(Theme.textSec)
                                .lineLimit(2).multilineTextAlignment(.leading)
                        }
                        Spacer()
                        Text("去作答")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Theme.blueBtn).clipShape(Capsule())
                    }
                    .padding(14)
                }
                .buttonStyle(.plain)
                .cardStyle(stroke: Theme.gold.opacity(0.5))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell.slash").font(.system(size: 40)).foregroundStyle(Theme.textTer)
            Text("暂无待处理事项").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            Text("所有会话的审批请求与选择题会聚合在这里")
                .font(.system(size: 13)).foregroundStyle(Theme.textSec)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    private func allow(_ s: RelaySession) {
        relay.sendAction(ComponentAction(json: .object([
            "id": .string("perm_allow"), "value": .string(s.id)
        ]))!, for: "sess:\(s.id)", sessionId: s.id)
    }

    private func deny(_ s: RelaySession) {
        relay.sendAction(ComponentAction(json: .object([
            "id": .string("perm_deny"), "value": .string(s.id)
        ]))!, for: "sess:\(s.id)", sessionId: s.id)
    }
}

/// 中性(描边)按钮 —— 复用组件。
struct NeutralButton: View {
    let label: String
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(Theme.cardHi)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
}
