import Foundation
import UIKit
import WebKit

/// 播放页嗅探：把播放页塞进无界面 WKWebView，拦它自己发出的媒体请求。
///
/// 为什么需要这一层：配置里 `parses` 有一半是 `type: 0`（嗅探型）。这类接口不返回
/// JSON，给的是一个播放页地址，页面里跑一段播放器脚本自己去请求 m3u8。
/// 页面上看不到地址，只能拦。
///
/// 三层拦截，漏一层就有一类站点拿不到：
/// 1. JS hook XHR / fetch —— 主路径
/// 2. JS 盯 video / source 的 src 赋值 —— 少数站点直接给标签赋值
/// 3. 原生 decidePolicyFor —— 整页跳转到 m3u8 的站点走这条
///
/// 过滤规则外置在 `Resources/sniff_rules.json`，hook 代码在 `Resources/parse_sniff.js`。
/// 两边都改了要同步 `tests/parse_webview.test.js`。
enum ParseWebView {

    struct Outcome {
        /// nil 表示这次没嗅到，notes 里是原因
        var url: String?
        var notes: [String]
        var source: String
        /// 取到地址时带上「取它时用的头」：嗅出来的流多数认播放页的 Referer，不是站点根
        var headers: [String: String] = [:]
    }

    struct Hit {
        var url: String
        var source: String
        var rank: Int
    }

    // MARK: - 规则

    struct Rules {
        var mediaExtensions: [String] = ["m3u8", "mpd", "mp4", "m4v", "mov", "flv", "ts", "mkv", "webm", "mp3", "m4a", "aac"]
        var blockHostKeywords: [String] = []
        var blockURLPatterns: [String] = []
        var noteURLPatterns: [String] = ["^blob:", "^mediasource:"]
        var rankBoost: [String: Int] = ["m3u8": 30, "mpd": 30, "mp4": 20, "flv": 10]
        var confirmedBoost: Int = 100
        var timeout: TimeInterval = 14
        var settle: TimeInterval = 1.2
        var maxWebViewAttempts: Int = 2
        var maxJSONAttempts: Int = 4
    }

    /// 读不到规则文件也照跑：内置默认值覆盖常见情况
    static let rules: Rules = loadRules()

