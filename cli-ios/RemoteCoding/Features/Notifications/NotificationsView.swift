import SwiftUI

/// 屏 3 —— 通知 / 审批。
/// 通知尚无协议(PROTOCOL §12 TODO),此处先空态;后续由服务器推送驱动,不放任何模拟数据。
struct NotificationsView: View {
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    header
                    emptyState
                }
                .padding(16)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("通知").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
            Spacer()
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 17)).foregroundStyle(Theme.textSec)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell.slash").font(.system(size: 40)).foregroundStyle(Theme.textTer)
            Text("暂无通知").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            Text("审批请求与任务通知会出现在这里")
                .font(.system(size: 13)).foregroundStyle(Theme.textSec)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
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
