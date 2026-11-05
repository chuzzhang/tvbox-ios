import Foundation

/// 配置里的地址解析。
///
/// TVBox 配置大量使用相对路径（`./jar/top98_1.jar`、`./json/xxx.json`），
/// 相对的对象是**配置文件的 URL**，不是站点的 api。
/// 不解析成绝对地址，请求就会打到 app 沙盒里，表现为 "spider 不是 http 地址"。
enum URLKit {

    /// 配置 URL 去掉最后一段，得到用来做相对解析的基准地址
    static func base(_ configURL: String) -> String {
        let s = configURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: s), u.scheme != nil else { return "" }
        var comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
        comps?.query = nil
        comps?.fragment = nil
        guard var path = comps?.path, !path.isEmpty else { return s }
        if let i = path.lastIndex(of: "/") {
            path = String(path[path.startIndex..<i])
        }
        comps?.path = path.isEmpty ? "/" : path
        return comps?.string ?? ""
    }

    /// 把 `./x`、`../x`、`/x`、`//host/x` 统一解析成绝对地址。
    /// 已经是绝对地址的原样返回；没有基准地址时原样返回（交给调用方判断）。
    static func resolve(_ raw: String?, base: String?) -> String {
        var s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        // 单个 # 是 TVBox 里表示"空"的写法
        if s == "#" { return "" }
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return s }
        if s.hasPrefix("//") {
            let scheme = (base?.lowercased().hasPrefix("http://") ?? false) ? "http:" : "https:"
            return scheme + s
        }
        guard let base, !base.trimmingCharacters(in: .whitespaces).isEmpty,
              let b = URL(string: base) else { return s }

        // 去掉前导 ./，URL(relativeTo:) 对 "./" 也能处理，但手工处理更稳
        while s.hasPrefix("./") { s = String(s.dropFirst(2)) }
        if let u = URL(string: s, relativeTo: b)?.absoluteURL.absoluteString, u.lowercased().hasPrefix("http") {
            return u
        }
        // 中文文件名会让 URL(string:) 返回 nil，退回手工拼接
        // （编码交给 Net.makeURL，那里只在前者解析失败时才编码，不会二次编码）
        let dir = base.hasSuffix("/") ? String(base.dropLast()) : base
        return s.hasPrefix("/") ? dir + s : dir + "/" + s
    }

    /// 取 origin，用于 Referer —— 一堆源站只校验 Referer 的来源域
    static func origin(_ url: String) -> String {
        guard let u = URL(string: url), let scheme = u.scheme, let host = u.host else { return "" }
        if let port = u.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    /// 判断是不是"看起来像地址"，用于区分内联 JSON 和 URL
    static func looksLikeURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return true }
        if t.hasPrefix("./") || t.hasPrefix("../") || t.hasPrefix("/") { return true }
        // 配置文件里常见只写文件名
        return t.hasSuffix(".json") || t.hasSuffix(".js") || t.hasSuffix(".jar")
            || t.hasSuffix(".txt") || t.hasSuffix(".zip")
    }
}
