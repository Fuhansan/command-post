import Combine
import Foundation
import ServiceManagement

/// User-modifiable settings persisted to `~/.vibenotch/settings.json`.
/// Launch-at-login is intentionally excluded — `SMAppService.mainApp.status`
/// is the system source of truth; we read/write that directly so settings
/// can never disagree with the actual login-items registration.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var language: Language { didSet { persist() } }
    @Published var muted: Bool        { didSet { persist(); SoundPlayer.shared.muted = muted } }
    /// 手机「新建会话」时,新终端先 cd 进的默认工作目录(空=用 ~ )。
    @Published var defaultWorkdir: String { didSet { persist() } }
    /// 新建会话时在命令前自动执行的代理设置(大陆用户跑 claude 需要;空=不设)。
    @Published var launchProxy: String { didSet { persist() } }
    /// 让手动起的 claude/codex 自动跑在 tmux 里(手机锁屏也能遥控)。
    /// 开=往 shell rc 注入包装函数;关=卸载。
    @Published var tmuxWrap: Bool { didSet { persist(); ShellWrapper.apply(enabled: tmuxWrap) } }

    /// Mirrors `SMAppService.mainApp.status`; the setter actually
    /// (un)registers the login item, so the UI's binding is one-shot truth.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            let svc = SMAppService.mainApp
            do {
                if newValue, svc.status != .enabled { try svc.register() }
                if !newValue, svc.status == .enabled { try svc.unregister() }
            } catch {
                vlog("launch-at-login toggle failed: \(error.localizedDescription)")
            }
            objectWillChange.send()
        }
    }

    enum Language: String, CaseIterable, Codable, Identifiable {
        case system, english, chinese
        var id: String { rawValue }
    }

    private init() {
        let loaded = Self.loadFromDisk()
        self.language = loaded?.language ?? .system
        self.muted    = loaded?.muted    ?? false
        self.defaultWorkdir = loaded?.defaultWorkdir ?? ""
        self.launchProxy = loaded?.launchProxy ?? ""
        self.tmuxWrap = loaded?.tmuxWrap ?? true   // 默认开:用户要的「锁屏可控」靠它
        SoundPlayer.shared.muted = self.muted
        ShellWrapper.apply(enabled: self.tmuxWrap)  // 启动时对齐(幂等)
    }

    // MARK: - Persistence

    private static let configDir  = NSString(string: "~/.vibenotch").expandingTildeInPath
    private static let configPath = "\(configDir)/settings.json"

    private struct Stored: Codable {
        var language: Language
        var muted: Bool
        var defaultWorkdir: String?
        var launchProxy: String?
        var tmuxWrap: Bool?
    }

    private func persist() {
        let snap = Stored(language: language, muted: muted, defaultWorkdir: defaultWorkdir,
                          launchProxy: launchProxy, tmuxWrap: tmuxWrap)
        do {
            try FileManager.default.createDirectory(
                atPath: Self.configDir,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(snap)
            try data.write(to: URL(fileURLWithPath: Self.configPath), options: .atomic)
        } catch {
            vlog("settings persist failed: \(error.localizedDescription)")
        }
    }

    private static func loadFromDisk() -> Stored? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)) else {
            return nil
        }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }
}
