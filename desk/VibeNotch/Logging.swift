import Foundation

private let _logURL: URL = {
    let dir = NSString(string: "~/.vibenotch").expandingTildeInPath
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return URL(fileURLWithPath: dir + "/agent.log")
}()
private let _logFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f
}()

func vlog(_ msg: String) {
    let line = "[\(_logFmt.string(from: Date()))] \(msg)\n"
    FileHandle.standardError.write(Data(line.utf8))
    // 同时落盘,便于事后排查;超 5MB 重置
    if let size = try? FileManager.default.attributesOfItem(atPath: _logURL.path)[.size] as? Int,
       size > 5_000_000 {
        try? FileManager.default.removeItem(at: _logURL)
    }
    if let h = try? FileHandle(forWritingTo: _logURL) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? Data(line.utf8).write(to: _logURL)
    }
}
