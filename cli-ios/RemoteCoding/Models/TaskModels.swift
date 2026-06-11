import SwiftUI

/// 任务状态(对应设计图的徽章与状态色)。
enum TaskStatus {
    case waitingApproval   // 等待审批
    case waitingInput      // 等待输入
    case running           // 运行中
    case completed         // 已完成
    case failed            // 执行失败

    var label: String {
        switch self {
        case .waitingApproval: return "等待审批"
        case .waitingInput:    return "等待输入"
        case .running:         return "运行中"
        case .completed:       return "已完成"
        case .failed:          return "执行失败"
        }
    }
    var color: Color {
        switch self {
        case .waitingApproval: return Theme.coral
        case .waitingInput:    return Theme.gold
        case .running:         return Theme.blue
        case .completed:       return Theme.green
        case .failed:          return Theme.coral
        }
    }
    var icon: String {
        switch self {
        case .waitingApproval: return "hourglass"
        case .waitingInput:    return "bubble.left.and.text.bubble.right"
        case .running:         return "play.circle"
        case .completed:       return "checkmark.circle"
        case .failed:          return "exclamationmark.triangle"
        }
    }
}

/// 操作按钮风格。
enum ActionStyle { case coral, gold, blue
    var bg: Color {
        switch self {
        case .coral: return Theme.coral
        case .gold:  return Theme.gold
        case .blue:  return Theme.blueBtn
        }
    }
    var fg: Color { self == .gold ? .black.opacity(0.85) : .white }
}

struct TaskItem: Identifiable, Hashable {
    let id: String
    let name: String
    let agent: String          // "Claude Code" / "Codex"
    let letter: String
    let avatarColor: Color
    let status: TaskStatus
    let detail: String         // "等待审批: npm install"
    let actionLabel: String    // "立即处理" / "回复" / "查看进度"
    let actionStyle: ActionStyle

    static func == (l: TaskItem, r: TaskItem) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// 通知。
enum NotiKind { case completed, waitingInput, failed
    var icon: String {
        switch self {
        case .completed:    return "checkmark.circle.fill"
        case .waitingInput: return "bubble.left.fill"
        case .failed:       return "exclamationmark.triangle.fill"
        }
    }
    var color: Color {
        switch self {
        case .completed:    return Theme.green
        case .waitingInput: return Theme.gold
        case .failed:       return Theme.coral
        }
    }
}

struct AppNotification: Identifiable {
    let id = UUID()
    let kind: NotiKind
    let title: String
    let subtitle: String
    let time: String
    let unread: Bool
}
