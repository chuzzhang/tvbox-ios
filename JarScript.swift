import Foundation
import ZIPFoundation

/// spider 脚本解析：type 3/4 站点的 api 可能指向 .js，也可能指向 .jar。
/// iOS 禁止 DexClassLoader 动态加载可执行代码，jar 里的 dex 跑不了，
/// 但 TVBox 生态里相当一部分 jar 同时内置了 js 版实现 —— 从 jar 里抽出来用 JS 引擎跑。
enum ScriptResolver {

    struct Resolved {
        var lib: String?
        var code: String
        var source: String
    }

    static func resolve(_ site: Site) async throws -> Resolved {
        let api = site.api.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = api.lowercased()

        if lower.hasSuffix(".js") {
            let code = try await Net.shared.fetchText(api)
            return Resolved(lib: bundledLib(), code: code, source: "remote:\(api)")
        }

        if lower.hasSuffix(".jar") {
            let data = try await Net.shared.fetch(api, timeout: 30)
            if let js = extractJS(from: data) {
                return Resolved(lib: bundledLib(), code: js.text, source: "jar:\(js.name)")
            }
            throw NetError.decode(
                "jar 内没有可用的 js 实现",
                "该站点只能在 Android 上跑 dex spider。替代做法：在配置里把该站换成一个 CMS 接口或 js 版来源。"
            )
        }

        if let local = bundledSpider() {
            return Resolved(lib: bundledLib(), code: local, source: "bundle:spider.js")
        }

        throw NetError.decode(
            "没有可执行的脚本",
            "把对应 spider.js 放进 Resources（命名 spider.js），或把该站 api 改成 .js 直链。"
        )
    }

    // MARK: - jar 内抽 js

    private static func extractJS(from data: Data) -> (name: String, text: String)? {
        guard let archive = try? Archive(data: data, accessMode: .read) else { return nil }

        var candidates: [(name: String, text: String, score: Int)] = []

        for entry in archive where entry.type == .file {
            let name = entry.path
            guard name.lowercased().hasSuffix(".js") else { continue }
            guard entry.uncompressedSize > 0, entry.uncompressedSize < 8 * 1024 * 1024 else { continue }
            var buf = Data()
            guard (try? archive.extract(entry) { buf.append($0) }) != nil else { continue }
            guard let text = String(data: buf, encoding: .utf8), !text.isEmpty else { continue }

            // 按 TVBox spider 契约打分：实现得越全越优先
            var score = 0
            for key in ["homeContent", "categoryContent", "detailContent", "searchContent", "var rule", "rule="] {
                if text.contains(key) { score += 1 }
            }
            if score > 0 { candidates.append((name, text, score)) }
        }

        // 单文件得分最高者；同分取体积大的（通常是主实现而非 polyfill）
        return candidates
            .sorted { a, b in a.score == b.score ? a.text.count > b.text.count : a.score > b.score }
            .first
            .map { ($0.name, $0.text) }
    }

    // MARK: - 内置资源

    static func bundledLib() -> String? {
        guard let u = Bundle.main.url(forResource: "cat", withExtension: "js") else { return nil }
        return try? String(contentsOf: u, encoding: .utf8)
    }

    static func bundledSpider() -> String? {
        guard let u = Bundle.main.url(forResource: "spider", withExtension: "js") else { return nil }
        return try? String(contentsOf: u, encoding: .utf8)
    }
}
