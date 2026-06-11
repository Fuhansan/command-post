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
            if let kind = TerminalKind.match(processName: info.name) {
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
}
