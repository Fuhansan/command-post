import Foundation

/// 图片上传 REST(服务器 8080)。
///
/// 手机把图片字节用 HTTP 上传换回一个 id,WebSocket 控制通道只传这个 id,
/// 不再把 base64 塞进帧里(避免撑大流量、挤心跳、重传整图)。
enum ImageAPI {
    /// 上传一张 JPEG,返回服务器分配的 id(如 img_1a2b3c)。
    /// 服务器 IP 沿用设置页,端口固定 8080(Spring MVC,与 WS 的 8090 分开)。
    static func upload(jpeg: Data) async throws -> String {
        // savedHost / sessionToken 是主线程隔离的,先在主线程取出再发请求。
        let (host, token) = await MainActor.run { (RelayClient.savedHost, AppState.sessionToken) }
        guard let url = URL(string: "http://\(host):8080/api/image/upload?ext=jpg") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = jpeg
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard let obj = try? JSONDecoder().decode([String: String].self, from: data),
              let id = obj["id"] else { throw URLError(.cannotParseResponse) }
        return id
    }
}
