import Foundation
import JavaScriptCore
import SwiftSoup

/// TVBox / catvod JS 引擎桥：在 iOS 上用 JavaScriptCore 跑 spider 脚本
/// 提供给 JS 的原生函数：request / joinUrl / pdfh / pdfa / log
final class JSSpider {

    private let ctx: JSContext
    private var emptyObj: JSValue {
        if let o = JSValue(newObjectIn: ctx) { return o }
        return JSValue(undefinedIn: ctx)
    }
    private(set) var ruleTitle: String
    private var lastError: String?

    /// site.type == 3/4 的站点；lib 为 assets/js/lib/cat.js 内容，code 为具体 spider 脚本
    init?(site: Site, lib: String?, code: String) {
        guard let context = JSContext() else { return nil }
        // 先完成所有存储属性初始化，再让闭包捕获 self
        self.ruleTitle = site.name
        self.ctx = context
        ctx.exceptionHandler = { [weak self] _, exc in
            self?.lastError = exc?.toString() ?? "JS 异常"
        }

        installBridges()

        if let lib, !lib.isEmpty { ctx.evaluateScript(lib) }

        // ext 原样注入，脚本里通常读 __ext__
        var extString = ""
        if case .string(let s)? = site.ext { extString = s }
        else if let e = site.ext, let d = try? JSONEncoder().encode(e) { extString = String(data: d, encoding: .utf8) ?? "" }
        ctx.evaluateScript("var __ext__ = \(jsLiteral(extString));")

        ctx.evaluateScript(code)

        if let rule = ctx.objectForKeyedSubscript("rule"), !rule.isUndefined {
            ruleTitle = rule.objectForKeyedSubscript("title")?.toString() ?? site.name
            if let initFn = ctx.objectForKeyedSubscript("init"), !initFn.isUndefined {
                initFn.call(withArguments: [rule])
            }
        }
    }

    var errorText: String? { lastError }

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
                if !out.isEmpty { return out }
            }
        }
        // 老脚本走 home() + rule.class_parse
        if let fn = ctx.objectForKeyedSubscript("home"), !fn.isUndefined {
            let r = fn.call(withArguments: [])
            if let dict = jsonDict(r), let arr = dict["class"] as? [[String: Any]] {
                out = arr.compactMap { d in
                    guard let tid = str(d["type_id"]), let name = str(d["type_name"]) else { return nil }
                    return VCategory(type_id: tid, type_name: name)
                }
            }
        }
        return out
    }

    func category(tid: String, page: Int) -> (items: [VItem], pageCount: Int) {
        guard let fn = ctx.objectForKeyedSubscript("categoryContent"), !fn.isUndefined else { return ([], 1) }
        let r = fn.call(withArguments: [tid, page, false, emptyObj])
        guard let dict = jsonDict(r) else { return ([], 1) }
        let items = parseItems(dict["list"])
        let pc = (dict["pagecount"] as? NSNumber)?.intValue ?? 1
        return (items, max(pc, 1))
    }

    func detail(id: String) -> VDetail? {
        guard let fn = ctx.objectForKeyedSubscript("detailContent"), !fn.isUndefined else { return nil }
        let r = fn.call(withArguments: [[id]])
        guard let dict = jsonDict(r), let list = dict["list"] as? [[String: Any]], let first = list.first else { return nil }
        return parseDetail(first)
    }

    func search(key: String, page: Int = 1) -> [VItem] {
        guard let fn = ctx.objectForKeyedSubscript("searchContent"), !fn.isUndefined else { return [] }
        let r = fn.call(withArguments: [key, true, page])
        guard let dict = jsonDict(r) else { return [] }
        return parseItems(dict["list"])
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
        if let s = v.toString(), let d = s.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            return o
        }
        if let o = v.toObject() as? [String: Any] { return o }
        return nil
    }

    private func jsLiteral(_ s: String) -> String {
        let d = try? JSONSerialization.data(withJSONObject: [s])
        let arr = d.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
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

        let log: @convention(block) (String) -> Void = { msg in
            #if DEBUG
            print("[spider] \(msg)")
            #endif
        }
        ctx.setObject(unsafeBitCast(log, to: AnyObject.self), forKeyedSubscript: "log" as NSString)
    }

    /// 同步 HTTP，供 JS 直接返回字符串；走独立队列避免与主线程互相等待
    static func syncGet(_ urlString: String, headers: [String: String]) -> String {
        guard let url = URL(string: urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString) else { return "" }
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

    /// 支持 "div.x&&Text" / "div.x&&href" / "a&&img&&src" 这类链式写法
    static func queryH(_ html: String, _ selector: String) -> String {
        guard let doc = try? SwiftSoup.parse(html) else { return "" }
        let parts = selector.components(separatedBy: "&&").map { $0.trimmingCharacters(in: .whitespaces) }
        guard var current = try? doc.select(parts[0]).first() else { return "" }

        var mode = "Text"
        var chain = Array(parts.dropFirst())
        if let last = chain.last, ["Text", "Html", "OuterHtml"].contains(last) || isAttrLike(last) {
            mode = last
            chain.removeLast()
        }
        for css in chain {
            guard let next = try? current.select(css).first() else { return "" }
            current = next
        }
        switch mode {
        case "Text": return (try? current.text()) ?? ""
        case "Html": return (try? current.html()) ?? ""
        case "OuterHtml": return (try? current.outerHtml()) ?? ""
        default: return (try? current.attr(mode)) ?? ""
        }
    }

    static func queryA(_ html: String, _ selector: String) -> [String] {
        guard let doc = try? SwiftSoup.parse(html) else { return [] }
        let parts = selector.components(separatedBy: "&&").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let els = try? doc.select(parts[0]) else { return [] }

        var chain = Array(parts.dropFirst())
        var mode: String? = nil
        if let last = chain.last, ["Text", "Html", "OuterHtml"].contains(last) || isAttrLike(last) {
            mode = last
            chain.removeLast()
        }

        var results: [String] = []
        for el in els {
            var cur = el
            var ok = true
            for css in chain {
                if let next = try? cur.select(css).first() { cur = next } else { ok = false; break }
            }
            if !ok { continue }
            switch mode {
            case .none: results.append((try? cur.outerHtml()) ?? "")
            case .some("Text"): results.append((try? cur.text()) ?? "")
            case .some("Html"): results.append((try? cur.html()) ?? "")
            case .some("OuterHtml"): results.append((try? cur.outerHtml()) ?? "")
            case .some(let attr): results.append((try? cur.attr(attr)) ?? "")
            }
        }
        return results
    }

    private static func isAttrLike(_ s: String) -> Bool {
        guard !s.isEmpty, s.count < 24 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) } && !s.contains(" ")
    }
}
