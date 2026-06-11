import Darwin
import Foundation

/// One in-flight hook invocation. The hook script blocked waiting for our
/// reply on the same UDS connection; the App must call either `respond` or
/// `dismiss` exactly once.
final class HookConnection {
    let event: HookEvent
    let raw: String
    private var fd: Int32
    private var resolved = false
    private let lock = NSLock()

    init(fd: Int32, event: HookEvent, raw: String) {
        self.fd = fd
        self.event = event
        self.raw = raw
    }

    /// Write `json` + "\n" to the script's stdout side, then close.
    /// Used for PreToolUse permissionDecision payloads.
    func respond(json: String) {
        lock.lock(); defer { lock.unlock() }
        guard !resolved else { return }
        resolved = true
        let payload = json + "\n"
        let data = Data(payload.utf8)
        data.withUnsafeBytes { buf in
            _ = write(fd, buf.baseAddress, buf.count)
        }
        close(fd)
    }

    /// Close the connection without writing anything (the script will read EOF
    /// and exit with empty stdout — claude continues with its normal flow).
    func dismiss() {
        lock.lock(); defer { lock.unlock() }
        guard !resolved else { return }
        resolved = true
        close(fd)
    }
}
