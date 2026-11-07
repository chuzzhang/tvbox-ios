import Foundation
import JavaScriptCore
import SwiftSoup
import CommonCrypto

/// 原生 HTTP 的结果备注，按地址存。
///
/// 空字符串是「请求成功」还是「拿到 403 错误页」在 JS 里看不出区别，
/// 把原因记在这里，drpy 解释器就能在日志里写「HTTP 502（源站上游不可用）」
/// 而不是只有一句「0 字符」。
final class HTTPNote: @unchecked Sendable {
    static let shared = HTTPNote()

    private let lock = NSLock()
    private var map: [String: String] = [:]

    func set(_ url: String, _ note: String) {
        lock.lock()
        if note.isEmpty { map.removeValue(forKey: url) } else { map[url] = note }
        lock.unlock()
    }

    func get(_ url: String) -> String {
        lock.lock()
        let v = map[url] ?? ""
        lock.unlock()
        return v
    }

    func clear() {
        lock.lock()
        map.removeAll()
        lock.unlock()
    }
}

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
    /// home() 里给的筛选器默认值，按分类存：tid -> { sort: "update", … }。
    /// 新版 js 脚本直接把它拼进 URL（`${baseUrl}${tid}/${sort}/${pg}/`），
    /// extend 传空对象的话 sort 是空串，URL 变成 `/theme/64//1/` —— 站点回 404，
    /// 表现就是「分类有、进去 0 条」。TVBox 在 Android 上就是带默认值调的。
    private var filterDefaults: [String: [String: Any]] = [:]

    /// req() 实际打过的站点源（scheme://host[:port]）。
    /// 不能拿配置里 api 的域名：js 站点的 api 在配置服务器上，内容在另一个域名
    /// （xp天堂 的 api 在 clun.top，内容在 dzsx5k…cloudfront.net），拼错就是 404。
    private final class HostBox { var origin = "" }
    private let hostBox = HostBox()

    var lastOrigin: String { hostBox.origin }

    /// 把脚本返回的相对路径（`/videos/xxx/`）拼成绝对地址
    func absoluteURL(_ path: String) -> String? {
        let p = path.trimmingCharacters(in: .whitespaces)
        if p.lowercased().hasPrefix("http") { return p }
        guard p.hasPrefix("/"), !hostBox.origin.isEmpty else { return nil }
        return hostBox.origin + p
    }

    /// 站点脚本自身的错误。
    /// 公共库告警、以及我们自己插的「第 N 段报错」标记都要滤掉 ——
    /// 否则界面上只剩一句没信息量的标记，真正的原因被挡在后面。
    var errorText: String? {
        box.lines.last {
            // 这几种前缀都是我们自己打的：公共库告警、分段标记、兼容层状态、console 输出。
            // 少滤一个，界面上就会把一条普通日志显示成「脚本执行报错」。
            !$0.hasPrefix("[公共库]") && !$0.hasPrefix("[第 ")
                && !$0.hasPrefix("[兼容层") && !$0.hasPrefix("[日志]")
        }
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
            b.lines.append(JSSpider.describeJS(exc))
        }

        installBridges()
        injectGlobals(site: site)

        // 新版 js spider 依赖 cheerio / req / console，JSCore 里一个都没有。
        // 兼容层必须在站点脚本之前跑，否则第 1 行 import 就语法错。
        if let compat = JSSpider.bundledCompat() {
            let before = b.lines.count
            context.evaluateScript(compat)
            if b.lines.count > before {
                b.lines.append("[兼容层 compat.js 执行失败]")
            }
        }

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
            context.evaluateScript(JSSpider.stripESM(code))
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
                _ = unwrap(initFn.call(withArguments: [r]))
            }
        }
    }

    // MARK: - 对外接口

    func home() -> [VCategory] {
        var out: [VCategory] = []

        if let fn = ctx.objectForKeyedSubscript("homeContent"), !fn.isUndefined {
            let r = unwrap(fn.call(withArguments: [emptyObj]))
            if let dict = jsonDict(r) { cacheFilters(dict["filters"]) }
            if let dict = jsonDict(r), let arr = dict["class"] as? [[String: Any]] {
                out = arr.compactMap { d in
                    guard let tid = str(d["type_id"]), let name = str(d["type_name"]) else { return nil }
                    return VCategory(type_id: tid, type_name: name)
                }
            }
        }

        // 老接口 home() + rule.class_parse
        if out.isEmpty, let fn = ctx.objectForKeyedSubscript("home"), !fn.isUndefined {
            let r = unwrap(fn.call(withArguments: []))
            if let dict = jsonDict(r) { cacheFilters(dict["filters"]) }
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
            let r = unwrap(fn.call(withArguments: [tid, page, false, extendFor(tid)]))
            if let dict = jsonDict(r) {
                let items = parseItems(dict["list"])
                if !items.isEmpty {
                    let pc = (dict["pagecount"] as? NSNumber)?.intValue ?? (page + 1)
                    return (items, max(pc, page))
                }
            }
        }
        // 新版接口：category(tid, pg, filter, extend)
        if let fn = ctx.objectForKeyedSubscript("category"), !fn.isUndefined {
            if let dict = jsonDict(unwrap(fn.call(withArguments: [tid, page, false, extendFor(tid)]))) {
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
        if let fn = ctx.objectForKeyedSubscript("detailContent"), !fn.isUndefined {
            if let d = firstDetail(jsonDict(unwrap(fn.call(withArguments: [[id]])))) { return d }
        }
        // 新版接口：detail(id)，id 是字符串（脚本里直接拼到 baseUrl 后面）
        if let fn = ctx.objectForKeyedSubscript("detail"), !fn.isUndefined {
            if let d = firstDetail(jsonDict(unwrap(fn.call(withArguments: [id])))) { return d }
            if let d = firstDetail(jsonDict(unwrap(fn.call(withArguments: [[id]])))) { return d }
        }
        return nil
    }

    private func firstDetail(_ dict: [String: Any]?) -> VDetail? {
        guard let dict, let list = dict["list"] as? [[String: Any]], let first = list.first else { return nil }
        return parseDetail(first)
    }

    func search(key: String, page: Int = 1) -> [VItem] {
        if let fn = ctx.objectForKeyedSubscript("searchContent"), !fn.isUndefined {
            let r = unwrap(fn.call(withArguments: [key, true, page]))
            if let dict = jsonDict(r) {
                let items = parseItems(dict["list"])
                if !items.isEmpty { return items }
            }
        }
        // 新版接口：search(key, quick, page)
        if let fn = ctx.objectForKeyedSubscript("search"), !fn.isUndefined {
            if let dict = jsonDict(unwrap(fn.call(withArguments: [key, true, page]))) {
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
        // 解释器侧记录的请求与分类来源，抓不到分类时靠它定位是请求失败还是选择器没命中
        if let logV = ctx.evaluateScript(
            "(typeof __drpy_log__ !== 'undefined' && __drpy_log__ && __drpy_log__.length) ? __drpy_log__.slice(-10).join('\\n') : ''"),
           !logV.isUndefined, !logV.isNull,
           let t = logV.toString(), !t.isEmpty {
            s += "\n解释器日志：\n" + t
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
        guard let v, !v.isUndefined, !v.isNull else { return nil }
        // 新版 js spider 习惯 `return JSON.stringify({list:[…]})`，拿到的是字符串。
        // 只认 isObject 的话这类脚本永远是「跑起来了但没内容」。
        if v.isString, let s = v.toString(), s.hasPrefix("{"),
           let d = s.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            return o
        }
        guard v.isObject else { return nil }
        // 脚本返回对象时 toString 就是 JSON；返回数组时套一层没意义，交给 toObject
        if let s = v.toString(), s.hasPrefix("{"), let d = s.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            return o
        }
        if let o = v.toObject() as? [String: Any] { return o }
        return nil
    }

    /// 把 home() 给的筛选默认值拼成 extend 对象。没有就用空对象。
    private func extendFor(_ tid: String) -> JSValue {
        let obj = emptyObj
        guard let defaults = filterDefaults[tid], !defaults.isEmpty else { return obj }
        for (k, v) in defaults {
            obj.setObject(v, forKeyedSubscript: k as NSString)
        }
        return obj
    }

    /// filters 形如 { tid: [ {key:"sort", name:"排序", value:[{n:"最近更新", v:"update"}, …]}, … ] }
    /// 取每组第一个 value 当作默认值。
    private func cacheFilters(_ raw: Any?) {
        guard let f = raw as? [String: Any], !f.isEmpty else { return }
        for (tid, v) in f {
            guard let groups = v as? [[String: Any]] else { continue }
            var defaults: [String: Any] = [:]
            for g in groups {
                guard let key = g["key"] as? String,
                      let vals = g["value"] as? [[String: Any]],
                      let first = vals.first,
                      let val = first["v"] else { continue }
                defaults[key] = val
            }
            if !defaults.isEmpty { filterDefaults[tid] = defaults }
        }
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

    // MARK: - 兼容层 / ESM / 异步

    static func bundledCompat() -> String? {
        guard let u = Bundle.main.url(forResource: "compat", withExtension: "js") else { return nil }
        return try? String(contentsOf: u, encoding: .utf8)
    }

    /// 新版站点脚本是 ES Module：`import cheerio from 'assets://…'` + `export default {…}`。
    /// `evaluateScript` 只吃脚本不吃模块，原样 eval 第 1 行就 SyntaxError（
    /// 表现就是「第 1 段脚本执行期间报错」，连站点是谁都看不出来）。
    /// 这里删掉 import（cheerio 由 compat.js 提供全局），export 降级成普通变量。
    static func stripESM(_ src: String) -> String {
        guard src.contains("import ") || src.contains("export ") else { return src }
        var out = src
        let o: String.CompareOptions = [.regularExpression]
        out = out.replacingOccurrences(of: "(?m)^[ \\t]*import[ \\t]+[^;\\n]*;?[ \\t]*$", with: "", options: o)
        out = out.replacingOccurrences(of: "(?m)^[ \\t]*export[ \\t]+default[ \\t]+", with: "var __default_export__ = ", options: o)
        out = out.replacingOccurrences(of: "(?m)^[ \\t]*export[ \\t]+(?=(const|let|var|function|class|async))", with: "", options: o)
        out = out.replacingOccurrences(of: "(?m)^[ \\t]*export[ \\t]*\\{[^}]*\\}[ \\t]*;?[ \\t]*$", with: "", options: o)
        return out
    }

    /// 异常对象转一句能行动的说明：message + 行号 + 来源。
    /// 只打 `e.toString()` 的话，SyntaxError 只会得到 "SyntaxError"，没有行号根本没法查。
    static func describeJS(_ exc: JSValue?) -> String {
        guard let e = exc, !e.isUndefined, !e.isNull else { return "JS 异常（没有异常对象）" }
        var head = ""
        if let m = e.objectForKeyedSubscript("message")?.toString(), !m.isEmpty, m != "undefined" {
            head = m
            if let n = e.objectForKeyedSubscript("name")?.toString(), !n.isEmpty, n != "Error" {
                head = n + ": " + m
            }
        } else if let t = e.toString(), !t.isEmpty {
            head = t
        }
        var loc = ""
        if let line = e.objectForKeyedSubscript("line")?.toString(), !line.isEmpty, line != "0" {
            loc = "第 \(line) 行"
            if let col = e.objectForKeyedSubscript("column")?.toString(), !col.isEmpty, col != "0" {
                loc += " 第 \(col) 列"
            }
            if let src = e.objectForKeyedSubscript("sourceURL")?.toString(), !src.isEmpty {
                loc += "（\(src)）"
            }
        }
        if head.isEmpty { head = "未知错误" }
        return loc.isEmpty ? "JS 错误：" + head : "JS 错误：" + head + "  [" + loc + "]"
    }

    /// 站点脚本基本都是 async function。JSCore 里 `fn.call` 拿到的是 Promise，
    /// 微任务要反复进 JS 才会被抽干，所以这里轮询 __tb_state。
    /// 原生 HTTP 是同步的，实际一轮就够；留 90 秒上限是防脚本里 await 了别的东西。
    func unwrap(_ v: JSValue?, timeout: TimeInterval = 90) -> JSValue? {
        guard let v, !v.isUndefined, !v.isNull else { return v }
        let then = v.objectForKeyedSubscript("then")
        guard let then, !then.isUndefined, then.isObject else { return v }

        ctx.setObject(v, forKeyedSubscript: "__tb_pending" as NSString)
        ctx.evaluateScript("__tb_watch(__tb_pending)")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (ctx.objectForKeyedSubscript("__tb_state")?.toInt32() ?? 0) != 0 { break }
            ctx.evaluateScript("0")          // 触发一次微任务抽干
            Thread.sleep(forTimeInterval: 0.002)
        }
        let st = ctx.objectForKeyedSubscript("__tb_state")?.toInt32() ?? 0
        if st == 1 { return ctx.objectForKeyedSubscript("__tb_value") }
        if st == 2 {
            box.lines.append(ctx.objectForKeyedSubscript("__tb_error")?.toString() ?? "异步调用失败")
            return nil
        }
        box.lines.append("异步入口 \(Int(timeout)) 秒没有返回（Promise 一直 pending）")
        return nil
    }

    /// req(url, {method, headers, body, buffer}) 的落地实现。
    /// 同步阻塞（信号量等 URLSession），调用方必须在后台队列上。
    static func syncRequest(_ urlString: String, _ headersJSON: String,
                            _ method: String, _ body: String, _ asBase64: Bool) -> String {
        var headers: [String: String] = [:]
        if let d = headersJSON.data(using: .utf8),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            for (k, v) in o { headers[k] = "\(v)" }
        }
        guard let url = Net.makeURL(urlString) else {
            HTTPNote.shared.set(urlString, "地址无效")
            return ""
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.httpMethod = method.isEmpty ? "GET" : method.uppercased()
        req.setValue(Net.shared.defaultUA, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if !body.isEmpty { req.httpBody = body.data(using: .utf8) }

        let sem = DispatchSemaphore(value: 0)
        let box2 = ResultBox()
        var raw = Data()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: cfg, delegate: TrustAllDelegate(), delegateQueue: nil)
        session.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { box2.note = JSSpider.describe(err); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code != 0, !(200...299).contains(code) { box2.note = "HTTP \(code)"; return }
            guard let data, !data.isEmpty else { box2.note = "HTTP \(code) 但内容为空"; return }
            raw = data
            if asBase64 { return }
            if let t = String(data: data, encoding: .utf8) { box2.text = t }
            else {
                let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
                box2.text = String(data: data, encoding: String.Encoding(rawValue: gb)) ?? ""
            }
        }.resume()
        _ = sem.wait(timeout: .now() + 20)
        session.invalidateAndCancel()
        HTTPNote.shared.set(urlString, box2.text.isEmpty && box2.note.isEmpty ? "" : box2.note)
        if asBase64 { return raw.base64EncodedString() }
        return box2.text
    }

    /// AES-CBC 解密，输入输出都是 base64。
    /// 先按 NoPadding 解，再手动去掉 PKCS7 尾巴 —— 站点有的标 "No" 有的真带 padding，
    /// 统一这么处理两边都不会错。
    static func aesDecryptBase64(_ b64: String, key: String, iv: String, mode: String) -> String {
        let clean = b64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: clean, options: [.ignoreUnknownCharacters]),
              !data.isEmpty else { return "" }
        let k = Array(key.utf8)
        var ivBytes = Array(iv.utf8)
        if ivBytes.isEmpty { ivBytes = Array(repeating: 0, count: 16) }
        guard k.count == 16 || k.count == 24 || k.count == 32, ivBytes.count == 16 else { return "" }
        if data.count % kCCBlockSizeAES128 != 0 { return "" }

        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let st = out.withUnsafeMutableBytes { ob -> Int32 in
            data.withUnsafeBytes { db -> Int32 in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                        k, k.count, ivBytes,
                        db.baseAddress, data.count,
                        ob.baseAddress, ob.count, &moved)
            }
        }
        guard st == kCCSuccess, moved > 0 else { return "" }
        var plain = out.prefix(moved)
        // 去掉 PKCS7 尾巴：末字节 n，且末尾 n 个字节都等于 n
        if let last = plain.last, last > 0, last <= 16, plain.count >= Int(last) {
            let n = Int(last)
            let tail = plain.suffix(n)
            if tail.allSatisfy({ $0 == last }) { plain = plain.dropLast(n) }
        }
        return Data(plain).base64EncodedString()
    }

    // MARK: - HTML 片段（cheerio shim 的原语）

    static func fragmentRoot(_ html: String) -> Element? {
        guard let doc = try? SwiftSoup.parseBodyFragment(html) else { return nil }
        return doc.body()?.children().first()
    }

    static func fragmentText(_ html: String) -> String {
        guard let el = fragmentRoot(html) else { return "" }
        return (try? el.text()) ?? ""
    }

    static func fragmentHtml(_ html: String) -> String {
        guard let el = fragmentRoot(html) else { return "" }
        return (try? el.html()) ?? ""
    }

    static func fragmentAttr(_ html: String, _ name: String) -> String {
        guard let el = fragmentRoot(html) else { return "" }
        return (try? el.attr(name)) ?? ""
    }

    /// `$(sel)` / `node.find(sel)`：返回命中的 outerHTML 数组。
    /// 传进来的是整页就从 document 选，传进来的是单个节点（outerHTML）就只在该节点下面选。
    static func queryAll(_ html: String, _ selector: String) -> [String] {
        let sel = selector.trimmingCharacters(in: .whitespaces)
        guard !sel.isEmpty else { return [] }
        let lower = html.lowercased()
        let wholePage = lower.hasPrefix("<!doctype") || lower.hasPrefix("<html") || lower.contains("<body")
        guard let doc = try? SwiftSoup.parse(html) else { return [] }
        let scope: Element = wholePage ? doc : ((doc.body()?.children().first()) ?? doc)
        guard let els = try? scope.select(sel) else { return [] }
        return els.map { (try? $0.outerHtml()) ?? "" }
    }

    // MARK: - 原生桥

    private func installBridges() {
        let ctx = self.ctx
        let b = self.box

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

        // JS 里判断「为什么没拿到页面」用：__httpNote(url) → "" 表示成功
        let httpNote: @convention(block) (String) -> String = { url in
            HTTPNote.shared.get(url)
        }
        ctx.setObject(unsafeBitCast(httpNote, to: AnyObject.self), forKeyedSubscript: "__httpNote" as NSString)

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

        // ---- 新版 js spider 需要的那几个 ----
        // console.* 落到日志里，前缀标清楚，免得被 errorText 当成站点错误
        let logLine: @convention(block) (String) -> Void = { line in
            if b.lines.count < 400 { b.lines.append("[日志] " + line) }
        }
        ctx.setObject(unsafeBitCast(logLine, to: AnyObject.self), forKeyedSubscript: "__log" as NSString)

        // req(url, {method, headers, body, buffer})
        let hosts = self.hostBox
        let reqSync: @convention(block) (String, String, String, String, Int) -> String = { url, hjson, method, body, b64 in
            if let u = URL(string: url), let h = u.host, !h.isEmpty {
                var origin = (u.scheme ?? "https") + "://" + h
                if let port = u.port { origin += ":\(port)" }
                hosts.origin = origin
            }
            return JSSpider.syncRequest(url, hjson, method, body, b64 != 0)
        }
        ctx.setObject(unsafeBitCast(reqSync, to: AnyObject.self), forKeyedSubscript: "__reqSync" as NSString)

        // cheerio 的最小实现：选择器交给 SwiftSoup，返回 outerHTML 数组
        let selAll: @convention(block) (String, String) -> String = { html, q in
            let arr = JSSpider.queryAll(html, q)
            guard let d = try? JSONSerialization.data(withJSONObject: arr) else { return "[]" }
            return String(data: d, encoding: .utf8) ?? "[]"
        }
        ctx.setObject(unsafeBitCast(selAll, to: AnyObject.self), forKeyedSubscript: "__sel" as NSString)

        let fragText: @convention(block) (String) -> String = { html in JSSpider.fragmentText(html) }
        ctx.setObject(unsafeBitCast(fragText, to: AnyObject.self), forKeyedSubscript: "__text" as NSString)

        let fragHtml: @convention(block) (String) -> String = { html in JSSpider.fragmentHtml(html) }
        ctx.setObject(unsafeBitCast(fragHtml, to: AnyObject.self), forKeyedSubscript: "__innerHtml" as NSString)

        let fragAttr: @convention(block) (String, String) -> String = { html, n in JSSpider.fragmentAttr(html, n) }
        ctx.setObject(unsafeBitCast(fragAttr, to: AnyObject.self), forKeyedSubscript: "__attr" as NSString)

        // aesX(...) 的解密半：这类脚本拿它解封面图（站点把图片 AES 加密了），
        // JSCore 没有 crypto，交给 CommonCrypto。
        let aesDec: @convention(block) (String, String, String, String) -> String = { b64, key, iv, mode in
            JSSpider.aesDecryptBase64(b64, key: key, iv: iv, mode: mode)
        }
        ctx.setObject(unsafeBitCast(aesDec, to: AnyObject.self), forKeyedSubscript: "__aesDec" as NSString)
    }

    /// 同步 HTTP，供 JS 直接拿字符串。
    /// 失败原因记进 HTTPNote，JS 侧用 __httpNote(url) 读出来 —— 否则诊断里只有「0 字符」，
    /// 分不清是域名解析失败、被墙、还是源站 502。
    static func syncGet(_ urlString: String, headers: [String: String]) -> String {
        guard let url = Net.makeURL(urlString) else {
            HTTPNote.shared.set(urlString, "地址无效")
            return ""
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue(Net.shared.defaultUA, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        let session = URLSession(configuration: cfg, delegate: TrustAllDelegate(), delegateQueue: nil)
        session.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err {
                box.note = Self.describe(err)
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code != 0, !(200...299).contains(code) {
                box.note = Self.describe(status: code)
                return          // 错误页的正文（"upstream connect failed"）不能当 HTML 用
            }
            guard let data, !data.isEmpty else {
                box.note = "HTTP \(code) 但内容为空"
                return
            }
            if let s = String(data: data, encoding: .utf8) {
                box.text = s
            } else {
                let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
                box.text = String(data: data, encoding: String.Encoding(rawValue: gb)) ?? ""
            }
            if box.text.isEmpty { box.note = "HTTP \(code) 但正文无法按 UTF-8/GB18030 解码" }
        }.resume()
        _ = sem.wait(timeout: .now() + 18)
        session.invalidateAndCancel()

        if box.text.isEmpty && box.note.isEmpty { box.note = "请求超时（12 秒无响应）" }
        HTTPNote.shared.set(urlString, box.text.isEmpty ? box.note : "")
        return box.text
    }

    /// dataTask 回调与等待线程之间传结果
    private final class ResultBox: @unchecked Sendable {
        var text = ""
        var note = ""
    }

    static func describe(_ err: Error) -> String {
        let e = err as NSError
        switch e.code {
        case NSURLErrorTimedOut:            return "连接超时（12 秒）"
        case NSURLErrorCannotFindHost:      return "域名解析失败（DNS 拿不到 IP）"
        case NSURLErrorCannotConnectToHost: return "连不上主机（端口不通，或被网络拦截）"
        case NSURLErrorNetworkConnectionLost: return "连接被重置"
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateUntrusted: return "TLS 握手失败（证书问题或被中间设备拦截）"
        case NSURLErrorNotConnectedToInternet: return "设备没有网络"
        default: return e.localizedDescription
        }
    }

    static func describe(status: Int) -> String {
        switch status {
        case 401, 403: return "HTTP \(status)（拒绝访问：鉴权或防盗链）"
        case 404:      return "HTTP 404（页面不存在）"
        case 500:      return "HTTP 500（源站内部错误）"
        case 502, 503, 504: return "HTTP \(status)（源站上游不可用，服务器自己出问题了）"
        default: return "HTTP \(status)"
        }
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
