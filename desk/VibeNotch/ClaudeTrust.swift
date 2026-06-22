import Foundation

/// 预置 Claude Code 对某目录的「信任」,避免新会话卡在启动时的
/// 「Do you trust the files in this folder?」确认(该提示早于 hook,手机接不到)。
/// 效果等同用户手动点「Yes, trust」:写 ~/.claude.json 的
/// projects.<dir>.hasTrustDialogAccepted = true。
enum ClaudeTrust {

    private static let path = NSString(string: "~/.claude.json").expandingTildeInPath

    /// 把若干目录标记为已信任。原子写,只增字段,不动其他内容。
    static func trust(directories dirs: [String]) {
        let targets = dirs
            .map { (($0 as NSString).expandingTildeInPath as String).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !targets.isEmpty else { return }

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        var projects = (root["projects"] as? [String: Any]) ?? [:]
        var changed = false
        for dir in targets {
            var entry = (projects[dir] as? [String: Any]) ?? [:]
            if (entry["hasTrustDialogAccepted"] as? Bool) != true {
                entry["hasTrustDialogAccepted"] = true
                projects[dir] = entry
                changed = true
            }
        }
        guard changed else { return }
        root["projects"] = projects

        guard let out = try? JSONSerialization.data(withJSONObject: root,
                                                    options: [.prettyPrinted]) else { return }
        // 原子写(临时文件 + rename),避免与正在运行的 claude 抢写时损坏
        let tmp = path + ".vibenotch.tmp"
        do {
            try out.write(to: URL(fileURLWithPath: tmp), options: .atomic)
            _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                       withItemAt: URL(fileURLWithPath: tmp))
        } catch {
            vlog("claude trust write failed: \(error.localizedDescription)")
        }
    }
}
