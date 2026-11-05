import Foundation
import JavaScriptCore
import SwiftSoup

/// TVBox / catvod JS 引擎桥：在 iOS 上用 JavaScriptCore 跑 spider 脚本。
///
/// 提供给 JS 的原生函数：request / joinUrl / pdfh / pdfa / log
/// 注入给 JS 的全局量：key、__key__、ext、__ext__、pwd、host
///
/// `key` 是分派用的：顶层 spider 往往是一个大脚本，里面按站点的 key
/// 选对应规则（`eval(key)` / `ruleMap[key]`），不注入就找不到规则。
final class JSSpider {

    /// 闭包要写日志，但不能在 init 里过早捕获 self，用这个盒子过渡
    private final class LogBox {
        var lines: [String] = []
    }

    /// 脚本里的 request() 是同步的（信号量等 HTTP 返回），直接在 UI 线程跑会卡住整个界面。
    /// 同一份 JSContext 又不能被并发访问，所以统一放到一条串行队列上。
    static let jsQueue = DispatchQueue(label: "osc.tvbox.jspider", qos: .userInitiated)

    private let ctx: JSContext
    private let box = LogBox()
    private let siteKey: String
    private(set) var ruleTitle: String
    private var rule: JSValue? = nil

    /// 站点脚本自身的错误（公共库的告警不算）
    var errorText: String? {
        box.lines.last { !$0.hasPrefix("[公共库]") }
    }
    var allErrors: [String] { box.lines }

    init?(site: Site, lib: String?, scripts: [String]) {
        guard let context = JSContext() else { return nil }
        // 先把所有存储属性落定，再让闭包捕获局部引用
        self.ruleTitle = site.name
        self.siteKey = site.key
        self.ctx = context

        let b = box
        context.exceptionHandler = { _, exc in
            var msg = "JS 异常"
            if let e = exc, !e.isUndefined, let s = e.toString(), !s.isEmpty { msg = s }
            b.lines.append(msg)
        }

        installBridges()
        injectGlobals(site: site)

        // cat.js 这类公共库先跑；它的告警不该算成站点不可用
        if let lib, !lib.isEmpty {
            let before = b.lines.count
            context.evaluateScript(lib)
            if b.lines.count > before {
                for i in before..<b.lines.count {
                    b.lines[i] = "[公共库] " + b.lines[i]
                }
            }
        }

        for (i, code) in scripts.enumerated() where !code.isEmpty {
            let before = b.lines.count
            context.evaluateScript(code)
            if b.lines.count > before {
                b.lines.append("[第 \(i + 1) 段脚本执行期间报错，继续加载后续脚本]")
            }
        }

        if let r = context.objectForKeyedSubscript("rule"), !r.isUndefined, !r.isNull {
            rule = r
            if let t = r.objectForKeyedSubscript("title")?.toString(), !t.isEmpty {
                ruleTitle = t
            }
            if let initFn = context.objectForKeyedSubscript("init"), !initFn.isUndefined {
                initFn.call(withArguments: [r])
            }
        }
    }

    // MARK: - 对外接口

    func home() -> [VCategory] {
        var out: [VCategory] = []

        if let fn = ctx.objectForKeyedSubscript("homeContent"), !fn.isUndefined {
            let r = fn.call(withArguments: [emptyObj])
            if let dict = jsonDict(r), let arr = dict["class"] as? [[String: Any]] {
                out = arr.compactMap { d in
                    guard let tid = str(d["type_id"]), let name = str(d["type_name"]) else { return nil }
                    return VCategory(type_id: tid, type_name: name)
                }
            }
        }

        // 老接口 home() + rule.class_parse
        if out.isEmpty, let fn = ctx.objectForKeyedSubscript("home"), !fn.isUndefined {
            let r = fn.call(withArguments: [])
            if let dict = jsonDict(r), let arr = dict["class"] as? [[String: Any]] {
                out = arr.compactMap { d in
                    guard let tid = str(d["type_id"]), let name = str(d["type_name"]) else { return nil }
                    return VCategory(type_id: tid, type_name: name)
                }
            }
        }

        // 都没有：按 rule.class_parse 抓分类页，很多 cat 系脚本只写了 rule
        if out.isEmpty { out = classesFromRule() }
        return out
    }

