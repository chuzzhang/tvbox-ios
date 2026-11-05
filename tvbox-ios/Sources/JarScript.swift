import Foundation
import ZIPFoundation

/// 把站点解析成「要执行的 js 段」。
///
/// 解析顺序（前一条命中就不再往下走）：
/// 1. ext 是 drpy 规则（JSON / .json / .js 规则）→ 内置 drpy 解释器
/// 2. api 指向 drpy 框架库 → 从 ext 取规则，同样走解释器
/// 3. api 是 js 直链 → 下载执行
/// 4. api 是 jar → 抽包内 js
/// 5. 以上都没有 → 配置顶层 spider
/// 6. 最后 → 内置 Resources/spider.js
///
/// 所有地址先按配置文件的 URL 解析相对路径：`./jar/x.jar`、`./json/x.json`
/// 这类写法在原版 TVBox 里是相对配置地址的，不解析就是死路径。
enum ScriptResolver {

    struct Resolved {
        var scripts: [String]
        var source: String
        /// 逐条解析过程，失败时直接显示给用户，省得靠猜
        var diagnostics: String
    }

    /// 同一站点的脚本没必要每次搜索/进页面都重下一次
    private static let cacheLock = NSLock()
    private static var cache: [String: Resolved] = [:]

    static func resolve(_ site: Site,
                        spider: SpiderStore.Report?,
                        base: String? = nil) async throws -> Resolved {
        let key = "\(site.key)|\(site.api)|\(Drpy.extText(site.ext))|\(base ?? "")"
        cacheLock.lock()
        if let hit = cache[key] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        let r = try await resolveUncached(site, spider: spider, base: base)
        cacheLock.lock()
        cache[key] = r
        cacheLock.unlock()
        return r
    }