    private static func loadRules() -> Rules {
        var r = Rules()
        guard let u = Bundle.main.url(forResource: "sniff_rules", withExtension: "json"),
              let data = try? Data(contentsOf: u),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return r
        }
        if let v = obj["mediaExtensions"] as? [String], !v.isEmpty {
            r.mediaExtensions = v.map { $0.lowercased() }
        }
        if let v = obj["blockHostKeywords"] as? [String] { r.blockHostKeywords = v.map { $0.lowercased() } }
        if let v = obj["blockURLPatterns"] as? [String] { r.blockURLPatterns = v }
        if let v = obj["noteURLPatterns"] as? [String], !v.isEmpty { r.noteURLPatterns = v }
        if let v = obj["rankBoost"] as? [String: Any] {
            var m: [String: Int] = [:]
            for (k, any) in v {
                if let n = any as? Int { m[k.lowercased()] = n }
                else if let n = any as? Double { m[k.lowercased()] = Int(n) }
            }
            if !m.isEmpty { r.rankBoost = m }
        }
        if let v = obj["confirmedBoost"] as? Int { r.confirmedBoost = v }
        if let v = obj["timeout"] as? Double, v >= 3 { r.timeout = v }
        if let v = obj["settle"] as? Double, v >= 0 { r.settle = v }
        if let v = obj["maxWebViewAttempts"] as? Int, v > 0 { r.maxWebViewAttempts = v }
        if let v = obj["maxJSONAttempts"] as? Int, v > 0 { r.maxJSONAttempts = v }
        return r
    }

    // MARK: - 地址判定（纯函数，改动要同步单测里的同名实现）

    static func extensionOf(_ url: String) -> String {
        var path = url.lowercased()
        if let i = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(path[path.startIndex..<i])
        }
        guard let dot = path.lastIndex(of: ".") else { return "" }
        let tail = String(path[path.index(after: dot)...])
        // 尾巴里还有 "/" 说明这个点属于域名，不是扩展名
        if tail.contains("/") { return "" }
        return tail
    }

    static func looksMedia(_ url: String, rules r: Rules) -> Bool {
        let low = url.lowercased()
        if noteOnly(url, rules: r) { return false }
        let ext = extensionOf(low)
        // 有扩展名就按扩展名判：`a.m3u8.jpg` 这种挂羊头的不能被 contains("m3u8") 放进来
        if !ext.isEmpty { return r.mediaExtensions.contains(ext) }
        // 无扩展名的 HLS：/hls/index、/live/play?format=m3u8
        if low.contains("/hls/") { return true }
        if let q = low.split(separator: "?").dropFirst().first, q.contains("m3u8") { return true }
        return false
    }

    static func isBlocked(_ url: String, rules r: Rules) -> Bool {
        let low = url.lowercased()
        for k in r.blockHostKeywords where !k.isEmpty && low.contains(k) { return true }
        for p in r.blockURLPatterns {
            if let re = regex(p), re.firstMatch(in: low, range: NSRange(low.startIndex..., in: low)) != nil {
                return true
            }
        }
        return false
    }

    static func noteOnly(_ url: String, rules r: Rules) -> Bool {
        let low = url.lowercased()
        for p in r.noteURLPatterns {
            if let re = regex(p), re.firstMatch(in: low, range: NSRange(low.startIndex..., in: low)) != nil {
                return true
            }
        }
        return false
    }

    static func rank(_ url: String, rules r: Rules) -> Int {
        r.rankBoost[extensionOf(url)] ?? 5
    }

    private static var regexCache: [String: NSRegularExpression] = [:]

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        if let c = regexCache[pattern] { return c }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        regexCache[pattern] = re
        return re
    }

    // MARK: - hook 脚本

    private static let hookSource: String = {
        guard let u = Bundle.main.url(forResource: "parse_sniff", withExtension: "js"),
              let s = try? String(contentsOf: u, encoding: .utf8) else { return "" }
        return s
    }()

    // MARK: - 入口

    /// 持有正在跑的嗅探器：WKWebView 的 navigationDelegate 是弱引用，
    /// 只靠 webView 自己的强引用会被提前释放
    private static var running: [Sniffer] = []

    /// 只在主线程调用（UIView 创建必须主线程）。内部自己 hop 到 main，调用方不用管。
    static func sniff(_ playURL: String, persistent: Bool = true) async -> Outcome {
        guard let target = Net.makeURL(playURL) else {
            return Outcome(url: nil, notes: ["播放页地址无效，没法嗅探"], source: "none")
        }
        guard !hookSource.isEmpty else {
            // 资源没打进包时任何站点都会走到这里，必须说清楚下一步查什么
            return Outcome(url: nil, notes: ["bundle 里缺 parse_sniff.js，webview 嗅探不可用（查 project.yml 的 Resources 路径）"], source: "none")
        }
        let s = Sniffer(target: target, rules: rules, hook: hookSource, persistent: persistent)
        // running 的读写都收敛到 main：连点两集时会并发进来
        await MainActor.run { running.append(s) }
        let out = await s.run()
        await MainActor.run { running.removeAll { $0 === s } }
        return out
    }
}

// MARK: - 嗅探器

