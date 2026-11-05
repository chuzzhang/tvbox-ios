import Foundation

/// drpy / hipy 站点支持。
///
/// 这类站点的 `api` 指向的是**框架库**（`.../dr_py/libs/drpy.min.js`），
/// 真正的规则在 `ext` 里（`./json/xxx.json` 或 `./js/xxx.js`）。
/// 把库当站点脚本来跑是跑不出内容的：库只提供 pdfh/html/drpy 等工具函数，
/// 没有 homeContent。正确做法是拿 ext 的规则，交给内置解释器执行。
enum Drpy {

    struct Result {
        var scripts: [String]
        var source: String
        var note: String
    }

    /// api 是不是 drpy 系框架库
    static func isFramework(_ api: String) -> Bool {
        let l = api.lowercased()
        guard l.contains(".js") || l.hasSuffix("js") else { return false }
        return l.contains("drpy") || l.contains("dr_py") || l.contains("hipy") || l.contains("dr_py_")
    }

    /// 文本是不是 drpy 规则 JSON（不是随便一个 JSON 都算）
    static func looksLikeRule(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{") else { return false }
        let keys = ["规则", "\"一级\"", "\"二级\"", "\"首页\"", "\"分类url\"", "一级", "搜索url"]
        for k in keys where t.contains(k) { return true }
        return false
    }

    /// ext 取文本：可能是内联 JSON，也可能是相对/绝对 URL
    static func extText(_ ext: JSONAny?) -> String {
        guard let ext else { return "" }
        switch ext {
        case .string(let s):
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case .object, .array:
            if let d = try? JSONEncoder().encode(ext), let s = String(data: d, encoding: .utf8) {
                return s
            }
            return ""
        case .int(let i): return String(i)
        default: return ""
        }
    }

    /// 从规则里找站点 host：优先 host/首页，其次分类模板的域名
    static func hostFromRule(_ json: [String: Any]?) -> String {
        guard let json else { return "" }
        var rules: [String: Any] = json
        if let inner = json["规则"] as? [String: Any] { rules = inner }
        else if let inner = json["rule"] as? [String: Any] { rules = inner }

        for k in ["host", "域名", "首页", "home", "homeUrl", "网址", "站点", "分类url", "url"] {
            if let v = rules[k] as? String, v.lowercased().hasPrefix("http") {
                let o = URLKit.origin(v)
                if !o.isEmpty { return o }
            }
        }
        return ""
    }

    /// 组装 drpy 站点的执行脚本。
    /// - Returns: nil 表示这份 ext 不足以驱动站点
    static func load(site: Site,
                     apiURL: String,
                     base: String?) async -> (result: Result?, notes: [String]) {

        var notes: [String] = []
        var extBody = extText(site.ext)
        guard !extBody.isEmpty else {
            notes.append("drpy 站点没有 ext（规则文件），无法驱动")
            return (nil, notes)
        }

        var extURL = ""
        var ruleJSON: [String: Any]? = nil

        // ext 是地址：拉下来
        if URLKit.looksLikeURL(extBody) && !extBody.hasPrefix("{") {
            extURL = URLKit.resolve(extBody, base: base)
            notes.append("ext 规则：\(extURL)")
            do {
                let got = try await Net.shared.fetchScriptTracked(extURL)
                let data = got.data
                if let m = got.mirror { notes.append("ext 改用镜像：\(m)") }
                if let s = String(data: data, encoding: .utf8) {
                    extBody = s
                } else {
                    let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
                    extBody = String(data: data, encoding: String.Encoding(rawValue: gb)) ?? ""
                }
            } catch {
                notes.append("ext 规则下载失败：\(error.localizedDescription)")
                notes.append("这条是上游问题：规则文件在服务器上已经取不到（401/404），客户端拿不到规则就组不出脚本")
                return (nil, notes)
            }
        }

        let trimmed = extBody.trimmingCharacters(in: .whitespacesAndNewlines)

        // 内置解释器（最后一段，只补原库缺的函数）
        guard let lite = bundled() else {
            notes.append("内置 drpy 解释器缺失（Resources/drpy_lite.js）")
            return (nil, notes)
        }

        // 官方 drpy.min.js 能下到就用它：它是完整引擎，比内置解释器覆盖得多。
        // 下不到（401 / 404）不影响，内置解释器接管。
        var libScript: String? = nil
        if apiURL.lowercased().hasPrefix("http"), apiURL.lowercased().contains(".js") {
            if let got = try? await Net.shared.fetchScriptTracked(apiURL),
               let text = String(data: got.data, encoding: .utf8), text.count > 2048 {
                libScript = text
                let where_ = got.mirror == nil ? "原始地址" : "镜像"
                notes.append("已加载 drpy 官方库 \(text.count / 1024) KB（\(where_)）")
            } else {
                notes.append("drpy 官方库没下到（401/404），用内置解释器执行规则")
            }
        }

        // ext 是 js 规则：规则写在 js 里，通常还依赖 cat 系的工具函数
        if !trimmed.hasPrefix("{") {
            let jsLike = trimmed.contains("homeContent")
                || trimmed.contains("var rule") || trimmed.contains("const rule") || trimmed.contains("let rule")
                || trimmed.contains("class_name") || trimmed.contains("function range(")
                || trimmed.hasPrefix("rule") || trimmed.contains("rule={") || trimmed.contains("rule = {")
            if jsLike {
                var scripts: [String] = []
                if let libScript { scripts.append(libScript) }
                scripts.append(trimmed)
                // js 规则只给规则对象，homeContent/categoryContent 由解释器按规则生成
                scripts.append(lite)
                notes.append("ext 是 js 规则（\(trimmed.count / 1024) KB），解释器接管 4 个入口")
                return (Result(scripts: scripts, source: "drpy:ext.js", note: "ext.js"), notes)
            }
            notes.append("ext 既不是 JSON 规则也不是 js（前 60 字：\(trimmed.prefix(60))）")
            return (nil, notes)
        }

        // ext 是 JSON 规则
        let cleaned = Net.sanitize(trimmed)
        if let d = cleaned.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            ruleJSON = obj
        } else if let d = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            ruleJSON = obj
        }

