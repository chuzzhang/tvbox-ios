import Foundation
import SwiftUI

final class AppState: ObservableObject {

    @Published var configText: String = UserDefaults.standard.string(forKey: "cfg.url") ?? ""
    @Published var config: BoxConfig? = nil
    @Published var loading = false
    @Published var errorMessage: String? = nil
    /// 详细的失败原文，弹窗关掉后仍留在配置页，方便长按复制
    @Published var lastErrorDetail: String? = nil
    @Published var selectedSiteKey: String? = nil
    /// 顶层 spider 的加载结果，脚本型站点全靠它
    @Published var spiderReport: SpiderStore.Report? = nil
    /// 配置文件所在目录，配置里的 ./jar、./json 都要相对它解析
    @Published var configBase: String = UserDefaults.standard.string(forKey: "cfg.base") ?? ""

    @Published var history: [VItem] = []
    @Published var favorites: [VItem] = []

    /// 配置页那四个开关。默认只开 CMS 和 js，python / jar 现在跑不了，默认关。
    /// 存 UserDefaults：换配置、重启都不该把用户的勾选重置掉。
    @Published var enabledKinds: Set<SiteKind> = AppState.loadKinds()

    private let ud = UserDefaults.standard

    init() {
        history = Self.loadList("list.history")
        favorites = Self.loadList("list.fav")
        if let dead = UserDefaults.standard.array(forKey: "site.dead") as? [String] {
            deadSiteKeys = Set(dead)
        }
        if !configText.isEmpty {
            Task { await refreshConfig(silent: true) }
        }
    }

    var sites: [Site] {
        var seen = Set<String>()
        let list = (config?.sites ?? []).filter { s in
            guard s.isUsable, enabledKinds.contains(s.kind), !seen.contains(s.id) else { return false }
            seen.insert(s.id)
            return true
        }
        // CMS 站排前面：脚本站在 iOS 上要看 jar 里有没有 js，能用的概率低
        return list.filter { $0.isCMSRoute } + list.filter { !$0.isCMSRoute }
    }

    /// 配置里有站点，但被开关全滤掉了 —— 首页要提示去配置页开，而不是说"没有站点"
    var filteredOutAll: Bool {
        let all = (config?.sites ?? []).filter { $0.isUsable }
        return !all.isEmpty && sites.isEmpty
    }

    /// 某一类在配置里有多少个（不受开关影响，用来显示在开关右边）
    func count(of kind: SiteKind) -> Int {
        var seen = Set<String>()
        return (config?.sites ?? []).reduce(0) { n, s in
            guard s.isUsable, s.kind == kind, !seen.contains(s.id) else { return n }
            seen.insert(s.id)
            return n + 1
        }
    }

    /// 配置里可用站点总数，不受开关影响。配置页显示「已导入 x / y」用。
    var totalSiteCount: Int {
        var seen = Set<String>()
        return (config?.sites ?? []).reduce(0) { n, s in
            guard s.isUsable, !seen.contains(s.id) else { return n }
            seen.insert(s.id)
            return n + 1
        }
    }

    func setKind(_ kind: SiteKind, on: Bool) {
        if on { enabledKinds.insert(kind) } else { enabledKinds.remove(kind) }
        ud.set(enabledKinds.map(\.rawValue).sorted(), forKey: "site.kinds")
        // 当前选中的站点可能刚被关掉，换一个，不然首页直接空白
        ensureSelection()
    }

    /// 当前选中的站点还在可选列表里就保持，否则落到第一个 CMS 站
    func ensureSelection() {
        if let k = selectedSiteKey, sites.contains(where: { $0.key == k }) { return }
        selectedSiteKey = sites.first(where: { $0.isCMSRoute })?.key ?? sites.first?.key
    }

