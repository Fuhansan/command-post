import AppKit

/// 图片中转工具:全程按 id。通道里只走 id;字节按 id 上传/下载,本地按 id 持久缓存。
/// base64 只出现在「上传那一步」(无 OSS)。缩略图等任何 base64 都不进通道。
enum ImageRelay {
    private static var cacheDir: String {
        let d = (NSString(string: "~/.vibenotch/imgcache")).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }
    /// 按 id 的本地缓存路径(driver 当文件路径喂 agent、scheme handler 按 id 取字节都用它)。
    static func cachePath(id: String, ext: String) -> String {
        let safeId = id.replacingOccurrences(of: "/", with: "_")
        return "\(cacheDir)/\(safeId).\(ext.isEmpty ? "img" : ext)"
    }
    /// 把字节按 id 落到本地缓存,返回路径。
    @discardableResult
    static func saveById(id: String, ext: String, data: Data) -> String? {
        let path = cachePath(id: id, ext: ext)
        return FileManager.default.createFile(atPath: path, contents: data) ? path : nil
    }
    /// 确保本地有这张图:命中缓存直接返回路径;否则按 id 回源下载再缓存。
    static func ensureCached(id: String, ext: String) -> String? {
        let path = cachePath(id: id, ext: ext)
        if FileManager.default.fileExists(atPath: path) { return path }
        guard let data = download(id: id) else { return nil }
        return saveById(id: id, ext: ext, data: data)
    }

    /// 上传到服务器(POST /api/image/upload),返回 (id, ext)。带配对 token,按账号隔离。同步阻塞,在后台调用。
    static func upload(_ data: Data, ext: String) -> (id: String, ext: String)? {
        guard let url = URL(string: "\(AgentServer.httpBase)/api/image/upload?ext=\(ext)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("image/\(ext == "jpg" ? "jpeg" : ext)", forHTTPHeaderField: "Content-Type")
        if let token = AgentCredentials.token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = data
        var out: (String, String)?
        let sem = DispatchSemaphore(value: 0)
        URLSession.direct.dataTask(with: req) { d, resp, _ in
            defer { sem.signal() }
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200, let d = d,
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let id = obj["id"] as? String else { return }
            out = (id, (obj["ext"] as? String) ?? ext)
        }.resume()
        _ = sem.wait(timeout: .now() + 30)
        return out.map { (id: $0.0, ext: $0.1) }
    }

    /// 凭 id 从服务器下载字节(GET /api/image/<id>,带 token)。同步阻塞,在后台调用。
    static func download(id: String) -> Data? {
        guard let url = URL(string: "\(AgentServer.httpBase)/api/image/\(id)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 30)
        if let token = AgentCredentials.token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        var out: Data?
        let sem = DispatchSemaphore(value: 0)
        URLSession.direct.dataTask(with: req) { d, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 { out = d }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 30)
        return out
    }

    /// 历史 transcript 里的图是内联 base64、没有服务器 id:落到本地缓存、用内容 hash 当本地 id,
    /// 返回 id,桌面 web 按 `app://__img/<id>` 取(通道里只走这个 id,不放 base64)。
    static func cacheBase64(_ b64: String, ext: String) -> String? {
        guard let data = Data(base64Encoded: b64) else { return nil }
        let id = stableId(b64)
        return saveById(id: id, ext: ext, data: data) != nil ? id : nil
    }
    private static func stableId(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603   // FNV-1a 64
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return "h" + String(h, radix: 16)
    }
}
