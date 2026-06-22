import Foundation

/// 用量统计:扫 ~/.claude/projects/**/*.jsonl 里每条 assistant 消息的 usage,
/// 聚合 token / 缓存命中 / 请求数 / 按天 / 按模型;花费用内置单价表估算。
/// 按文件 mtime+size 缓存,只重扫变化的文件;短范围(14/30 天)只扫近期改动的文件。
actor UsageScanner {
    static let shared = UsageScanner()

    struct Bucket {
        var input = 0, output = 0, cacheRead = 0, cacheCreation = 0, requests = 0
        mutating func add(_ o: Bucket) {
            input += o.input; output += o.output; cacheRead += o.cacheRead
            cacheCreation += o.cacheCreation; requests += o.requests
        }
        var tokens: Int { input + output + cacheRead + cacheCreation }
    }
    private struct FileCache { let mtime: Date; let size: Int; let perDayModel: [String: [String: Bucket]] }
    private var cache: [String: FileCache] = [:]

    /// 各模型单价(USD / 1M tokens):input / output / cache 写入(5m)/ cache 读取。Anthropic 公开价,估算用。
    private static func price(_ model: String) -> (input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
        let m = model.lowercased()
        if m.contains("opus")  { return (15, 75, 18.75, 1.5) }
        if m.contains("haiku") { return (0.80, 4, 1.0, 0.08) }
        return (3, 15, 3.75, 0.30)   // 默认按 sonnet
    }
    private static func cost(_ model: String, _ b: Bucket) -> Double {
        let p = price(model)
        return Double(b.input) / 1e6 * p.input + Double(b.output) / 1e6 * p.output
             + Double(b.cacheCreation) / 1e6 * p.cacheWrite + Double(b.cacheRead) / 1e6 * p.cacheRead
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    /// 聚合。days>0 = 最近 N 天;days==0 = 全部。返回汇总 + 按天按模型的趋势序列(供折线图/排行)。
    func aggregate(days: Int) -> [String: Any] {
        let root = NSString(string: "~/.claude/projects").expandingTildeInPath
        let fm = FileManager.default
        var files: [String] = []
        for d in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let sub = "\(root)/\(d)"
            for f in (try? fm.contentsOfDirectory(atPath: sub)) ?? [] where f.hasSuffix(".jsonl") {
                files.append("\(sub)/\(f)")
            }
        }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let startToday = utc.startOfDay(for: Date())
        let cutoffDate = days > 0 ? utc.date(byAdding: .day, value: -(days - 1), to: startToday) : nil

        for path in files {
            let attrs = try? fm.attributesOfItem(atPath: path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
            let size = (attrs?[.size] as? Int) ?? 0
            if let c = cache[path], c.mtime == mtime, c.size == size { continue }   // 已缓存且未变
            if let cut = cutoffDate, mtime < cut { continue }                        // 老文件,本范围用不到,跳过
            cache[path] = FileCache(mtime: mtime, size: size, perDayModel: Self.parseFile(path))
        }
        cache = cache.filter { files.contains($0.key) }

        // 日期序列(短范围补零成连续天;全部=已有天升序)
        var dayKeys: [String]
        if let cutoffDate {
            dayKeys = (0..<days).map { Self.dayFmt.string(from: utc.date(byAdding: .day, value: $0, to: cutoffDate)!) }
        } else {
            var s = Set<String>()
            for (_, fc) in cache { for (day, _) in fc.perDayModel { s.insert(day) } }
            dayKeys = s.sorted()
        }
        let n = dayKeys.count
        var dayIndex: [String: Int] = [:]
        for (i, d) in dayKeys.enumerated() { dayIndex[d] = i }

        var totals = Bucket()
        var perModelDay: [String: [Bucket]] = [:]
        for (_, fc) in cache {
            for (day, models) in fc.perDayModel {
                guard let idx = dayIndex[day] else { continue }
                for (model, b) in models {
                    totals.add(b)
                    if perModelDay[model] == nil { perModelDay[model] = Array(repeating: Bucket(), count: n) }
                    perModelDay[model]![idx].add(b)
                }
            }
        }

        var totalCost = 0.0
        var series: [[String: Any]] = []
        for (model, arr) in perModelDay {
            let cost = arr.map { Self.cost(model, $0) }
            totalCost += cost.reduce(0, +)
            series.append([
                "name": model,
                "cost": cost,
                "token": arr.map { $0.input + $0.output },
                "req": arr.map { $0.requests },
            ])
        }

        return [
            "range": days,
            "totals": [
                "requests": totals.requests, "cost": totalCost,
                "input": totals.input, "output": totals.output, "tokens": totals.input + totals.output,
                "cacheWrite": totals.cacheCreation, "cacheRead": totals.cacheRead,
                "cacheTokens": totals.cacheCreation + totals.cacheRead,
            ],
            "days": dayKeys.map { String($0.suffix(5)) },
            "series": series,
        ]
    }

    /// 解析单文件 → [天: [模型: Bucket]]。
    private static func parseFile(_ path: String) -> [String: [String: Bucket]] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: [String: Bucket]] = [:]
        for line in content.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (o["type"] as? String) == "assistant",
                  let msg = o["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { continue }
            let model = (msg["model"] as? String) ?? "unknown"
            if model == "<synthetic>" { continue }
            let ts = (o["timestamp"] as? String) ?? ""
            let day = ts.count >= 10 ? String(ts.prefix(10)) : "unknown"
            var b = out[day, default: [:]][model] ?? Bucket()
            b.input += usage["input_tokens"] as? Int ?? 0
            b.output += usage["output_tokens"] as? Int ?? 0
            b.cacheRead += usage["cache_read_input_tokens"] as? Int ?? 0
            b.cacheCreation += usage["cache_creation_input_tokens"] as? Int ?? 0
            b.requests += 1
            out[day, default: [:]][model] = b
        }
        return out
    }
}
