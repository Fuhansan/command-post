import Foundation

/// 会话元数据:用户自定义标题 + 隐藏黑名单。按稳定 key(claude session_id / 手动会话 id)持久化。
/// 「删除」= 加入 hidden,后台只是不展示,不动真实转录。
@MainActor
final class SessionMetaStore {
    static let shared = SessionMetaStore()

    private(set) var titles: [String: String] = [:]
    private(set) var hidden: Set<String> = []

    private struct Persist: Codable { var titles: [String: String]; var hidden: [String] }
    private static let url = URL(fileURLWithPath:
        NSString(string: "~/.vibenotch/console-session-meta.json").expandingTildeInPath)

    init() { load() }

    func title(for key: String) -> String? { titles[key] }
    func isHidden(_ key: String) -> Bool { hidden.contains(key) }

    func rename(_ key: String, to title: String) {
        guard !key.isEmpty else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { titles[key] = nil } else { titles[key] = t }
        save()
    }
    func hide(_ key: String) { guard !key.isEmpty else { return }; hidden.insert(key); save() }
    func unhide(_ key: String) { hidden.remove(key); save() }

    /// 隐藏项列表(key + 展示名),供「已隐藏」恢复。
    func hiddenEntries() -> [(key: String, title: String)] {
        hidden.map { ($0, titles[$0] ?? $0) }.sorted { $0.title < $1.title }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.url),
              let p = try? JSONDecoder().decode(Persist.self, from: data) else { return }
        titles = p.titles; hidden = Set(p.hidden)
    }
    private func save() {
        let p = Persist(titles: titles, hidden: Array(hidden))
        if let data = try? JSONEncoder().encode(p) { try? data.write(to: Self.url, options: .atomic) }
    }
}
