import SwiftUI

/// 字母头像(圆角方块)。
struct Avatar: View {
    let letter: String
    let color: Color
    var size: CGFloat = 44
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(letter)
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}

/// 状态徽章(图标 + 文字,半透明底色)。
struct StatusBadge: View {
    let status: TaskStatus
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.icon).font(.system(size: 11, weight: .semibold))
            Text(status.label).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(status.color)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(status.color.opacity(0.14))
        .clipShape(Capsule())
    }
}

/// 统计卡(待处理 / 运行中 / 已完成)。
struct StatCard: View {
    let icon: String
    let label: String
    let value: Int
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(color)
                Text(label).font(.system(size: 13)).foregroundStyle(Theme.textSec)
            }
            Text("\(value)").font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardStyle()
    }
}

/// 主操作按钮。
struct ActionButton: View {
    let label: String
    let style: ActionStyle
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(style.fg)
                .padding(.horizontal, 18).padding(.vertical, 9)
                .background(style.bg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// 任务卡(设计图首页列表项)。
struct TaskCard: View {
    let task: TaskItem
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Avatar(letter: task.letter, color: task.avatarColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(task.agent).font(.system(size: 13)).foregroundStyle(Theme.textSec)
                }
                Spacer()
                StatusBadge(status: task.status)
            }
            HStack {
                Text(task.detail).font(.system(size: 14)).foregroundStyle(Theme.textSec)
                    .lineLimit(1)
                Spacer()
                ActionButton(label: task.actionLabel, style: task.actionStyle)
            }
        }
        .padding(16)
        .cardStyle()
    }
}

/// 区块卡头部(图标 + 标题)。
struct SectionHeader: View {
    let icon: String
    let title: String
    var tint: Color = Theme.textSec
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(tint)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint == Theme.textSec ? Theme.text : tint)
            Spacer()
        }
    }
}

/// 通用区块卡容器。
struct SectionCard<Content: View>: View {
    let icon: String
    let title: String
    var tint: Color = Theme.textSec
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(icon: icon, title: title, tint: tint)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

/// 通知行。
struct NotificationRow: View {
    let noti: AppNotification
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: noti.kind.icon)
                .font(.system(size: 18))
                .foregroundStyle(noti.kind.color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(noti.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text(noti.subtitle).font(.system(size: 13)).foregroundStyle(Theme.textSec)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(noti.time).font(.system(size: 12)).foregroundStyle(Theme.textTer)
                if noti.unread {
                    Circle().fill(Theme.blue).frame(width: 7, height: 7)
                }
            }
        }
        .padding(14)
        .cardStyle()
    }
}
