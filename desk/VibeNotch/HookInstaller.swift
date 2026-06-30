import Foundation

/// Installs the VibeNotch hook scripts into ~/.vibenotch/hooks and idempotently
/// merges hook entries into ~/.claude/settings.json. Existing user settings are
/// preserved; entries pointing to our scripts are deduplicated.
enum HookInstaller {
    static let baseDir = NSString(string: "~/.vibenotch/hooks").expandingTildeInPath
    static let settingsPath = NSString(string: "~/.claude/settings.json").expandingTildeInPath
    static let codexHooksPath = NSString(string: "~/.codex/hooks.json").expandingTildeInPath

    /// Events VibeNotch listens to. Order is the install order — also matches spec B-§2.
    static let events: [(name: String, file: String)] = [
        ("SessionStart", "session_start.sh"),
        ("UserPromptSubmit", "user_prompt_submit.sh"),
        ("PreToolUse", "pre_tool_use.sh"),
        ("PostToolUse", "post_tool_use.sh"),
        ("Notification", "notification.sh"),
        ("Stop", "stop.sh"),
        ("SessionEnd", "session_end.sh"),
    ]

    static let scriptTemplate = #"""
    #!/bin/bash
    # VibeNotch hook forwarder — managed by VibeNotch.app (v5)
    # Sends event to UDS, half-closes write side, then waits (up to 24h) for the
    # App's response (used by PreToolUse permissionDecision). For non-blocking
    # events, the App dismisses the connection immediately and we read EOF in
    # under 10ms. Always exits 0 — never breaks claude.
    VN_PPID="$PPID" exec /usr/bin/python3 -c '
    import json, os, socket, sys
    sock_path = os.path.expanduser("~/.vibenotch/sock")
    if not os.path.exists(sock_path):
        sys.exit(0)
    data = sys.stdin.read()
    try:
        obj = json.loads(data)
        obj["_ppid"] = int(os.environ.get("VN_PPID", "0"))
        payload = (json.dumps(obj) + "\n").encode()
    except Exception:
        payload = (data + "\n").encode()
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(86400.0)
        s.connect(sock_path)
        s.sendall(payload)
        try:
            s.shutdown(socket.SHUT_WR)
        except Exception:
            pass
        response = b""
        while True:
            try:
                chunk = s.recv(4096)
            except Exception:
                break
            if not chunk:
                break
            response += chunk
            if b"\n" in response:
                break
        s.close()
        line = response.split(b"\n", 1)[0]
        if line.strip():
            sys.stdout.write(line.decode("utf-8", errors="replace") + "\n")
            sys.stdout.flush()
    except Exception:
        pass
    '
    """#

    static let disabledFlagPath = NSString(string: "~/.vibenotch/disabled").expandingTildeInPath

    static func install() throws {
        try writeUninstallScript()
        if FileManager.default.fileExists(atPath: disabledFlagPath) {
            vlog("install skipped — disabled flag present at \(disabledFlagPath)")
            vlog("(rm ~/.vibenotch/disabled and relaunch to re-enable)")
            return
        }
        try writeScripts()
        try mergeSettings()
    }

    /// Disaster-recovery script: removes every VibeNotch hook entry from
    /// ~/.claude/settings.json without touching the rest of the config.
    /// Usable manually with `bash ~/.vibenotch/uninstall.sh`.
    static func writeUninstallScript() throws {
        let dir = NSString(string: "~/.vibenotch").expandingTildeInPath
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/uninstall.sh"
        let content = #"""
        #!/bin/bash
        # VibeNotch hook uninstaller — removes every hook entry whose command
        # path begins with $HOME/.vibenotch/hooks/ . Backs up settings.json first.
        set -e
        SETTINGS="$HOME/.claude/settings.json"
        if [[ ! -f "$SETTINGS" ]]; then
            echo "no settings.json; nothing to do"
            exit 0
        fi
        BACKUP="${SETTINGS}.uninstall-$(date +%s).bak"
        cp "$SETTINGS" "$BACKUP"
        /usr/bin/python3 - <<'EOF'
        import json, os, sys
        path = os.path.expanduser("~/.claude/settings.json")
        prefix = os.path.expanduser("~/.vibenotch/hooks/")
        with open(path) as f:
            cfg = json.load(f)
        hooks = cfg.get("hooks") or {}
        changed = False
        for ev, groups in list(hooks.items()):
            new_groups = []
            for g in (groups or []):
                inner = g.get("hooks") or []
                kept = [h for h in inner if not (h.get("command", "").startswith(prefix))]
                if kept:
                    g["hooks"] = kept
                    new_groups.append(g)
                else:
                    changed = True
            if new_groups:
                hooks[ev] = new_groups
            else:
                del hooks[ev]
                changed = True
        if not hooks:
            cfg.pop("hooks", None)
            changed = True
        else:
            cfg["hooks"] = hooks
        with open(path, "w") as f:
            json.dump(cfg, f, indent=2, sort_keys=True)
        print("done; backup at " + os.environ.get("BACKUP", "?"))
        EOF
        # Drop a flag file so the App won't re-install on next launch.
        touch "$HOME/.vibenotch/disabled"
        echo "VibeNotch hooks removed from settings.json. Backup: $BACKUP"
        echo "Disabled flag set at ~/.vibenotch/disabled."
        echo "Run 'rm ~/.vibenotch/disabled' and relaunch VibeNotch to re-enable."
        """#
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        vlog("uninstall script written to \(path)")
    }

    static func writeScripts() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
        for ev in events {
            let path = "\(baseDir)/\(ev.file)"
            try scriptTemplate.write(toFile: path, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        vlog("hook scripts written to \(baseDir)")
    }

    static func mergeSettings() throws {
        try mergeClaudeSettings()
        try mergeCodexHooks()
    }

    private static func mergeClaudeSettings() throws {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: settingsPath)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var json: [String: Any] = [:]
        if fm.fileExists(atPath: settingsPath),
           let data = try? Data(contentsOf: url),
           let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = obj
        }

        var hooks = (json["hooks"] as? [String: Any]) ?? [:]
        var addedAny = false

        for ev in events {
            let scriptPath = "\(baseDir)/\(ev.file)"
            var groups = (hooks[ev.name] as? [[String: Any]]) ?? []

            var alreadyInstalled = false
            // 已安装的条目:确保带 timeout(claude 默认 60s 会把扣住问题的 hook 杀掉)
            for gi in groups.indices {
                guard var hookList = groups[gi]["hooks"] as? [[String: Any]] else { continue }
                for hi in hookList.indices where (hookList[hi]["command"] as? String) == scriptPath {
                    alreadyInstalled = true
                    if (hookList[hi]["timeout"] as? Int) != 86400 {
                        hookList[hi]["timeout"] = 86400
                        groups[gi]["hooks"] = hookList
                        hooks[ev.name] = groups
                        addedAny = true
                    }
                }
            }
            guard !alreadyInstalled else { continue }

            groups.append([
                "hooks": [
                    ["type": "command", "command": scriptPath, "timeout": 86400],
                ],
            ])
            hooks[ev.name] = groups
            addedAny = true
        }

        json["hooks"] = hooks

        if addedAny {
            let data = try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: url, options: .atomic)
            vlog("hooks installed/updated in \(settingsPath)")
        } else {
            vlog("hooks already installed; no settings.json change")
        }
    }

    private static func mergeCodexHooks() throws {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: codexHooksPath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var json: [String: Any] = [:]
        if fm.fileExists(atPath: codexHooksPath),
           let data = try? Data(contentsOf: url),
           let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = obj
        }

        var hooks = (json["hooks"] as? [String: Any]) ?? [:]
        var changed = false
        let codexEvents = events.filter { ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"].contains($0.name) }
        for ev in codexEvents {
            let scriptPath = "\(baseDir)/\(ev.file)"
            var groups = (hooks[ev.name] as? [[String: Any]]) ?? []
            var alreadyInstalled = false
            for gi in groups.indices {
                guard var hookList = groups[gi]["hooks"] as? [[String: Any]] else { continue }
                for hi in hookList.indices where (hookList[hi]["command"] as? String) == scriptPath {
                    alreadyInstalled = true
                    if (hookList[hi]["timeout"] as? Int) != 86400 {
                        hookList[hi]["timeout"] = 86400
                        groups[gi]["hooks"] = hookList
                        hooks[ev.name] = groups
                        changed = true
                    }
                }
            }
            guard !alreadyInstalled else { continue }
            groups.append([
                "hooks": [
                    ["type": "command", "command": scriptPath, "timeout": 86400],
                ],
            ])
            hooks[ev.name] = groups
            changed = true
        }

        json["hooks"] = hooks
        if changed {
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            vlog("codex hooks installed/updated in \(codexHooksPath)")
        } else {
            vlog("codex hooks already installed; no hooks.json change")
        }
    }
}
