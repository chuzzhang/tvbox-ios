import Foundation
import AVFoundation

/// HLS 本地代理：让 AVPlayer 用上自定义 Referer / UA。
///
/// iOS 上 `AVURLAssetHTTPHeaderFieldsKey` 是私有键、基本不生效，
/// 而一堆源站的 m3u8 校验 Referer/UA，直连就是 403 → 黑屏且不报错。
///
/// 做法：把 http(s) 地址包成 `skd://proxy/<base64>`，AVPlayer 遇到非 http scheme
/// 会把请求交给 resourceLoader，我们用自己的 URLSession（带头）去拉，
/// 播放列表里的分片地址再逐个包一遍，这样分片也带上头。
final class HLSProxy: NSObject, AVAssetResourceLoaderDelegate {

    static let scheme = "skd"
    static let host = "proxy"

    private let headers: [String: String]
    private let session: URLSession

    init(headers: [String: String]) {
        self.headers = headers
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg, delegate: TrustAllDelegate(), delegateQueue: nil)
        super.init()
    }

    func close() {
        session.invalidateAndCancel()
    }

    // MARK: - 地址编解码

    static func proxyURL(_ http: String) -> URL? {
        guard let data = http.data(using: .utf8) else { return nil }
        var b64 = data.base64EncodedString()
        b64 = b64.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "\(scheme)://\(host)/\(b64)")
    }

    static func originalURL(_ proxy: URL) -> String? {
        var b64 = proxy.lastPathComponent
        b64 = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let purl = loadingRequest.request.url,
              let real = Self.originalURL(purl) else { return false }
        start(real, loadingRequest)
        return true
    }

    private func start(_ real: String, _ lr: AVAssetResourceLoadingRequest) {
        guard let u = Net.makeURL(real) else {
            lr.finishLoading(with: NetError.badURL(real))
            return
        }
        var req = URLRequest(url: u)
        req.timeoutInterval = 20
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        session.dataTask(with: req) { data, resp, err in
            if let err {
                lr.finishLoading(with: err)
                return
            }
            guard let data, let http = resp as? HTTPURLResponse else {
                lr.finishLoading()
                return
            }
            guard http.statusCode == 200 || http.statusCode == 206 else {
                lr.finishLoading(with: NetError.status(http.statusCode, real))
                return
            }

            let ctype = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            var payload = data
            var isPlaylist = ctype.contains("mpegurl")
            if !isPlaylist, let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") {
                isPlaylist = true
            }
            if isPlaylist {
                let text = String(data: data, encoding: .utf8) ?? ""
                payload = Data(Self.rewrite(text, base: real).utf8)
            }

            if let info = lr.contentInformationRequest {
                info.contentType = isPlaylist ? "application/vnd.apple.mpegurl" : (ctype.isEmpty ? "video/mp2t" : ctype)
                info.contentLength = Int64(payload.count)
                info.isByteRangeAccessSupported = false
            }
            lr.dataRequest?.respond(with: payload)
            lr.finishLoading()
        }.resume()
    }

    // MARK: - m3u8 重写

    /// 把播放列表里的分片、子列表、密钥地址逐个包成代理地址
    static func rewrite(_ text: String, base: String) -> String {
        let baseURL = URL(string: base)
        var out: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                out.append(raw)
                continue
            }
            if line.hasPrefix("#") {
                out.append(rewriteTagURI(line, baseURL: baseURL))
                continue
            }
            if let abs = URL(string: line, relativeTo: baseURL)?.absoluteURL.absoluteString,
               let proxied = proxyString(abs) {
                out.append(proxied)
            } else {
                out.append(raw)
            }
        }
        return out.joined(separator: "\n")
    }

    /// `#EXT-X-KEY:...URI="xxx"` / `#EXT-X-MAP:URI="xxx"` / `#EXT-X-MEDIA:URI="xxx"`
    private static func rewriteTagURI(_ line: String, baseURL: URL?) -> String {
        guard line.contains("URI=\""), let baseURL else { return line }
        guard let re = try? NSRegularExpression(pattern: "URI=\"([^\"]*)\"", options: []) else { return line }
        let ns = line as NSString
        let matches = re.matches(in: line, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return line }

        // 从后往前替换：前面还没处理的位置不会因为替换而偏移
        var out = line
        for m in matches.reversed() {
            let r = m.range(at: 1)
            guard r.location != NSNotFound, let swiftRange = Range(r, in: out) else { continue }
            let raw = ns.substring(with: r)
            guard let abs = URL(string: raw, relativeTo: baseURL)?.absoluteURL.absoluteString,
                  let proxied = proxyString(abs) else { continue }
            out.replaceSubrange(swiftRange, with: proxied)
        }
        return out
    }

    private static func proxyString(_ http: String) -> String? {
        guard let data = http.data(using: .utf8) else { return nil }
        var b64 = data.base64EncodedString()
        b64 = b64.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(scheme)://\(host)/\(b64)"
    }
}
