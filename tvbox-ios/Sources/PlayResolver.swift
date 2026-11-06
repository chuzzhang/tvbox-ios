import Foundation
import AVFoundation

/// 播放地址解析。
///
/// CMS 给的 `vod_play_url` 有三种坑：
/// 1. 是播放页而不是媒体流：`https://x/player/?url=https%3A%2F%2Fcdn%2F1.m3u8`
/// 2. 是相对路径：`/v/2024/xxx.m3u8`
/// 3. 直链但校验 Referer/UA：裸请求 403，AVPlayer 默认 UA 是 AppleCoreMedia，一样被拒
///
/// 三种都表现为「能加载，但是黑屏」——AVPlayer 拿不到可用数据也不一定报错。
/// 这里在播放前先探一次，把地址换对，把必须的头带上（必要时走本地代理）。
enum PlayResolver {

    struct Plan {
        var url: String
        /// 播放该地址需要的请求头
        var headers: [String: String]
        /// 只有带 headers 才拿得到数据时，用本地资源代理把 headers 补上
        var useProxy: Bool
        /// 诊断：播放页上「为什么黑」直接显示给人看
        var notes: [String]
    }

    struct Probe {
        var status: Int = 0
        var contentType: String = ""
        var head: String = ""
        var failure: String = ""

        var ok: Bool {
            if failure.isEmpty == false { return false }
            guard status == 200 || status == 206 else { return false }
            if contentType.contains("html") || contentType.contains("json") || contentType.contains("text/plain") {
                // text/plain 可能是 m3u8，看头部内容再定
                if !head.hasPrefix("#EXTM3U") { return false }
            }
            return true
        }

        var describe: String {
            if !failure.isEmpty { return "请求失败：\(failure)" }
            if status == 401 || status == 403 { return "HTTP \(status)（防盗链，需要带 Referer/UA）" }
            if status == 404 { return "HTTP 404，文件不存在" }
            if !head.isEmpty, head.hasPrefix("<") { return "HTTP \(status)，返回的是网页不是视频流" }
            return "HTTP \(status) \(contentType)"
        }
    }

    private static let mediaExts = [
        "m3u8", "mp4", "flv", "ts", "mkv", "mov", "m4v", "avi", "wmv", "mp3", "m4a", "mpd", "webm"
    ]

    // MARK: - 入口

    static func resolve(raw: String, siteBase: String?, parses: [Parse]) async -> Plan {
        var notes: [String] = []
        var s = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else {
            return Plan(url: "", headers: [:], useProxy: false, notes: ["播放地址为空"])
        }

        // 1) 播放页里嵌了真实地址：?url= / ?v= / ?play=
        if let inner = innerURL(s), inner != s {
            notes.append("从播放页取出真实地址：\(short(inner))")
            s = inner
        }

        // 2) 相对路径补站点
        s = normalize(s, base: siteBase)
        notes.append("播放地址：\(short(s))")

        var headers: [String: String] = ["User-Agent": Net.shared.defaultUA]
        // origin 返回的是 String（拿不到时是空串），不能当可选值二次绑定
        let origin = URLKit.origin(siteBase ?? s)
        if !origin.isEmpty {
            headers["Referer"] = origin + "/"
        }

        // 3) 探一次：带 headers 能不能拿到流
        var p = await probe(s, headers: headers)
        notes.append("带 Referer 探测：\(p.describe)")

        // 3.5) https 握手被链路掐掉时，同域名的 80 端口往往还通（表现是 iOS 报安全连接失败）
        if !p.ok, s.lowercased().hasPrefix("https://") {
            let alt = Net.httpVariant(s)
            if alt != s {
                let p2 = await probe(alt, headers: headers)
                notes.append("换 http 探测：\(p2.describe)")
                if p2.ok {
                    notes.append("https 握手被阻断，改用 http（同一份数据，只是没加密）")
                    Net.noteDowngrade(from: s, to: alt)
                    s = alt
                    p = p2
                }
            }
        }

        // 4) 拿不到就按 parses 逐条试：type 1 走 json 接口，其余走 webview 嗅探
        if !p.ok {
            let attempts = await viaParses(s, parses: parses)
            for a in attempts {
                var head = "解析「\(a.name)」[\(a.kind)]"
                if let cand = a.url, !cand.isEmpty {
                    head += "：" + short(cand)
                } else {
                    head += "：没取到地址"
                }
                notes.append(head)
                for n in a.notes { notes.append("    · " + n) }

                guard let cand = a.url, !cand.isEmpty else { continue }
                // 嗅探带回来的头优先：那条流认的是播放页的 Referer
                var candHeaders = headers
                for (k, v) in a.headers { candHeaders[k] = v }
                let p2 = await probe(cand, headers: candHeaders)
                notes.append("    · 探测：" + p2.describe)
                if p2.ok {
                    s = cand
                    p = p2
                    headers = candHeaders
                    notes.append("采用「\(a.name)」给出的地址")
                    break
                }
            }
        }

        guard p.ok else {
            notes.append("这个地址播不了：\(p.describe)")
            notes.append("常见原因：源站要求登录/时效性 token 过期，或该线路的 CDN 已失效。换一条线路试试。")
            return Plan(url: s, headers: headers, useProxy: false, notes: notes)
        }

        // 5) 裸请求行不行 —— 不行说明必须补头，那就走本地代理
        let bare = await probe(s, headers: [:])
        let useProxy = !bare.ok
        if useProxy {
            notes.append("裸请求被拒（\(bare.describe)），播放时通过本地代理补 Referer/UA")
        }

        return Plan(url: s, headers: headers, useProxy: useProxy, notes: notes)
    }

