import Darwin
import Foundation

enum ProcessUtils {
    /// Walk parent chain starting from `pid` and return the first matching terminal.
    /// Bound the walk to `maxDepth` to defend against odd states.
    static func findTerminalKind(startPid: pid_t, maxDepth: Int = 32) -> TerminalKind {
        findTerminal(startPid: startPid, maxDepth: maxDepth).kind
    }

    /// Walk parent chain and return both the matched kind and its PID, so the
    /// caller can later activate the actual NSRunningApplication.
    static func findTerminal(startPid: pid_t, maxDepth: Int = 32) -> (kind: TerminalKind, pid: pid_t?) {
        var current = startPid
        var depth = 0
        while depth < maxDepth {
            guard let info = procInfo(pid: current) else { return (.unknown, nil) }
            if let kind = TerminalKind.match(processName: info.name, path: procPath(pid: current)) {
                return (kind, current)
            }
            if info.ppid <= 1 { return (.unknown, nil) }
            current = info.ppid
            depth += 1
        }
        return (.unknown, nil)
    }

    /// Returns (executable name, parent pid) for the given pid, or nil if lookup fails.
    static func procInfo(pid: pid_t) -> (name: String, ppid: pid_t)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]

        let result = mib.withUnsafeMutableBufferPointer { mibBuf -> Int32 in
            sysctl(mibBuf.baseAddress, UInt32(mibBuf.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }

        let commCapacity = MemoryLayout.size(ofValue: info.kp_proc.p_comm)
        let name = withUnsafePointer(to: &info.kp_proc.p_comm) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: commCapacity) {
                String(cString: $0)
            }
        }
        return (name, info.kp_eproc.e_ppid)
    }

    /// Full executable path for a process. `p_comm` is capped to a tiny buffer
    /// on macOS, so app-host detection needs this for paths like Codex.app.
    static func procPath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Full argv for a process. `proc_pidpath` only returns the executable, but
    /// distinguishing `codex app-server` from terminal `codex resume` needs args.
    static func commandLine(pid: pid_t) -> [String]? {
        let maxArgs = max(Int(sysconf(_SC_ARG_MAX)), 4096)
        var buffer = [CChar](repeating: 0, count: maxArgs)
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let result = mib.withUnsafeMutableBufferPointer { mibPtr in
            sysctl(mibPtr.baseAddress, UInt32(mibPtr.count), &buffer, &size, nil, 0)
        }
        guard result == 0, size > MemoryLayout<Int32>.size else { return nil }

        var argc: Int32 = 0
        memcpy(&argc, buffer, MemoryLayout<Int32>.size)
        guard argc > 0 else { return [] }

        var index = MemoryLayout<Int32>.size
        // Skip executable path.
        while index < size && buffer[index] != 0 { index += 1 }
        // Skip NUL padding before argv[0].
        while index < size && buffer[index] == 0 { index += 1 }

        var args: [String] = []
        while index < size && args.count < Int(argc) {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            if index > start {
                let bytes = buffer[start..<index].map { UInt8(bitPattern: $0) }
                if let s = String(bytes: bytes, encoding: .utf8), !s.isEmpty {
                    args.append(s)
                }
            }
            while index < size && buffer[index] == 0 { index += 1 }
        }
        return args
    }

    static func hasCodexAppServerAncestor(startPid: pid_t, maxDepth: Int = 32) -> Bool {
        var current = startPid
        var depth = 0
        while current > 1 && depth < maxDepth {
            if let args = commandLine(pid: current),
               args.contains(where: { ($0 as NSString).lastPathComponent == "codex" }),
               args.dropFirst().contains("app-server") {
                return true
            }
            guard let info = procInfo(pid: current) else { return false }
            current = info.ppid
            depth += 1
        }
        return false
    }
}