        guard looksLikeRule(cleaned) else {
            notes.append("ext 是 JSON 但不像 drpy 规则（缺 规则/一级/首页 字段）")
            return (nil, notes)
        }

        // host：规则里没有就用 ext 的域名；ext 是内联的，退回 api 的域名
        var host = hostFromRule(ruleJSON)
        if host.isEmpty { host = URLKit.origin(extURL) }
        if host.isEmpty { host = URLKit.origin(apiURL) }
        notes.append("drpy 站点 host：\(host.isEmpty ? "（未识别）" : host)")

        // 规则文本直接嵌进 JS：先尝试规范化成标准 JSON，失败就用清洗后的原文
        var ruleLiteral = cleaned
        if let ruleJSON,
           let d = try? JSONSerialization.data(withJSONObject: ruleJSON, options: []),
           let s = String(data: d, encoding: .utf8) {
            ruleLiteral = s
        }

        let prelude = "var __drpy_rule__ = \(ruleLiteral);\n"
            + "var __drpy_host__ = \(jsString(host));\n"

        var scripts: [String] = [prelude]
        if let libScript { scripts.append(libScript) }
        scripts.append(lite)

        var ruleDict: [String: Any] = ruleJSON ?? [:]
        if let inner = ruleDict["规则"] as? [String: Any] { ruleDict = inner }
        let keys = ruleDict.keys.sorted()
        notes.append("规则字段：" + keys.prefix(12).joined(separator: ", "))

        return (Result(scripts: scripts,
                       source: "drpy 规则（\(keys.count) 个字段）",
                       note: "drpy_lite"), notes)
    }

    static func bundled() -> String? {
        guard let u = Bundle.main.url(forResource: "drpy_lite", withExtension: "js") else { return nil }
        return try? String(contentsOf: u, encoding: .utf8)
    }

    static func jsString(_ s: String) -> String {
        let d = try? JSONSerialization.data(withJSONObject: [s])
        let arr = d.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }
}
