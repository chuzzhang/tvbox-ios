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

    @Published var history: [VItem] = []
    @Published var favorites: [VItem] = []

    private let ud = UserDefaults.standard

    init() {
        history = Self.loadList("list.history")
        favorites = Self.loadList("list.fav")
        if !configText.isEmpty {
            Task { await refreshConfig(silent: true) }
        }
    }

    var sites: [Site] {
        var seen = Set<String>()
        let list = (config?.sites ?? []).filter { s in
            guard s.isUsable, !seen.contains(s.id) else { return false }
            seen.insert(s.id)
            return true
        }
        // CMS 站排前面：脚本站在 iOS 上要看 jar 里有没有 js，能用的概率低
        return list.filter { $0.isCMSRoute } + list.filter { !$0.isCMSRoute }
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
            config = cfg
            ud.set(configText, forKey: "cfg.url")
            if selectedSiteKey == nil {
                // 优先落到 CMS 站：脚本站在 iOS 上受 jar 限制，CMS 站基本都能出内容
                let usable = (cfg.sites ?? []).filter { $0.isUsable }
                selectedSiteKey = (usable.first { $0.isCMSRoute } ?? usable.first)?.key
            }

            // 顶层 spider 后台加载，不挡住配置显示
            let spiderField = cfg.spider
            Task { @MainActor in
                spiderReport = await SpiderStore.shared.report(for: spiderField)
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