    func category(tid: String, page: Int) -> (items: [VItem], pageCount: Int) {
        if let fn = ctx.objectForKeyedSubscript("categoryContent"), !fn.isUndefined {
            let r = fn.call(withArguments: [tid, page, false, emptyObj])
            if let dict = jsonDict(r) {
                let items = parseItems(dict["list"])
                if !items.isEmpty {
                    let pc = (dict["pagecount"] as? NSNumber)?.intValue ?? (page + 1)
                    return (items, max(pc, page))
                }
            }
        }
        return categoryFromRule(tid: tid, page: page)
    }

    func detail(id: String) -> VDetail? {
        guard let fn = ctx.objectForKeyedSubscript("detailContent"), !fn.isUndefined else { return nil }
        let r = fn.call(withArguments: [[id]])
        guard let dict = jsonDict(r), let list = dict["list"] as? [[String: Any]], let first = list.first else { return nil }
        return parseDetail(first)
    }

    func search(key: String, page: Int = 1) -> [VItem] {
        if let fn = ctx.objectForKeyedSubscript("searchContent"), !fn.isUndefined {
            let r = fn.call(withArguments: [key, true, page])
            if let dict = jsonDict(r) {
                let items = parseItems(dict["list"])
                if !items.isEmpty { return items }
            }
        }
        return searchFromRule(key: key, page: page)
    }

    /// 加载结果摘要，用于界面诊断
    var loadSummary: String {
        var names: [String] = []
        for k in ["homeContent", "home", "categoryContent", "detailContent", "searchContent", "init", "rule"] {
            if let v = ctx.objectForKeyedSubscript(k), !v.isUndefined, !v.isNull { names.append(k) }
        }
        var s = "脚本已定义：" + (names.isEmpty ? "（无）" : names.joined(separator: ", "))
        if let rule {
            var fields: [String] = []
            for k in ["title", "host", "url", "searchUrl", "detailUrl", "class_parse", "class_url"] {
                if let v = rule.objectForKeyedSubscript(k)?.toString(), !v.isEmpty, v != "undefined" {
                    fields.append("\(k)=\(v.count > 70 ? String(v.prefix(70)) + "…" : v)")
                }
            }
            if !fields.isEmpty { s += "\nrule：" + fields.joined(separator: " · ") }
        }
        return s
    }

    // MARK: - rule 兜底（只写了 rule 没写函数的脚本）

    private func classesFromRule() -> [VCategory] {
        guard let rule else { return [] }
        guard let cp = rule.objectForKeyedSubscript("class_parse")?.toString(),
              !cp.isEmpty, cp != "undefined" else { return [] }

        var pageURL = ""
        for k in ["class_url", "homeUrl", "host"] {
            if let v = rule.objectForKeyedSubscript(k)?.toString(),
               !v.isEmpty, v.lowercased().hasPrefix("http") {
                pageURL = v
                break
            }
        }
        guard !pageURL.isEmpty else { return [] }

        let html = Self.syncGet(pageURL, headers: ruleHeaders())
        guard !html.isEmpty else { return [] }
        guard let spec = Self.parseRuleSpec(cp, isList: false) else { return [] }

        var out: [VCategory] = []
        var seen = Set<String>()
        for row in Self.rows(in: html, spec: spec) {
            guard !row.link.isEmpty, !seen.contains(row.link) else { continue }
            seen.insert(row.link)
            out.append(VCategory(type_id: row.link, type_name: row.title.isEmpty ? row.link : row.title))
        }
        return out
    }

    private func categoryFromRule(tid: String, page: Int) -> (items: [VItem], pageCount: Int) {
        guard let rule else { return ([], 1) }
        guard let tpl = rule.objectForKeyedSubscript("url")?.toString(),
              !tpl.isEmpty, tpl != "undefined" else { return ([], 1) }
        guard let listSpec = firstString(rule, ["列表", "list_parse", "list"]) else { return ([], 1) }
        guard let spec = Self.parseRuleSpec(listSpec, isList: true) else { return ([], 1) }

        let url = buildURL(tpl, tid: tid, page: page)
        guard !url.isEmpty else { return ([], 1) }

        let html = Self.syncGet(url, headers: ruleHeaders())
        guard !html.isEmpty else { return ([], 1) }

        var items: [VItem] = []
        for row in Self.rows(in: html, spec: spec) {
            guard !row.link.isEmpty, !row.title.isEmpty else { continue }
            items.append(VItem(vod_id: row.link, vod_name: row.title, vod_pic: row.pic, vod_remarks: nil))
        }
        // 规则里没有可靠的总页数字段，只要能翻到内容就让上层继续翻，翻空自停
        return (items, items.isEmpty ? page : page + 1)
    }

