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
        if FileManager.default.fileExists(atPath: path) { return path }   // 命中即跳过,不重写
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
        let id = cheapId(b64)
        if FileManager.default.fileExists(atPath: cachePath(id: id, ext: ext)) { return id }  // 已缓存:不解码不写
        guard let data = Data(base64Encoded: b64) else { return nil }
        return saveById(id: id, ext: ext, data: data) != nil ? id : nil
    }

    /// 廉价 id:只取首尾若干字符 + 长度做 FNV,不哈希整段(单张图 base64 几百 KB,逐字节哈希太慢)。
    /// 够稳定、碰撞概率极低,足够做缓存键 + 去重。
    static func cheapId(_ b64: String) -> String {
        let u = Array(b64.utf8); let n = u.count
        var h: UInt64 = 1469598103934665603
        for b in u.prefix(96) { h = (h ^ UInt64(b)) &* 1099511628211 }
        for b in u.suffix(48) { h = (h ^ UInt64(b)) &* 1099511628211 }
        h = (h ^ UInt64(truncatingIfNeeded: n)) &* 1099511628211
        return "h" + String(h, radix: 16)
    }

    // 懒索引:历史图 base64 太大,解析时**不解码**,只记 id→(转录文件, 行起始字节, 该行第几张图, ext)。
    // 真要显示时(scheme handler 取图)才按位置切出那一行、解出那一张、缓存。文字消息因此不被图片拖慢。
    private static var b64Loc: [String: (path: String, lineStart: UInt64, imgIdx: Int, ext: String)] = [:]
    private static let b64Lock = NSLock()

    // 本地文件按 id 取(用于队列消息里的 [Image #NN] → ~/.claude/image-cache/<会话>/NN.* 直接当缩略图)。
    private static var localFiles: [String: String] = [:]
    private static let lfLock = NSLock()
    /// 登记一个本地图片文件,返回可被 app://__img/<id> 取到的 id。
    static func registerLocalFile(_ path: String) -> String {
        let id = cheapId(path)
        lfLock.lock(); localFiles[id] = path; lfLock.unlock()
        return id
    }
    static func localFilePath(id: String) -> String? {
        lfLock.lock(); defer { lfLock.unlock() }; return localFiles[id]
    }

    /// 解析转录窗口时调用:登记一张图的位置(不解码、不写盘),返回廉价 id。
    static func indexB64(_ b64: String, path: String, lineStart: UInt64, imgIdx: Int, ext: String) -> String {
        let id = cheapId(b64)
        b64Lock.lock(); b64Loc[id] = (path, lineStart, imgIdx, ext); b64Lock.unlock()
        return id
    }

    /// scheme handler 取图:命中缓存直接返回;否则按索引切出转录那一行、解出第 imgIdx 张图、缓存、返回。
    static func ensureFromIndex(id: String, ext: String) -> String? {
        let p = cachePath(id: id, ext: ext)
        if FileManager.default.fileExists(atPath: p) { return p }            // 命中即跳过(不解码)
        b64Lock.lock(); let loc = b64Loc[id]; b64Lock.unlock()
        guard let loc, let fh = FileHandle(forReadingAtPath: loc.path) else { return nil }
        defer { try? fh.close() }
        try? fh.seek(toOffset: loc.lineStart)
        var line = Data(); let chunk = 256 * 1024
        while line.count < 64 * 1024 * 1024 {                                // 读到行尾(图片行可能很大)
            guard let part = try? fh.read(upToCount: chunk), !part.isEmpty else { break }
            if let nl = part.firstIndex(of: 0x0A) { line.append(part[..<nl]); break }
            line.append(part)
        }
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let msg = o["message"] as? [String: Any],
              let blocks = msg["content"] as? [[String: Any]] else { return nil }
        let images = blocks.filter { ($0["type"] as? String) == "image" }
        guard loc.imgIdx < images.count,
              let src = images[loc.imgIdx]["source"] as? [String: Any],
              let b64 = src["data"] as? String, let data = Data(base64Encoded: b64) else { return nil }
        return saveById(id: id, ext: ext, data: data)
    }
}
