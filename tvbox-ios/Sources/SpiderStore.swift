import Foundation
import ZIPFoundation

/// 配置顶层 `spider` 字段的加载器。
///
/// TVBox 的约定：
/// - `spider` 指向一个 jar，站点的 api 写成 `csp_xxx`，由 jar 里同名类分派；
/// - 或者指向一个 js，站点 api 也是 `csp_xxx`，由脚本里的 `rule` / `eval(key)` 分派。
///
/// 地址后面常带校验后缀（`;md5;xxx`、`;pk;xxx`），不剥掉直接请求会 404。
/// jar 内若是纯 dex，iOS 没有 ART 无法执行 —— 这种情况要能明确说出来，
/// 而不是给一句“脚本不可用”。
final class SpiderStore {

    static let shared = SpiderStore()

    struct Loaded {
        var scripts: [String]
        var source: String
    }

    struct Report {
        var ok: Bool
        var raw: String
        var url: String
        var message: String
        var scripts: [String] = []
        var source: String = ""
        /// jar 内的文件清单（截断），排查时很有用
        var entries: [String] = []
        var jsNames: [String] = []

        var bundle: Loaded? {
            ok && !scripts.isEmpty ? Loaded(scripts: scripts, source: source) : nil
        }

        var summary: String {
            if ok {
                return "顶层 spider 已加载：\(source)"
            }
            return "顶层 spider 不可用：\(message)"
        }

        static func failure(_ raw: String, _ msg: String) -> Report {
            Report(ok: false, raw: raw, url: "", message: msg)
        }
    }

    // MARK: - 缓存（同一份 spider 只下载一次）

    private let lock = NSLock()
    private var cache: [String: Report] = [:]
    private var inflight: [String: Task<Report, Never>] = [:]

    func report(for raw: String?) async -> Report {
        let rawText = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            return .failure("", "配置里没有 spider 字段（纯 CMS 配置可以忽略这条）")
        }
        let url = Self.stripSuffix(rawText)

        lock.lock()
        if let hit = cache[url] {
            lock.unlock()
            return hit
        }
        if let running = inflight[url] {
            lock.unlock()
            return await running.value
        }
        let task = Task<Report, Never> { await Self.build(url: url, raw: rawText) }
        inflight[url] = task
        lock.unlock()