    private func searchFromRule(key: String, page: Int) -> [VItem] {
        guard let rule else { return [] }
        guard let tpl = rule.objectForKeyedSubscript("searchUrl")?.toString(),
              !tpl.isEmpty, tpl != "undefined" else { return [] }
        guard let listSpec = firstString(rule, ["列表", "list_parse", "list"]) else { return [] }
        guard let spec = Self.parseRuleSpec(listSpec, isList: true) else { return [] }

        var url = tpl.replacingOccurrences(of: "**", with: key)
            .replacingOccurrences(of: "fypage", with: "\(page)")
            .replacingOccurrences(of: "fyword", with: key)
        url = absolute(url)
        guard !url.isEmpty else { return [] }

        let html = Self.syncGet(url, headers: ruleHeaders())
        guard !html.isEmpty else { return [] }
        return Self.rows(in: html, spec: spec).compactMap { row in
            guard !row.link.isEmpty, !row.title.isEmpty else { return nil }
            return VItem(vod_id: row.link, vod_name: row.title, vod_pic: row.pic, vod_remarks: nil)
        }
    }

    private func firstString(_ rule: JSValue, _ keys: [String]) -> String? {
        for k in keys {
            if let v = rule.objectForKeyedSubscript(k)?.toString(), !v.isEmpty, v != "undefined" {
                return v
            }
        }
        return nil
    }

    private func ruleHeaders() -> [String: String] {
        guard let rule else { return [:] }
        guard let h = rule.objectForKeyedSubscript("headers"), !h.isUndefined,
              let d = h.toObject() as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in d { out[k] = "\(v)" }
        return out
    }

    private func buildURL(_ tpl: String, tid: String, page: Int) -> String {
        var s = tpl
            .replacingOccurrences(of: "fyclass", with: tid)
            .replacingOccurrences(of: "fypage", with: "\(page)")
            .replacingOccurrences(of: "**", with: tid)
        s = absolute(s)
        return s
    }

    /// rule 里的地址可能是相对路径，补上 host
    private func absolute(_ s: String) -> String {
        if s.lowercased().hasPrefix("http") { return s }
        guard let rule, let host = rule.objectForKeyedSubscript("host")?.toString(),
              host.lowercased().hasPrefix("http") else { return s }
        if s.hasPrefix("/") { return host + s }
        return host + "/" + s
    }

    // MARK: - rule 选择器

    struct Row {
        var title: String = ""
        var link: String = ""
        var pic: String?
    }

    struct RuleSpec {
        var parent: String
        var title: String
        var link: String
        var pic: String?
    }

    /// 分隔符是分号；分类规则的第三段常是 `a&&href`，列表规则第四段是图片
    static func parseRuleSpec(_ raw: String, isList: Bool) -> RuleSpec? {
        let parts = raw.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let parent = parts.first, !parent.isEmpty else { return nil }
        let title = parts.count > 1 && !parts[1].isEmpty ? parts[1] : "a&&Text"
        let link = parts.count > 2 && !parts[2].isEmpty ? parts[2] : "a&&href"
        let pic = parts.count > 3 && !parts[3].isEmpty ? parts[3] : (isList ? "img&&data-original" : nil)
        return RuleSpec(parent: parent, title: title, link: link, pic: pic)
    }

    static func rows(in html: String, spec: RuleSpec) -> [Row] {
        guard let doc = try? SwiftSoup.parse(html) else { return [] }
        guard let els = try? doc.select(spec.parent) else { return [] }

        var out: [Row] = []
        for el in els {
            var r = Row()
            r.title = queryH(el, spec.title)
            r.link = queryH(el, spec.link)
            if let p = spec.pic {
                let v = queryH(el, p)
                if !v.isEmpty { r.pic = v }
            }
            if r.link.isEmpty { r.link = queryH(el, "a&&href") }
            if r.title.isEmpty { r.title = queryH(el, "Text") }
            if !r.title.isEmpty { out.append(r) }
        }
        return out
    }

