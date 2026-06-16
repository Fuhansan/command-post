import Foundation

/// 往用户 shell 配置(~/.zshrc、~/.bashrc)注入 claude/codex 的「透明 tmux 包装」函数:
/// 开发者照常敲 `claude`,它自动在 tmux 里跑(已在 tmux 内则直接跑)—— 这样手动起的
/// 会话也跑在 tmux,手机**锁屏也能遥控**。带标记、幂等、可一键卸载。
enum ShellWrapper {
    private static let begin = "# >>> AI Coding Remote (VibeNotch) tmux wrapper >>>"
    private static let end   = "# <<< AI Coding Remote (VibeNotch) tmux wrapper <<<"

    private static let block = """
    \(begin)
    # 让 claude/codex 自动在 tmux 里运行(已在 tmux 内则直接跑),这样手机锁屏也能遥控。
    # 关闭:在 VibeNotch 设置里关掉「终端自动用 tmux」,或删掉本段。
    _vn_wrap() {
      local tool="$1"; shift
      # 已在 tmux 内、没装 tmux、或不在交互终端(管道/脚本,tmux 无法 attach)→ 直接跑
      if [ -n "$TMUX" ] || ! command -v tmux >/dev/null 2>&1 || [ ! -t 0 ] || [ ! -t 1 ]; then
        command "$tool" "$@"; return
      fi
      local _vn_cmd="$tool" _vn_a
      for _vn_a in "$@"; do _vn_cmd="$_vn_cmd $(printf '%q' "$_vn_a")"; done
      tmux new-session -A -s "vn_$(date +%s)" "$_vn_cmd"
    }
    claude() { _vn_wrap claude "$@"; }
    codex()  { _vn_wrap codex "$@"; }
    \(end)
    """

    /// 目标 rc 文件:总写 ~/.zshrc(macOS 默认 zsh);~/.bashrc 存在才写。
    private static var rcFiles: [String] {
        let home = NSHomeDirectory()
        var files = ["\(home)/.zshrc"]
        let bash = "\(home)/.bashrc"
        if FileManager.default.fileExists(atPath: bash) { files.append(bash) }
        return files
    }

    static func isInstalled() -> Bool {
        rcFiles.contains { ((try? String(contentsOfFile: $0, encoding: .utf8)) ?? "").contains(begin) }
    }

    /// 按开关状态对齐:开→(重)写入当前块(install 幂等,顺带更新旧版本);关→卸载。
    static func apply(enabled: Bool) {
        if enabled {
            install()
        } else if isInstalled() {
            uninstall()
        }
    }

    static func install() {
        for f in rcFiles {
            var content = (try? String(contentsOfFile: f, encoding: .utf8)) ?? ""
            content = stripBlock(content)
            if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
            content += block + "\n"
            try? content.write(toFile: f, atomically: true, encoding: .utf8)
        }
        vlog("shell wrapper 已安装:claude/codex 自动 tmux(新开终端生效)")
    }

    static func uninstall() {
        for f in rcFiles {
            guard let content = try? String(contentsOfFile: f, encoding: .utf8), content.contains(begin) else { continue }
            try? stripBlock(content).write(toFile: f, atomically: true, encoding: .utf8)
        }
        vlog("shell wrapper 已卸载")
    }

    /// 去掉 begin…end 之间的旧块(含两行标记 + 末尾换行)。
    private static func stripBlock(_ s: String) -> String {
        guard let r1 = s.range(of: begin), let r2 = s.range(of: end) else { return s }
        var hi = r2.upperBound
        if hi < s.endIndex, s[hi] == "\n" { hi = s.index(after: hi) }
        var out = s
        out.removeSubrange(r1.lowerBound..<hi)
        return out
    }
}