        let result = await task.value
        lock.lock()
        cache[url] = result
        inflight[url] = nil
        lock.unlock()
        return result
    }

    // MARK: - 后缀剥离

    /// TVBox 支持 `url;md5;hash` / `url;pk;key;cipher;aes` 这类写法，
    /// 只截到第一个已知标记，避免误伤正常 URL 里的分号。
    static func stripSuffix(_ s: String) -> String {
        let marks = [";md5;", ";pk;", ";json;", ";base64;", ";zip;", ";utf-8;", ";gbk;", ";aes;", ";jar;"]
        var cut: String.Index? = nil
        for m in marks {
            guard let r = s.range(of: m, options: .caseInsensitive) else { continue }
            if cut == nil || r.lowerBound < cut! { cut = r.lowerBound }
        }
        guard let c = cut else { return s }
        return String(s[s.startIndex..<c])
    }

    // MARK: - 加载

    private static func build(url: String, raw: String) async -> Report {
        var rep = Report(ok: false, raw: raw, url: url, message: "")

        // 内联 base64（部分配置生成器会把 jar 直接塞进字段）
        if !url.lowercased().hasPrefix("http") {
            if let data = Data(base64Encoded: url, options: .ignoreUnknownCharacters), data.count > 64 {
                return unpack(data, source: "spider(base64)", into: rep)
            }
            return Report(ok: false, raw: raw, url: url,
                          message: "spider 不是 http 地址：\(url.prefix(80))")
        }

        do {
            // js 直链：直接抓文本
            if url.lowercased().contains(".js") {
                let text = try await Net.shared.fetchText(url)
                guard !text.isEmpty else {
                    return Report(ok: false, raw: raw, url: url, message: "spider.js 是空文件")
                }
                rep.ok = true
                rep.scripts = [text]
                rep.source = "spider.js，\(text.count / 1024) KB"
                rep.jsNames = [url]
                return rep
            }

            let data = try await Net.shared.fetch(url, timeout: 40, retry: 2)
            return unpack(data, source: "spider 包", into: rep)
        } catch {
            return Report(ok: false, raw: raw, url: url,
                          message: "下载失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 解包

    struct Extract {
        var scripts: [String] = []
        var jsNames: [String] = []
        var entries: [String] = []
    }

    /// 从 jar/zip 里抽 js。`preferKey` 命中的文件名优先（多 js 的包里按站点 key 挑）
    static func extract(_ data: Data, preferKey: String? = nil) -> Extract {
        var out = Extract()
        guard let archive = try? Archive(data: data, accessMode: .read) else {
            return out
        }

        var found: [(name: String, text: String, score: Int)] = []
        let want = normalizeKey(preferKey)

        for entry in archive where entry.type == .file {
            out.entries.append(entry.path)
            guard entry.path.lowercased().hasSuffix(".js") else { continue }
            guard entry.uncompressedSize > 0, entry.uncompressedSize < 16 * 1024 * 1024 else { continue }
            var buf = Data()
            guard (try? archive.extract(entry) { buf.append($0) }) != nil else { continue }
            guard let text = String(data: buf, encoding: .utf8), !text.isEmpty else { continue }

            var sc = score(text)
            if !want.isEmpty, normalizeKey(entry.path).contains(want) { sc += 100 }
            found.append((entry.path, text, sc))
        }

        // 同分取体积大的：通常是主实现而不是 polyfill
        let ordered = found.sorted { a, b in
            a.score == b.score ? a.text.count > b.text.count : a.score > b.score
        }
        out.scripts = ordered.map { $0.text }
        out.jsNames = ordered.map { $0.name }
        return out
    }

    private static func unpack(_ data: Data, source: String, into rep: Report) -> Report {
        var rep = rep
        let ex = extract(data)

        if ex.entries.isEmpty {
            // 解不开压缩包：可能是改了扩展名的纯 js
            if let text = String(data: data, encoding: .utf8),
               text.count > 200,
               text.contains("homeContent") || text.contains("var rule") || text.contains("function") {
                rep.ok = true
                rep.scripts = [text]
                rep.source = "\(source)（按纯文本 js 处理）"
                return rep
            }
            rep.message = "\(source) 既不是压缩包也不是 js（\(data.count) 字节）"
            return rep
        }

        rep.entries = Array(ex.entries.prefix(60))
        rep.jsNames = ex.jsNames

        guard !ex.scripts.isEmpty else {
            let dex = ex.entries.filter { $0.lowercased().hasSuffix(".dex") }.count
            rep.message = "\(source) 里共 \(ex.entries.count) 个文件，没有 js；"
                + "其中 \(dex) 个 dex 字节码 —— dex 要 Android ART 才能执行，iOS 加载不了"
            return rep
        }

        rep.ok = true
        rep.scripts = ex.scripts
        rep.source = "\(source) 内 js：\(ex.jsNames.prefix(3).joined(separator: ", "))"
        return rep
    }

    private static func score(_ text: String) -> Int {
        var s = 0
        for k in ["homeContent", "categoryContent", "detailContent", "searchContent", "var rule", "class_parse"] {
            if text.contains(k) { s += 1 }
        }
        if text.count > 200_000 { s += 1 }
        return s
    }

    /// `csp_abc` / `abc` 都归一到 `abc`，用于文件名匹配
    private static func normalizeKey(_ k: String?) -> String {
        guard var s = k?.lowercased().trimmingCharacters(in: .whitespaces), !s.isEmpty else { return "" }
        for p in ["csp_", "js_", "web_"] where s.hasPrefix(p) {
            s = String(s.dropFirst(p.count))
        }
        return s
    }
}