    private static func resolveUncached(_ site: Site,
                                        spider: SpiderStore.Report?,
                                        base: String? = nil) async throws -> Resolved {

        var notes: [String] = []
        let apiRaw = site.api.trimmingCharacters(in: .whitespacesAndNewlines)
        let api = URLKit.resolve(SpiderStore.stripSuffix(apiRaw), base: base)
        let extText = Drpy.extText(site.ext)

        notes.append("站点 key=\(site.key)  type=\(site.type)")
        notes.append("api=\(apiRaw.isEmpty ? "（空）" : apiRaw)")
        if api != apiRaw, !api.isEmpty { notes.append("api 解析为：\(api)") }
        if !extText.isEmpty {
            let brief = extText.count > 90 ? String(extText.prefix(90)) + "…" : extText
            notes.append("ext=\(brief)")
        }

        // 1) Pyramid（python 版 TVBox）：api 是 `py_xxx`，规则或脚本在 ext 里。
        //    规则型和 drpy 同源（htmlParser.py 的 pdfa/pdfh/pd 与 cat.js 是一套），
        //    解释器直接吃；脚本型是完整的 .py 程序，要 CPython。
        if site.isPyramid {
            notes.append("pyramid 站点（python 版 TVBox 的规则体系，api 不是 URL）")
            let pyScriptLike = extText.lowercased().hasSuffix(".py")
                || (extText.contains("import ") && extText.contains("def ")
                    && !extText.hasPrefix("{"))
            if pyScriptLike {
                notes.append("ext 是 python 脚本：iOS 没有 CPython 运行时，也没有 lxml/pyquery/requests 那套依赖")
                notes.append("把这段 .py 的逻辑改写成等价 js 规则（或换同源的 js 版站点）才能在本机跑")
                throw NetError.decode("站点「\(site.name)」是 python 脚本站点", notes.joined(separator: "\n"))
            }
            if extText.isEmpty {
                notes.append("站点没给 ext —— pyramid 站点靠 ext 承载规则，缺了在 Android 上同样跑不起来")
            } else {
                let attempt = await Drpy.load(site: site, apiURL: "", base: base)
                notes.append(contentsOf: attempt.notes)
                if let r = attempt.result {
                    notes.append("脚本来源：\(r.source)")
                    return Resolved(scripts: r.scripts, source: r.source,
                                    diagnostics: notes.joined(separator: "\n"))
                }
            }
        }

        // 2 / 3) drpy 规则站点
        let extIsRuleFile = URLKit.looksLikeURL(extText) && !extText.hasPrefix("{")
            && (extText.lowercased().contains(".json") || extText.lowercased().contains(".js"))
        let extIsJSON = extText.hasPrefix("{")
        let extLooksRule = extIsJSON && Drpy.looksLikeRule(extText)
        if !extText.isEmpty && (extIsRuleFile || extLooksRule || Drpy.isFramework(api) || Drpy.isFramework(apiRaw)) {
            let attempt = await Drpy.load(site: site, apiURL: api, base: base)
            notes.append(contentsOf: attempt.notes)
            if let r = attempt.result {
                notes.append("脚本来源：\(r.source)")
                return Resolved(scripts: r.scripts, source: r.source,
                                diagnostics: notes.joined(separator: "\n"))
            }
        } else if extText.isEmpty && (Drpy.isFramework(api) || Drpy.isFramework(apiRaw)) {
            notes.append("api 是 drpy 框架库，但站点没给 ext 规则 —— 这份配置在 Android TVBox 上同样跑不起来")
        }

        // 3 / 4) 站点自带脚本
        if api.lowercased().hasPrefix("http") {
            let lower = api.lowercased()
            if lower.contains(".js") {
                do {
                    let got = try await Net.shared.fetchScriptTracked(api)
                    if let m = got.mirror { notes.append("站点脚本改用镜像：\(m)") }
                    let data = got.data
                    let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                    if !text.isEmpty {
                        if Drpy.looksLikeRule(text) || Drpy.isFramework(api) {
                            notes.append("站点 js 是 drpy 框架库/规则，改用解释器")
                            let attempt = await Drpy.load(site: site, apiURL: api, base: base)
                            notes.append(contentsOf: attempt.notes)
                            if let r = attempt.result {
                                notes.append("脚本来源：\(r.source)")
                                return Resolved(scripts: r.scripts, source: r.source,
                                                diagnostics: notes.joined(separator: "\n"))
                            }
                            notes.append("drpy 解释器也没能组出脚本（多半是缺 ext 规则）")
                        } else {
                            notes.append("使用站点自带 js：\(text.count / 1024) KB")
                            return Resolved(scripts: [text], source: "site.js",
                                            diagnostics: notes.joined(separator: "\n"))
                        }
                    } else {
                        notes.append("站点 api 指向的 js 是空文件")
                    }
                } catch {
                    notes.append("站点脚本下载失败：\(error.localizedDescription)")
                }
            } else if lower.contains(".jar") {
                do {
                    let got = try await Net.shared.fetchScriptTracked(api)
                    if let m = got.mirror { notes.append("站点 jar 改用镜像：\(m)") }
                    let data = got.data
                    let ex = SpiderStore.extract(data, preferKey: site.key)
                    if !ex.scripts.isEmpty {
                        notes.append("站点 jar 内抽到 \(ex.scripts.count) 段 js：\(ex.jsNames.prefix(3).joined(separator: ", "))")
                        return Resolved(scripts: ex.scripts, source: "site.jar",
                                        diagnostics: notes.joined(separator: "\n"))
                    }
                    let dexCount = ex.entries.filter { $0.lowercased().hasSuffix(".dex") }.count
                    notes.append("站点 jar 内 \(ex.entries.count) 个文件，没有 js（dex \(dexCount) 个）")
                    for info in ex.dex {
                        notes.append("包内 \(info.classNames.count) 个类 / \(info.methodCount) 个方法"
                            + (info.obscuredCount > 0 ? "（\(info.obscuredCount) 个是混淆后的 jsoup）" : ""))
                        let cls = info.siteClasses
                        if !cls.isEmpty {
                            notes.append("jar 支持的站点类：" + cls.prefix(12).joined(separator: ", ")
                                + (cls.count > 12 ? " …共 \(cls.count) 个" : ""))
                        }
                        notes.append("dex 外部依赖：" + info.dependencyLine)
                        notes.append(info.isPlainJava
                            ? "依赖面只有标准库，站点逻辑可以被 js 重写"
                            : "依赖了第三方网络库/并发框架，iOS 上无法靠 js 替代执行")
                    }
                } catch {
                    notes.append("站点 jar 下载失败：\(error.localizedDescription)")
                }
            }
        }

        // 5) 配置顶层 spider
        if let sp = spider {
            notes.append(sp.summary)
            if !sp.entries.isEmpty {
                notes.append("spider 包内文件：" + sp.entries.prefix(12).joined(separator: ", "))
            }
            if let b = sp.bundle, !b.scripts.isEmpty {
                notes.append("使用顶层 spider：\(b.source)")
                return Resolved(scripts: b.scripts, source: b.source,
                                diagnostics: notes.joined(separator: "\n"))
            }
            // 加固包（.guard + wexguard_*.so）：包里的 dex 是空壳，真逻辑在加密段里。
            // 这种情况再往下走只会落到「缺可执行脚本」，对排查没有帮助，直接给结论。
            if GuardSites.hasGuardPayload(sp.entries) || (GuardSites.isGuard(api: apiRaw) && !sp.entries.isEmpty) {
                notes.append(contentsOf: GuardSites.verdict(entries: sp.entries, dex: []))
                throw NetError.decode("站点「\(site.name)」跑在加固 spider 包里", notes.joined(separator: "\n"))
            }
        } else {
            notes.append("顶层 spider 尚未加载")
        }

        // 6) 内置脚本（用户把 spider.js 放进 Resources 时生效）
        if let local = bundledSpider() {
            notes.append("使用内置 Resources/spider.js")
            return Resolved(scripts: [local], source: "bundle:spider.js",
                            diagnostics: notes.joined(separator: "\n"))
        }

        notes.append("—— 结论：这个站点在 iOS 上缺可执行的脚本")
        // 把「上游文件没了」和「客户端实现不了」分开写，不然永远在猜
        let upstreamGone = notes.contains { $0.contains("HTTP 401") || $0.contains("HTTP 404") }
        if upstreamGone {
            notes.append("直接原因在上游：规则/脚本文件在服务器上已取不到（401 鉴权或 404 不存在），")
            notes.append("用 Android 版 TVBox 打开同一站点也是同样的报错。换站点或换配置，改客户端没有用。")
        }
        if GuardSites.isGuard(api: apiRaw) {
            notes.append("站点 api `\(apiRaw)` 是加固壳的类名（Wex / AI 卫士系），真逻辑在顶层 spider 包的 .guard 加密段里，")
            notes.append("dex 里那 143 个 XxxGuard 类是空的，接口地址反编译不出来。")
        }
        if extText.isEmpty && site.type == 3 && !upstreamGone {
            notes.append("站点既没有 js/jar 直链，也没有 ext 规则；它的实现应该在顶层 spider 的 dex 里。")
        }
        if !upstreamGone {
            notes.append("classes.dex 是 Dalvik 指令集，要 ART 运行时；iOS 只有 arm64 Mach-O 且禁 JIT，")
            notes.append("所以 jar 里带 js 的能用，只有 dex 的不能用。")
            notes.append("换成 CMS 站点（type 0/1）、js spider 站点、或带 ext 规则的 drpy 站点。")
        }
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