    private static func loadKinds() -> Set<SiteKind> {
        // 键不存在（首次启动）用默认；存在但被清空（用户全关掉）要尊重，不能回填
        guard let raw = UserDefaults.standard.array(forKey: "site.kinds") as? [String] else {
            return SiteKind.defaultEnabled
        }
        return Set(raw.compactMap { SiteKind(rawValue: $0) })
    }

    var selectedSite: Site? {
        if let k = selectedSiteKey, let s = sites.first(where: { $0.key == k }) { return s }
        return sites.first
    }

    @MainActor
    func refreshConfig(silent: Bool = false) async {
        guard !configText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !silent { loading = true }
        errorMessage = nil
        do {
            let cfg = try await ConfigLoader.load(configText)
            guard ConfigLoader.hasSites(cfg) else {
                throw NetError.decode("配置里没有可用站点",
                                      "共 \(cfg.sites?.count ?? 0) 个站点，api 与 ext 都为空")
            }
            // 配置里的相对路径要相对配置地址解析，先算基准再让界面读配置
            configBase = cfg.resolvedBase.isEmpty ? URLKit.base(configText) : cfg.resolvedBase
            ud.set(configBase, forKey: "cfg.base")

            config = cfg
            ud.set(configText, forKey: "cfg.url")
            if selectedSiteKey == nil || !sites.contains(where: { $0.key == selectedSiteKey }) {
                // 只在勾选的类别里挑：优先 CMS，其次第一个没被标死的脚本站
                let alive = sites.filter { !deadSiteKeys.contains($0.key) }
                let pool = alive.isEmpty ? sites : alive
                selectedSiteKey = (pool.first { $0.isCMSRoute } ?? pool.first)?.key
            }

            // 顶层 spider 后台加载，不挡住配置显示
            let spiderField = cfg.spider
            let base = configBase
            Task { @MainActor in
                spiderReport = await SpiderStore.shared.report(for: spiderField, base: base)
            }
        } catch {
            let msg = error.localizedDescription
            errorMessage = msg
            lastErrorDetail = msg + "\n\n[地址] " + configText
        }
        loading = false
    }

    func select(_ site: Site) {
        selectedSiteKey = site.key
    }

    /// 已经确认跑不起来的站点（脚本 401/404、缺 dex 等），本地记着，免得每次自动落到它身上
    @Published var deadSiteKeys: Set<String> = []

    func markDead(_ key: String) {
        deadSiteKeys.insert(key)
        ud.set(Array(deadSiteKeys), forKey: "site.dead")
    }

    /// 换到下一个能用的站点：先看 CMS 站（成功率最高），再退到没被标记的脚本站
    @discardableResult
    func switchToNextSite() -> Site? {
        let alive = sites.filter { !deadSiteKeys.contains($0.key) }
        let cms = alive.filter { $0.isCMSRoute }
        if let s = cms.first(where: { $0.key != selectedSiteKey }) {
            selectedSiteKey = s.key
            return s
        }
        if let s = alive.first(where: { $0.key != selectedSiteKey }) {
            selectedSiteKey = s.key
            return s
        }
        return nil
    }

    // MARK: - 历史 / 收藏

    func markPlayed(_ item: VItem) {
        history.removeAll { $0.vod_id == item.vod_id }
        history.insert(item, at: 0)
        if history.count > 60 { history = Array(history.prefix(60)) }
        Self.saveList(history, "list.history")
    }

    func toggleFavorite(_ item: VItem) {
        if let i = favorites.firstIndex(where: { $0.vod_id == item.vod_id }) {
            favorites.remove(at: i)
        } else {
            favorites.insert(item, at: 0)
        }
        Self.saveList(favorites, "list.fav")
    }

    func isFavorite(_ item: VItem) -> Bool {
        favorites.contains { $0.vod_id == item.vod_id }
    }

    private static func saveList(_ list: [VItem], _ key: String) {
        if let d = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }

    private static func loadList(_ key: String) -> [VItem] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder().decode([VItem].self, from: d) else { return [] }
        return v
    }
}
