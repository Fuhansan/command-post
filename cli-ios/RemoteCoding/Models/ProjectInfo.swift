import Foundation

/// 一个项目(= VibeNotch 打开的工作目录)。首页「项目区」一行,点进去看它的会话。
/// 数据来自电脑端 `console:projects` 通道的结构化 `body.projects`。
struct ProjectInfo: Identifiable, Hashable {
    var id: String { workdir }
    let workdir: String          // 工作目录(项目唯一键)
    let name: String             // 目录末段,做标题
    let history: [ProjectHistory]   // 该项目可恢复的历史会话(新→旧)
}

/// 项目下一条可恢复的历史会话(--resume 用)。
struct ProjectHistory: Identifiable, Hashable {
    let id: String       // claude session_id
    let label: String    // 首句摘要
}
