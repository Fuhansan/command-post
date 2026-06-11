import Darwin
import Foundation

/// Listens on a Unix domain socket and processes one event per accepted
/// connection in request-response style:
///   1. Read one `\n`-terminated JSON line as a `HookEvent`.
///   2. Hand the open fd to the App via a `HookConnection`.
///   3. The App eventually calls `respond(json:)` or `dismiss()` on it.
///
/// A 50-second watchdog dismisses any connection the App forgot.
final class UDSServer {
    let path: String
    private var listenFd: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "vibenotch.uds.accept")
    private let ioQueue = DispatchQueue(label: "vibenotch.uds.io", attributes: .concurrent)
    private let timeoutQueue = DispatchQueue(label: "vibenotch.uds.timeout")

    var onEvent: ((HookConnection) -> Void)?

    static let perConnectionTimeout: TimeInterval = 50

    init(path: String) {
        self.path = path
    }

    func start() throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(atPath: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path.0) { dst in
                _ = strlcpy(dst, src, capacity)
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockptr in
                Darwin.bind(fd, sockptr, addrLen)
            }
        }
        guard bindResult == 0 else {
            let e = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e))
        }

        guard listen(fd, 16) == 0 else {
            let e = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e))
        }

        listenFd = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.setCancelHandler { [fd] in close(fd) }
        src.resume()
        listenSource = src
    }

    func stop() {
        listenSource?.cancel()
        listenSource = nil
        listenFd = -1
        try? FileManager.default.removeItem(atPath: path)
    }

    private func acceptOne() {
        let clientFd = accept(listenFd, nil, nil)
        guard clientFd >= 0 else { return }
        ioQueue.async { [weak self] in self?.handleClient(fd: clientFd) }
    }

    private func handleClient(fd: Int32) {
        guard let line = readLine(fd: fd), !line.isEmpty else {
            close(fd)
            return
        }
        let raw = String(data: line, encoding: .utf8) ?? "<non-utf8>"
        let decoder = JSONDecoder()
        let event: HookEvent
        do {
            event = try decoder.decode(HookEvent.self, from: line)
        } catch {
            vlog("UDS decode failed: \(error.localizedDescription) raw=\(raw.prefix(200))")
            close(fd)
            return
        }

        let conn = HookConnection(fd: fd, event: event, raw: raw)

        timeoutQueue.asyncAfter(deadline: .now() + Self.perConnectionTimeout) {
            conn.dismiss()
        }

        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(conn)
        }
    }

    /// Blocking read of a single `\n`-terminated line. Returns nil on EOF
    /// before any byte arrived. Strips the trailing newline.
    private func readLine(fd: Int32) -> Data? {
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 {
                return buffer.isEmpty ? nil : buffer
            }
            if byte == 0x0A { return buffer }
            buffer.append(byte)
        }
    }
}
