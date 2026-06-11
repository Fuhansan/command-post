import Foundation

/// PROTOCOL §2 —— 连接状态。
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed(String)
}

/// PROTOCOL §2 —— 出站长连接客户端(URLSessionWebSocketTask)。
/// 负责:连接 / 收发文本帧 / 心跳 / 断线退避重连。
/// 注:本脚手架实现了连接与收发主干;心跳与重连为最小实现,细节见 TODO。
@MainActor
final class WebSocketClient: NSObject, ObservableObject {
    @Published private(set) var state: ConnectionState = .disconnected

    /// 收到一条解码后的 Frame 时回调。
    var onFrame: ((Frame) -> Void)?

    /// 连接(含重连)就绪后回调 —— 上层在此重发 auth(PROTOCOL §8.1)。
    var onConnect: (() -> Void)?

    private var task: URLSessionWebSocketTask?
    private lazy var session: URLSession = URLSession(configuration: .default)
    private var url: URL?
    private var retry = 0

    func connect(to url: URL) {
        self.url = url
        state = .connecting
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop()
        state = .connected
        retry = 0
        onConnect?()   // 上层据此发 auth 帧(首连与重连都会触发)
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .disconnected
    }

    /// 发送任意 Codable 的 Frame(出站)。
    func send<T: Encodable>(_ payload: T) {
        guard let data = try? JSONEncoder().encode(payload),
              let text = String(data: data, encoding: .utf8) else { return }
        sendRaw(text)
    }

    /// 发送一条已序列化好的 JSON 文本帧。
    func sendRaw(_ text: String) {
        task?.send(.string(text)) { error in
            if let error { print("[WS] send error:", error) }
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .success(let message):
                    if case .string(let text) = message, let frame = Frame.decode(text) {
                        self.onFrame?(frame)
                    }
                    self.receiveLoop()
                case .failure(let error):
                    self.state = .failed(error.localizedDescription)
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard let url else { return }
        retry += 1
        let delay = min(pow(2.0, Double(retry)), 30)   // 指数退避,封顶 30s
        state = .reconnecting
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.connect(to: url)
        }
    }
}
