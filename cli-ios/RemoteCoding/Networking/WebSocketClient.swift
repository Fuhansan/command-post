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
    private var heartbeat: Timer?
    private var lastPongAt = Date()
    private var manualClose = false   // 用户主动断开 → 不自动重连,等手动重连

    func connect(to url: URL) {
        self.url = url
        manualClose = false
        state = .connecting
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 8 << 20   // 收发大帧(图片)余量
        self.task = task
        task.resume()
        receiveLoop()
        state = .connected
        retry = 0
        startHeartbeat()
        onConnect?()   // 上层据此发 auth 帧(首连与重连都会触发)
    }

    func disconnect() {
        manualClose = true
        heartbeat?.invalidate(); heartbeat = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .disconnected
    }

    /// 应用层心跳:25s 一次 ping;70s 没收到 pong 视为僵死连接(切网/锁屏后的
    /// TCP 黑洞,send 不报错只有心跳能发现),主动断开走重连。
    private func startHeartbeat() {
        lastPongAt = Date()
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if Date().timeIntervalSince(self.lastPongAt) > 70 {
                    self.heartbeat?.invalidate(); self.heartbeat = nil
                    self.task?.cancel(with: .goingAway, reason: nil)
                    self.scheduleReconnect()
                    return
                }
                self.sendRaw("{\"v\":1,\"t\":\"ping\",\"id\":\"p_ios\",\"ts\":\(Int(Date().timeIntervalSince1970 * 1000))}")
            }
        }
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
        // 绑定本次连接的 task:切换服务器/重连时,旧 task 被 cancel 后其回调会**异步晚到**,
        // 那时新 task 已就位。若不甄别,旧回调会掐掉新连接的心跳、触发多余重连(切服务器抖动)。
        let myTask = task
        myTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                // 关键:JSON 解码在 URLSession 的后台队列上完成,绝不占用主线程 ——
                // 大帧(组件树 / 最大 8MB 图片)解析不再卡 UI。只把结果回主线程派发。
                var frame: Frame? = nil
                if case .string(let text) = message { frame = Frame.decode(text) }
                Task { @MainActor in
                    guard myTask === self.task else { return }   // 过期 task 的回调,丢弃
                    if let frame {
                        if case .pong = frame.t {
                            self.lastPongAt = Date()   // 心跳回应,不上抛
                        } else {
                            self.onFrame?(frame)
                        }
                    }
                    self.receiveLoop()
                }
            case .failure(let error):
                Task { @MainActor in
                    guard myTask === self.task else { return }
                    self.heartbeat?.invalidate(); self.heartbeat = nil
                    if self.manualClose {
                        self.state = .disconnected   // 用户主动断开,保持断开态
                    } else {
                        self.state = .failed(error.localizedDescription)
                        self.scheduleReconnect()
                    }
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
