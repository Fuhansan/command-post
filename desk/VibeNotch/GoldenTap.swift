import Foundation

/// P1 验证夹具(见 docs/message-hub.md §12):开启时把发往中转的 `ui`/`patch` 帧原样落盘,
/// 供枢纽迁移**前/后**逐帧比对,客观判定「行为没回退」。
///
/// 开关 = 标记文件 `~/.vibenotch/golden/RECORD` 是否存在(`touch` 开、`rm` 停,无需重新构建)。
/// 平时零开销:每 20 次调用才 stat 一次标记;auth/reset 帧(含 token)绝不落盘。
///
/// 用法:
///   录基线:`mkdir -p ~/.vibenotch/golden && touch ~/.vibenotch/golden/RECORD`
///          → 在 JetBrains 跑一小段 hook 会话 → `rm ~/.vibenotch/golden/RECORD`
///          → `mv ~/.vibenotch/golden/frames.jsonl ~/.vibenotch/golden/baseline.jsonl`
///   迁移后:同样录一份 `hub.jsonl`,再 diff(脚本忽略 seq / time 等传输字段)。
enum GoldenTap {
    private static let dir = NSString(string: "~/.vibenotch/golden").expandingTildeInPath
    private static let queue = DispatchQueue(label: "vibenotch.golden")

    static func record(_ json: String) {
        // 只录消息帧;auth/reset 跳过(且 auth 含 token,绝不落盘)。
        guard json.contains("\"t\":\"ui\"") || json.contains("\"t\":\"patch\"") else { return }
        // 每次都 stat 标记文件:RECORD 平时不存在 → 这一句几乎零成本;录制期才落盘。
        guard FileManager.default.fileExists(atPath: dir + "/RECORD") else { return }
        queue.async {
            let path = dir + "/frames.jsonl"
            let line = Data((json + "\n").utf8)
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile(); h.write(line); try? h.close()
            } else {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? line.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
