import Foundation
import ZIPFoundation

/// 把站点解析成「要执行的 js 段」。
///
/// 优先级：站点自带的 js/jar → 配置顶层 spider → 内置 Resources/spider.js。
/// 真实配置里 type 3 站点的 api 多数是 `csp_xxx` 这种标识符，脚本来自顶层 spider，
/// 所以顶层 spider 必须参与，否则每个脚本型站点都会落空。
enum ScriptResolver {

    struct Resolved {
        var scripts: [String]
        var source: String
        /// 逐条解析过程，失败时直接显示给用户，省得靠猜
        var diagnostics: String
    }

    static func resolve(_ site: Site, spider: SpiderStore.Report?) async throws -> Resolved {
        var notes: [String] = []
        let api = site.api.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = api.lowercased()
        notes.append("站点 key=\(site.key)  type=\(site.type)")
        notes.append("api=\(api.isEmpty ? "（空）" : api)")

        // 1) 站点自己的脚本
        if lower.hasPrefix("http") {
            if lower.contains(".js") {
                do {
                    let text = try await Net.shared.fetchText(api)
                    if !text.isEmpty {
                        notes.append("使用站点自带 js：\(text.count / 1024) KB")
                        return Resolved(scripts: [text], source: "site.js", diagnostics: notes.joined(separator: "\n"))
                    }
                    notes.append("站点 api 指向的 js 是空文件")
                } catch {
                    notes.append("站点脚本下载失败：\(error.localizedDescription)")
                }
            } else if lower.contains(".jar") {
                do {
                    let data = try await Net.shared.fetch(api, timeout: 40)
                    let ex = SpiderStore.extract(data, preferKey: site.key)
                    if !ex.scripts.isEmpty {
                        notes.append("站点 jar 内抽到 \(ex.scripts.count) 段 js：\(ex.jsNames.prefix(3).joined(separator: ", "))")
                        return Resolved(scripts: ex.scripts, source: "site.jar", diagnostics: notes.joined(separator: "\n"))
                    }
                    notes.append("站点 jar 内 \(ex.entries.count) 个文件，没有 js")
                } catch {
                    notes.append("站点 jar 下载失败：\(error.localizedDescription)")
                }
            }
        }

        // 2) 配置顶层 spider
        if let sp = spider {
            notes.append(sp.summary)
            if !sp.entries.isEmpty {
                notes.append("spider 包内文件：" + sp.entries.prefix(12).joined(separator: ", "))
            }
            if let b = sp.bundle, !b.scripts.isEmpty {
                return Resolved(scripts: b.scripts, source: b.source, diagnostics: notes.joined(separator: "\n"))
            }
        } else {
            notes.append("顶层 spider 尚未加载")
        }

        // 3) 内置脚本（用户把 spider.js 放进 Resources 时生效）
        if let local = bundledSpider() {
            notes.append("使用内置 Resources/spider.js")
            return Resolved(scripts: [local], source: "bundle:spider.js", diagnostics: notes.joined(separator: "\n"))
        }

        notes.append("—— 结论：这个站点在 iOS 上缺可执行的脚本")
        notes.append("纯 dex 的 jar spider 需要 Android 运行时，iOS 没有对应实现；")
        notes.append("换成 CMS 站点（type 0/1）或 js spider 站点才能用。")
        throw NetError.decode("站点「\(site.name)」没有可执行的脚本", notes.joined(separator: "\n"))
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