    // MARK: - 解析

    private func parseItems(_ any: Any?) -> [VItem] {
        guard let arr = any as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let id = str(d["vod_id"]), let name = str(d["vod_name"]) else { return nil }
            return VItem(vod_id: id, vod_name: name, vod_pic: str(d["vod_pic"]), vod_remarks: str(d["vod_remarks"]))
        }
    }

    private func parseDetail(_ d: [String: Any]) -> VDetail? {
        guard let id = str(d["vod_id"]), let name = str(d["vod_name"]) else { return nil }
        return VDetail(vod_id: id, vod_name: name,
                       vod_pic: str(d["vod_pic"]),
                       vod_content: str(d["vod_content"]) ?? str(d["vod_blurb"]),
                       vod_remarks: str(d["vod_remarks"]),
                       vod_year: str(d["vod_year"]),
                       vod_area: str(d["vod_area"]),
                       vod_actor: str(d["vod_actor"]),
                       vod_director: str(d["vod_director"]),
                       type_name: str(d["type_name"]),
                       vod_play_from: str(d["vod_play_from"]),
                       vod_play_url: str(d["vod_play_url"]))
    }

    private func str(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private func jsonDict(_ v: JSValue?) -> [String: Any]? {
        guard let v, !v.isUndefined, !v.isNull, v.isObject else { return nil }
        // 脚本返回对象时 toString 就是 JSON；返回数组时套一层没意义，交给 toObject
        if let s = v.toString(), s.hasPrefix("{"), let d = s.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            return o
        }
        if let o = v.toObject() as? [String: Any] { return o }
        return nil
    }

    private var emptyObj: JSValue {
        if let o = JSValue(newObjectIn: ctx) { return o }
        return ctx.evaluateScript("({})")
    }

    private func jsLiteral(_ s: String) -> String {
        let d = try? JSONSerialization.data(withJSONObject: [s])
        let arr = d.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    private func injectGlobals(site: Site) {
        var extString = ""
        if case .string(let s)? = site.ext {
            extString = s
        } else if let e = site.ext, let d = try? JSONEncoder().encode(e) {
            extString = String(data: d, encoding: .utf8) ?? ""
        }

        var js = ""
        js += "var key = \(jsLiteral(site.key));"
        js += "var __key__ = key;"
        js += "var pwd = '';"
        js += "var ext = \(jsLiteral(extString));"
        js += "var __ext__ = ext;"
        if let host = Self.firstHost([site.api, extString]) {
            js += "var host = \(jsLiteral(host));"
        }
        ctx.evaluateScript(js)
    }

    static func firstHost(_ candidates: [String]) -> String? {
        for text in candidates where !text.isEmpty {
            guard let r = text.range(of: "https?://[A-Za-z0-9._\\-:]+", options: .regularExpression) else { continue }
            return String(text[r])
        }
        return nil
    }

    // MARK: - 原生桥

    private func installBridges() {
        let ctx = self.ctx

        let request: @convention(block) (String, JSValue?) -> String = { url, opt in
            var headers: [String: String] = [:]
            if let opt, !opt.isUndefined, !opt.isNull,
               let h = opt.objectForKeyedSubscript("headers"), !h.isUndefined, !h.isNull,
               let dict = h.toObject() as? [String: Any] {
                for (k, v) in dict { headers[k] = "\(v)" }
            }
            return Self.syncGet(url, headers: headers)
        }
        ctx.setObject(unsafeBitCast(request, to: AnyObject.self), forKeyedSubscript: "request" as NSString)

        let joinUrl: @convention(block) (String, String) -> String = { base, href in
            guard let b = URL(string: base) else { return href }
            return URL(string: href, relativeTo: b)?.absoluteString ?? href
        }
        ctx.setObject(unsafeBitCast(joinUrl, to: AnyObject.self), forKeyedSubscript: "joinUrl" as NSString)

        let pdfh: @convention(block) (String, String) -> String = { html, sel in
            Self.queryH(html, sel)
        }
        ctx.setObject(unsafeBitCast(pdfh, to: AnyObject.self), forKeyedSubscript: "pdfh" as NSString)

        let pdfa: @convention(block) (String, String) -> AnyObject = { html, sel in
            Self.queryA(html, sel) as NSArray
        }
        ctx.setObject(unsafeBitCast(pdfa, to: AnyObject.self), forKeyedSubscript: "pdfa" as NSString)

        let log: @convention(block) (String) -> Void = { _ in }
        ctx.setObject(unsafeBitCast(log, to: AnyObject.self), forKeyedSubscript: "log" as NSString)
    }

    /// 同步 HTTP，供 JS 直接拿字符串
    static func syncGet(_ urlString: String, headers: [String: String]) -> String {
        guard let url = Net.makeURL(urlString) else { return "" }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(Net.shared.defaultUA, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let sem = DispatchSemaphore(value: 0)
        var result = ""
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: cfg, delegate: TrustAllDelegate(), delegateQueue: nil)
        session.dataTask(with: req) { data, _, _ in
            if let data, !data.isEmpty {
                result = String(data: data, encoding: .utf8) ?? ""
                if result.isEmpty {
                    let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
                    result = String(data: data, encoding: String.Encoding(rawValue: gb)) ?? ""
                }
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 20)
        session.invalidateAndCancel()
        return result
    }

    // MARK: - 选择器

    /// 支持 "div.x&&Text" / "div.x&&href" / "a&&img&&src" 这类链式写法
    static func queryH(_ html: String, _ selector: String) -> String {
        guard let doc = try? SwiftSoup.parse(html) else { return "" }
        var parts = selector.components(separatedBy: "&&").map { $0.trimmingCharacters(in: .whitespaces) }
        parts.removeAll { $0.isEmpty }
        guard let head = parts.first, let el = try? doc.select(head).first() else { return "" }
        let rest = parts.dropFirst().joined(separator: "&&")
        if rest.isEmpty { return (try? el.text()) ?? "" }
        return queryH(el, rest)
    }

    static func queryH(_ el: Element, _ selector: String) -> String {
        var parts = selector.components(separatedBy: "&&").map { $0.trimmingCharacters(in: .whitespaces) }
        parts.removeAll { $0.isEmpty }
        guard !parts.isEmpty else { return "" }

        var mode = "Text"
        if let last = parts.last, ["Text", "Html", "OuterHtml"].contains(last) || isAttrLike(last) {
            mode = last
            parts.removeLast()
        }

        var cur = el
        for css in parts {
            guard let next = try? cur.select(css).first() else { return "" }
            cur = next
        }
        switch mode {
        case "Text": return (try? cur.text()) ?? ""
        case "Html": return (try? cur.html()) ?? ""
        case "OuterHtml": return (try? cur.outerHtml()) ?? ""
        default: return (try? cur.attr(mode)) ?? ""
        }
    }

    static func queryA(_ html: String, _ selector: String) -> [String] {
        guard let doc = try? SwiftSoup.parse(html) else { return [] }
        var parts = selector.components(separatedBy: "&&").map { $0.trimmingCharacters(in: .whitespaces) }
        parts.removeAll { $0.isEmpty }
        guard let head = parts.first, let els = try? doc.select(head) else { return [] }
        let rest = parts.dropFirst().joined(separator: "&&")
        if rest.isEmpty { return els.map { (try? $0.outerHtml()) ?? "" } }
        return els.map { queryH($0, rest) }
    }

    private static let htmlTags: Set<String> = [
        "a", "div", "span", "img", "ul", "ol", "li", "p", "em", "i", "b", "strong", "font",
        "td", "th", "tr", "table", "section", "article", "body", "html", "option", "dd", "dt",
        "dl", "video", "source", "iframe", "br", "hr", "input", "textarea", "small", "time",
        "nav", "header", "footer", "main", "aside", "h1", "h2", "h3", "h4", "h5", "h6", "label"
    ]

    static func isAttrLike(_ s: String) -> Bool {
        guard !s.isEmpty, s.count < 24 else { return false }
        guard !htmlTags.contains(s.lowercased()) else { return false }
        guard !s.contains(" ") && !s.contains(".") && !s.contains("#") && !s.contains(">") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_:")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

// MARK: - 执行队列
extension JSSpider {

    static func run<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            jsQueue.async { cont.resume(returning: body()) }
        }
    }
}
