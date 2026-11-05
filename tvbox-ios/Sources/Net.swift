import Foundation

/// 极简 HTTP 客户端：自定义 UA / Referer、超时、一次重试、文本编码兜底
final class Net {
    static let shared = Net()

    private let session: URLSession

    /// 默认 UA 伪装成移动端浏览器，多数源站会按 UA 返回不同结果
    var defaultUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 8
        // 部分源站证书链有问题，这里放开校验（iOS 端壳自用）
        session = URLSession(configuration: cfg, delegate: TrustAllDelegate(), delegateQueue: nil)
    }

    func fetch(_ urlString: String,
               headers: [String: String] = [:],
               timeout: TimeInterval = 15,
               retry: Int = 1) async throws -> Data {
        guard let url = URL(string: urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString) else {
            throw NetError.badURL(urlString)
        }
        var lastError: Error = NetError.empty
        for attempt in 0...retry {
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = timeout
                req.setValue(defaultUA, forHTTPHeaderField: "User-Agent")
                req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
                for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
                let (data, resp) = try await session.data(for: req)
                if let http = resp as? HTTPURLResponse, !(200...399).contains(http.statusCode) {
                    throw NetError.status(http.statusCode, urlString)
                }
                if data.isEmpty { throw NetError.empty }
                return data
            } catch {
                lastError = error
                if attempt < retry {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
        }
        throw lastError
    }

    /// 拉文本并做编码兜底：先 UTF-8，失败再试 GB18030
    func fetchText(_ urlString: String, headers: [String: String] = [:]) async throws -> String {
        let data = try await fetch(urlString, headers: headers)
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    /// 拉 JSON，容忍 BOM 与前后杂字符
    func fetchJSON<T: Decodable>(_ type: T.Type, _ urlString: String, headers: [String: String] = [:]) async throws -> T {
        let data = try await fetch(urlString, headers: headers)
        let cleaned = Self.stripJSONNoise(data)
        do {
            return try JSONDecoder().decode(T.self, from: cleaned)
        } catch {
            throw NetError.decode(String(describing: error), String(data: cleaned.prefix(200), encoding: .utf8) ?? "")
        }
    }

    static func stripJSONNoise(_ data: Data) -> Data {
        guard var s = String(data: data, encoding: .utf8) else { return data }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("\u{feff}") { s.removeFirst() }
        if let start = s.firstIndex(where: { $0 == "{" || $0 == "[" }),
           let end = s.lastIndex(where: { $0 == "}" || $0 == "]" }) {
            s = String(s[start...end])
        }
        return Data(s.utf8)
    }
}

enum NetError: LocalizedError {
    case badURL(String)
    case status(Int, String)
    case empty
    case decode(String, String)

    var errorDescription: String? {
        switch self {
        case .badURL(let u): return "地址无效：\(u)"
        case .status(let c, let u): return "HTTP \(c) — \(u)"
        case .empty: return "返回内容为空"
        case .decode(let e, let body): return "解析失败：\(e)\n\(body)"
        }
    }
}

// MARK: - 配置拉取专用
// 配置地址的可用 UA 五花八门：有的源站只认浏览器，有的只认 okhttp，
// 还有的按 Dalvik 放行。挨个试，谁能拿到 JSON 就用谁。
extension Net {

    static let configUAs = [
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        "okhttp/3.12.13",
        "Dalvik/2.1.0 (Linux; U; Android 9; MI 8 Build/PKQ1.180729.001)",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    ]

    func fetchConfigData(_ urlString: String) async throws -> Data {
        let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString
        guard let url = URL(string: encoded) else { throw NetError.badURL(urlString) }

        var log: [String] = []
        for ua in Net.configUAs {
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 15
                req.setValue(ua, forHTTPHeaderField: "User-Agent")
                req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
                let (data, resp) = try await session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 && !data.isEmpty && Net.looksLikeJSON(data) {
                    return data
                }
                let head = (String(data: data.prefix(60), encoding: .utf8) ?? "")
                    .replacingOccurrences(of: "\n", with: " ")
                log.append("\(ua.prefix(14))…  HTTP \(code)  \(head)")
            } catch {
                log.append("\(ua.prefix(14))…  \(error.localizedDescription)")
            }
        }
        throw NetError.decode("配置地址没返回 JSON", log.joined(separator: "\n"))
    }

    static func looksLikeJSON(_ data: Data) -> Bool {
        guard let s = String(data: data.prefix(400), encoding: .utf8) else { return false }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{feff}", with: "")
        if t.hasPrefix("{") || t.hasPrefix("[") { return true }
        // 整体是 base64 的配置：够长、不含标签、字符集对得上
        if t.count > 40 && !t.contains("<") {
            let allowed = CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=\n\r ")
            if t.unicodeScalars.allSatisfy({ allowed.contains($0) }) { return true }
        }
        return false
    }

    /// 把响应开头打出来，HTML 单独提示——能直接看出是 403 页、验证页还是空
    static func preview(_ data: Data, limit: Int = 400) -> String {
        guard let s = String(data: data.prefix(2000), encoding: .utf8) else {
            let hex = data.prefix(16).map { String(format: "%02x", Int($0)) }.joined()
            return "（响应不是 UTF-8 文本，前 16 字节 \(hex)）"
        }
        let low = s.lowercased()
        if low.contains("<html") || low.contains("<!doctype") {
            return "返回的是网页不是 JSON，源站拦了请求：\n" + String(s.prefix(limit))
        }
        return String(s.prefix(limit))
    }

    /// JSON5 清洗：去掉 // 与 /* */ 注释、对象/数组尾部的多余逗号。
    /// 字符串内部原样保留，避免把 URL 里的 // 当注释砍掉。
    static func sanitize(_ input: String) -> String {
        var noComment = ""
        noComment.reserveCapacity(input.count)
        var i = input.startIndex
        var inStr = false
        var quote: Character = "\""
        var esc = false

        while i < input.endIndex {
            let ch = input[i]

            if inStr {
                noComment.append(ch)
                if esc { esc = false }
                else if ch == "\\" { esc = true }
                else if ch == quote { inStr = false }
                i = input.index(after: i)
                continue
            }

            if ch == "\"" || ch == "'" {
                inStr = true
                quote = ch
                noComment.append(ch)
                i = input.index(after: i)
                continue
            }

            if ch == "/" {
                let n = input.index(after: i)
                if n < input.endIndex && input[n] == "/" {
                    var j = n
                    while j < input.endIndex && input[j] != "\n" { j = input.index(after: j) }
                    i = j
                    continue
                }
                if n < input.endIndex && input[n] == "*" {
                    var j = input.index(after: n)
                    while j < input.endIndex {
                        if input[j] == "*" {
                            let k = input.index(after: j)
                            if k < input.endIndex && input[k] == "/" {
                                j = input.index(after: k)
                                break
                            }
                        }
                        j = input.index(after: j)
                    }
                    i = j
                    continue
                }
            }

            noComment.append(ch)
            i = input.index(after: i)
        }

        // 第二遍：删掉 } 或 ] 前面的逗号
        let chars = Array(noComment)
        var out = ""
        out.reserveCapacity(chars.count)
        var inStr2 = false
        var q2: Character = "\""
        var esc2 = false
        var idx = 0

        while idx < chars.count {
            let c = chars[idx]
            if inStr2 {
                out.append(c)
                if esc2 { esc2 = false }
                else if c == "\\" { esc2 = true }
                else if c == q2 { inStr2 = false }
                idx += 1
                continue
            }
            if c == "\"" || c == "'" {
                inStr2 = true
                q2 = c
                out.append(c)
                idx += 1
                continue
            }
            if c == "," {
                var k = idx + 1
                while k < chars.count && (chars[k] == " " || chars[k] == "\n"
                                          || chars[k] == "\r" || chars[k] == "\t") {
                    k += 1
                }
                if k < chars.count && (chars[k] == "}" || chars[k] == "]") {
                    idx += 1
                    continue
                }
            }
            out.append(c)
            idx += 1
        }

        return out
    }
}

/// 自签证书 / 过期证书直通
final class TrustAllDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