    // MARK: - 地址处理

    static func decodeEntities(_ s: String) -> String {
        var t = s
        for (a, b) in [("&amp;", "&"), ("&#38;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }

    static func normalize(_ s: String, base: String?) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("http") { return t }
        let r = URLKit.resolve(t, base: base)
        return r.isEmpty ? t : r
    }

    /// 从播放页地址里挖出真实媒体地址
    static func innerURL(_ s: String) -> String? {
        if let comps = URLComponents(string: s), let items = comps.queryItems {
            for name in ["url", "u", "v", "play", "vid", "src", "m3u8", "video"] {
                guard let v = items.first(where: { $0.name.lowercased() == name })?.value else { continue }
                let d = v.removingPercentEncoding ?? v
                if d.lowercased().hasPrefix("http"), looksMedia(d) { return d }
                if d.lowercased().hasPrefix("http") { return d }
            }
        }
        // query 整体被编码成一串时，直接在里面找 http 地址
        if let range = s.range(of: "https?://[^&\\s\"']+", options: .regularExpression) {
            let found = String(s[range])
            if found != s, looksMedia(found) { return found }
        }
        return nil
    }

    static func looksMedia(_ s: String) -> Bool {
        var path = s
        if let q = path.firstIndex(of: "?") { path = String(path[path.startIndex..<q]) }
        let ext = path.split(separator: ".").last.map { String($0).lowercased() } ?? ""
        if mediaExts.contains(ext) { return true }
        let low = s.lowercased()
        for e in [".m3u8", ".mp4", ".flv", ".mpd"] where low.contains(e) { return true }
        return false
    }

    private static func short(_ s: String) -> String {
        s.count > 110 ? String(s.prefix(110)) + "…" : s
    }

    // MARK: - 探测

    static func probe(_ url: String, headers: [String: String]) async -> Probe {
        guard let u = Net.makeURL(url) else {
            var p = Probe()
            p.failure = "地址无效"
            return p
        }
        var req = URLRequest(url: u)
        req.timeoutInterval = 8
        req.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: cfg, delegate: TrustAllDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, resp) = try await session.data(for: req)
            var p = Probe()
            p.status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            p.contentType = ((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            p.head = String(data: data.prefix(48), encoding: .utf8) ?? ""
            return p
        } catch {
            var p = Probe()
            p.failure = error.localizedDescription
            return p
        }
    }

    // MARK: - 解析接口

    struct ParseAttempt {
        var name: String
        var kind: String
        var url: String?
        var notes: [String] = []
        /// 取这个地址时用的请求头（webview 嗅探出来的是播放页的 Referer）
        var headers: [String: String] = [:]
    }

    /// tvbox 的 `parses` 有两种，配置里混着放：
    /// - `type: 1` —— json 接口，把播放页塞给 `.../?url=`，接口回 `{"url":"真实地址"}`
    /// - `type: 0/2`（默认）—— 嗅探接口，`url` 本身是播放页，页面里的播放器自己发包，
    ///   地址只有拦请求才拿得到，走 `ParseWebView`
    ///
    /// 顺序照配置走，**不按类型重排**：配置里的顺序就是站点作者排的可靠度顺序。
    /// 试的次数按 `sniff_rules.json` 的预算卡住，否则一次播放等十几条接口要几分钟。
    static func viaParses(_ playURL: String, parses: [Parse]) async -> [ParseAttempt] {
        guard !parses.isEmpty else { return [] }
        let rules = ParseWebView.rules
        var jsonLeft = rules.maxJSONAttempts
        var webLeft = rules.maxWebViewAttempts
        var out: [ParseAttempt] = []

        for p in parses {
            let raw = p.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            let name = p.name.isEmpty ? "未命名" : p.name

            if p.type == 1 {
                guard jsonLeft > 0 else {
                    out.append(ParseAttempt(name: name, kind: "json", url: nil,
                                            notes: ["跳过：json 接口已试满 \(rules.maxJSONAttempts) 个"]))
                    continue
                }
                jsonLeft -= 1
                var a = ParseAttempt(name: name, kind: "json", url: nil)
                a.url = await jsonParse(playURL, api: raw)
                if a.url == nil {
                    a.notes.append("接口没返回可识别的媒体地址（可能要求 Referer、或返回了错误页）")
                }
                out.append(a)
            } else {
                guard webLeft > 0 else {
                    out.append(ParseAttempt(name: name, kind: "webview", url: nil,
                                            notes: ["跳过：webview 嗅探已试满 \(rules.maxWebViewAttempts) 个"]))
                    continue
                }
                webLeft -= 1
                // 播放页地址可能是相对的，按播放地址所在目录补全
                let page = normalize(raw, base: URLKit.base(playURL))
                var a = ParseAttempt(name: name, kind: "webview", url: nil)
                let r = await ParseWebView.sniff(page)
                a.url = r.url
                a.headers = r.headers
                a.notes.append(contentsOf: r.notes)
                out.append(a)
            }
        }
        return out
    }

    /// json 型解析接口：拼 `?url=`，回来在 JSON 里找第一个像媒体地址的字段
    static func jsonParse(_ playURL: String, api: String) async -> String? {
        guard let encoded = playURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        var full = api
        if !full.contains("url=") {
            full += (full.contains("?") ? "" : "?") + "url="
        }
        full += encoded
        guard let data = try? await Net.shared.fetch(full, timeout: 10, retry: 0) else { return nil }
        return findURL(in: data)
    }

    /// 在解析接口的 JSON 里找第一个像媒体地址的字段
    private static func findURL(in data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            let text = String(decoding: data, as: UTF8.self)
            if let r = text.range(of: "https?://[^\"'\\s\\\\]+", options: .regularExpression) {
                let s = String(text[r]).replacingOccurrences(of: "\\/", with: "/")
                return looksMedia(s) ? decodeEntities(s) : nil
            }
            return nil
        }
        return searchURL(obj, depth: 0)
    }

    private static func searchURL(_ obj: Any, depth: Int) -> String? {
        if depth > 4 { return nil }
        if let s = obj as? String {
            return looksMedia(s) ? decodeEntities(s) : nil
        }
        if let arr = obj as? [Any] {
            for v in arr { if let r = searchURL(v, depth: depth + 1) { return r } }
            return nil
        }
        guard let dict = obj as? [String: Any] else { return nil }
        // 先看明确的字段名
        for k in ["url", "playUrl", "play_url", "src", "m3u8", "address"] {
            if let v = dict[k], let r = searchURL(v, depth: depth + 1) { return r }
        }
        for (_, v) in dict {
            if let r = searchURL(v, depth: depth + 1) { return r }
        }
        return nil
    }
}