/// 不用 @MainActor 标注：WKNavigationDelegate 的协议方法在旧 SDK 里没有隔离标注，
/// 加上 @MainActor 会撞编译器；而所有回调本来就落在主线程，这里靠「只在主线程访问」保证。
private final class Sniffer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

    private let target: URL
    private let rules: ParseWebView.Rules
    private let hook: String
    private let persistent: Bool

    private var webView: WKWebView?
    private var cont: CheckedContinuation<ParseWebView.Outcome, Never>?
    private var hits: [ParseWebView.Hit] = []
    private var notes: [String] = []
    private var done = false
    private var settleWork: DispatchWorkItem?
    private var drainRounds = 0

    private let handlerName = "tbSniff"

    init(target: URL, rules: ParseWebView.Rules, hook: String, persistent: Bool) {
        self.target = target
        self.rules = rules
        self.hook = hook
        self.persistent = persistent
    }

    func run() async -> ParseWebView.Outcome {
        await withCheckedContinuation { (c: CheckedContinuation<ParseWebView.Outcome, Never>) in
            // 状态只在主线程读写：continuation 也在 main 上落，boot 之后才开始计时
            DispatchQueue.main.async {
                self.cont = c
                self.boot()
                let t = self.rules.timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                    self?.finish(reason: "\(Int(t)) 秒内页面没发出可播放地址")
                }
            }
        }
    }

    // MARK: 启动

    private func boot() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        // 播放页常在 video 上等一次 play()，默认策略会把它拦掉
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.websiteDataStore = persistent ? WKWebsiteDataStore.default() : WKWebsiteDataStore.nonPersistent()

        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: hook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        ucc.add(self, name: handlerName)
        cfg.userContentController = ucc

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: cfg)
        wv.navigationDelegate = self
        wv.customUserAgent = Net.shared.defaultUA
        wv.isUserInteractionEnabled = false
        wv.scrollView.isScrollEnabled = false
        // 完全透明（0）会让 WebKit 判定不可见并降频渲染，后续请求被节流，嗅不到
        wv.alpha = 0.01
        webView = wv

        attach(wv)
        var req = URLRequest(url: target)
        req.timeoutInterval = rules.timeout
        req.setValue(Net.shared.defaultUA, forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        wv.load(req)
    }

    /// 不建新 UIWindow：隐藏窗口会抢 key window，把用户当前界面切走
    private func attach(_ wv: WKWebView) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        let host = windows.first(where: { $0.isKeyWindow }) ?? windows.first
        guard let root = host?.rootViewController?.view else { return }
        root.addSubview(wv)
    }

    private var referer: String {
        let o = URLKit.origin(target.absoluteString)
        return o.isEmpty ? target.absoluteString : o + "/"
    }

    // MARK: 命中处理

    @discardableResult
    private func record(_ raw: String, source: String, confirmed: Bool = false) -> Bool {
        guard !done else { return false }
        let u = PlayResolver.decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty, u != target.absoluteString else { return false }

        if ParseWebView.noteOnly(u, rules: rules) {
            let scheme = u.split(separator: ":").first.map(String.init) ?? "blob"
            let n = "页面用 MSE 取流（\(scheme): 地址），这种播放页没有外露直链"
            if !notes.contains(n) { notes.append(n) }
            return false
        }
        guard ParseWebView.looksMedia(u, rules: rules) else { return false }
        guard !ParseWebView.isBlocked(u, rules: rules) else { return false }

        // 同一条地址先以「未确认」上报，XHR 读回响应体后还会再来一次「确认」，
        // 这次要把分数提上去，否则排位还按首包算
        if let i = hits.firstIndex(where: { $0.url == u }) {
            guard confirmed else { return false }
            let upgraded = ParseWebView.rank(u, rules: rules) + rules.confirmedBoost
            guard hits[i].rank < upgraded else { return false }
            hits[i].rank = upgraded
            hits[i].source = source
            if ParseWebView.extensionOf(u) == "m3u8" {
                finish(reason: "响应体确认是 m3u8")
                return true
            }
            return false
        }

        let score = ParseWebView.rank(u, rules: rules) + (confirmed ? rules.confirmedBoost : 0)
        hits.append(ParseWebView.Hit(url: u, source: source, rank: score))

        // 响应体确认过的 m3u8 就是最优解，不用再等别的
        if confirmed && ParseWebView.extensionOf(u) == "m3u8" {
            finish(reason: "拿到确认过的 m3u8")
            return true
        }
        settleSoon()
        return false
    }

    private func settleSoon() {
        settleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.finish(reason: "已拿到候选地址")
        }
        settleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + rules.settle, execute: w)
    }

    private func finish(reason: String) {
        guard !done else { return }
        done = true
        settleWork?.cancel()
        settleWork = nil

        var out = notes
        var bestIndex = -1
        for (i, h) in hits.enumerated() {
            // 同分保留先到的：先发的通常是主线路，后面多是广告或备选
            if bestIndex < 0 || h.rank > hits[bestIndex].rank { bestIndex = i }
        }
        let best: ParseWebView.Hit? = bestIndex >= 0 ? hits[bestIndex] : nil

        if let b = best {
            out.append("嗅探命中（\(b.source)）：\(short(b.url))")
            if hits.count > 1 { out.append("页面共发出 \(hits.count) 个媒体地址，取分最高的一个") }
        } else {
            out.append("webview 嗅探失败：\(reason)")
            out.append("常见原因：播放页要求登录或点播放按钮、站点用 MSE 取流、页面依赖 WKWebView 不支持的接口")
        }

        teardown()
        var hdrs: [String: String] = [:]
        if best != nil {
            // 嗅到的流多数只认播放页的 Referer，站点根会被 403
            hdrs = ["Referer": referer, "User-Agent": Net.shared.defaultUA]
        }
        let c = cont
        cont = nil
        c?.resume(returning: ParseWebView.Outcome(url: best?.url, notes: out, source: best?.source ?? "none", headers: hdrs))
    }

    private func teardown() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: handlerName)
        webView?.removeFromSuperview()
        webView = nil
    }

    private func short(_ s: String) -> String {
        s.count > 120 ? String(s.prefix(120)) + "…" : s
    }

    // MARK: 兜底取数

    /// 主 frame 的 message handler 收不到 iframe 里的消息，中途主动取两次
    private func drain() {
        guard !done, drainRounds < 4, let wv = webView else { return }
        drainRounds += 1
        wv.evaluateJavaScript("window.__tbSniffDump ? window.__tbSniffDump() : '[]'") { [weak self] value, _ in
            guard let self else { return }
            guard let s = value as? String, let d = s.data(using: .utf8) else { return }
            DispatchQueue.main.async { self.absorb(d) }
        }
    }

    private func absorb(_ data: Data) {
        guard !done else { return }
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        for o in arr {
            guard let u = o["url"] as? String else { continue }
            let src = (o["src"] as? String) ?? "dump"
            let ok = (o["ok"] as? Bool) ?? false
            record(u, source: src, confirmed: ok)
        }
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == handlerName, let body = message.body as? [String: Any] else { return }
        let u = (body["url"] as? String) ?? ""
        let src = (body["src"] as? String) ?? "js"
        let ok = (body["ok"] as? Bool) ?? false
        record(u, source: src, confirmed: ok)
    }

    // MARK: WKNavigationDelegate

    /// decisionHandler 必须同步调用，否则 WebKit 内部状态机超时 —— 这里不做异步跳转
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let u = navigationAction.request.url?.absoluteString ?? ""
        let hit = !u.isEmpty
            && ParseWebView.looksMedia(u, rules: rules)
            && !ParseWebView.isBlocked(u, rules: rules)
        decisionHandler(hit ? .cancel : .allow)
        if hit {
            record(u, source: "nav")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        notes.append("播放页已加载（\(webView.url?.host ?? "?")），等它发包")
        drain()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.drain()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let msg = error.localizedDescription
        notes.append("播放页加载失败：\(msg)")
        finish(reason: "页面打不开：\(msg)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let msg = error.localizedDescription
        notes.append("播放页加载失败：\(msg)")
        finish(reason: "页面打不开：\(msg)")
    }

    /// 源站证书链很多是拼的，Net 层已经放开，webview 这里同样放开
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
