import Foundation

enum TerminalKind: String, Equatable {
    case iterm2
    case terminal
    case ghostty
    case warp
    case kitty
    case alacritty
    case wezterm
    case hyper
    case vscode
    case cursor
    case windsurf
    case jetbrains
    case xcode
    case tmux
    case unknown

    var displayName: String {
        switch self {
        case .iterm2: return "iTerm2"
        case .terminal: return "Terminal"
        case .ghostty: return "Ghostty"
        case .warp: return "Warp"
        case .kitty: return "kitty"
        case .alacritty: return "Alacritty"
        case .wezterm: return "WezTerm"
        case .hyper: return "Hyper"
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        case .windsurf: return "Windsurf"
        case .jetbrains: return "JetBrains"
        case .xcode: return "Xcode"
        case .tmux: return "tmux"
        case .unknown: return "?"
        }
    }

    /// SF Symbol used as a placeholder logo (real per-vendor logos arrive in stage 9).
    var sfSymbol: String {
        switch self {
        case .vscode, .cursor, .windsurf, .jetbrains, .xcode:
            return "chevron.left.forwardslash.chevron.right"
        case .unknown:
            return "questionmark.circle"
        default:
            return "terminal.fill"
        }
    }

    /// JetBrains IDE binary basenames (lowercased). Matched as exact basenames.
    private static let jetbrainsNames: Set<String> = [
        "pycharm", "idea", "webstorm", "goland", "rubymine", "phpstorm",
        "clion", "datagrip", "rider", "appcode", "fleet", "android studio",
        "studio", "rustrover", "aqua", "mps",
    ]

    static func match(processName name: String) -> TerminalKind? {
        let lower = name.lowercased()
        if lower.contains("iterm") { return .iterm2 }
        if lower == "terminal" { return .terminal }
        if lower.contains("ghostty") { return .ghostty }
        if lower.contains("warp") { return .warp }
        if lower.contains("kitty") { return .kitty }
        if lower.contains("alacritty") { return .alacritty }
        if lower.contains("wezterm") { return .wezterm }
        if lower.contains("hyper") { return .hyper }
        if lower.contains("cursor") { return .cursor }
        if lower.contains("windsurf") { return .windsurf }
        if lower.contains("xcode") { return .xcode }
        if jetbrainsNames.contains(where: { lower == $0 || lower.contains($0) }) {
            return .jetbrains
        }
        // 注意:必须精确匹配,否则 "codex"(含子串 "code")会被误判成 VS Code,
        // 进而把 codex 自己的 pid 当成终端 pid,导致 NSRunningApplication 找不到、注入失败。
        // VS Code 的进程 comm 是 "Code" / "Code Helper" / "Code Helper (Plugin)" 等。
        if lower == "code" || lower.hasPrefix("code ") { return .vscode }
        if lower == "tmux" || lower.hasPrefix("tmux:") { return .tmux }
        return nil
    }
}
