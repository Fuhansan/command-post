import Foundation

/// 文件树节点(url + 是否目录,isDir 预算好不再 body 里 syscall)。
struct FileNode: Hashable { let url: URL; let isDir: Bool }

/// 目录内容缓存:一次解析后复用,避免反复读磁盘。Web 控制台的 `listDir` 用它列目录。
enum DirCache {
    static let skipDirs: Set<String> = [
        "node_modules", ".git", ".build", "build", "DerivedData", "Pods", ".next",
        "dist", "out", "target", ".venv", "venv", "__pycache__", ".gradle", ".idea",
        "Carthage", ".swiftpm", ".cache", "vendor"
    ]
    static let maxChildren = 300
    private static var cache: [String: [FileNode]] = [:]

    static func children(_ dir: URL) -> [FileNode] {
        if let c = cache[dir.path] { return c }
        let nodes = compute(dir)
        cache[dir.path] = nodes
        return nodes
    }
    static func clear() { cache.removeAll() }

    private static func compute(_ dir: URL) -> [FileNode] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        let nodes = items.compactMap { url -> FileNode? in
            if skipDirs.contains(url.lastPathComponent) { return nil }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return FileNode(url: url, isDir: isDir)
        }
        let sorted = nodes.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
        return Array(sorted.prefix(maxChildren))
    }
}
