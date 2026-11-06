import Foundation

// MARK: - 配置加载（兼容明文 JSON / Base64 / urls 多仓）
enum ConfigLoader {

    static func load(_ raw: String) async throws -> BoxConfig {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NetError.empty }

        // 直接贴 JSON
        if text.hasPrefix("{") || text.hasPrefix("[") {
            return try decodeConfig(Data(text.utf8))
        }

        // 贴的是 Base64
        if let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters),
           let s = String(data: data, encoding: .utf8),
           s.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
            return try decodeConfig(Data(s.utf8))
        }

        // 网络拉取：内部会按多个 UA 依次试
        let body = try await Net.shared.fetchConfigData(encode(text))
        if var cfg = try? decodeConfig(body), hasSites(cfg) {
            cfg.resolvedBase = URLKit.base(text)
            return cfg
        }

        // 多仓格式：{"urls":[{"url":"...","name":"..."}]}
        if let multi = try? JSONDecoder().decode(MultiRepo.self, from: Net.stripJSONNoise(body)),
           let list = multi.urls, !list.isEmpty {
            var tried: [String] = []
            for r in list {
                let label = r.name ?? r.url
                guard let inner = try? await Net.shared.fetchConfigData(encode(r.url)),
                      var sub = try? decodeConfig(inner) else {
                    tried.append("\(label) → 拉取失败")
                    continue
                }
                if hasSites(sub) {
                    // 子仓自己的相对路径以子仓地址为基准，用主配置地址会全错
                    sub.resolvedBase = URLKit.base(r.url)
                    return sub
                }
                tried.append("\(label) → 解析到了但没站点")
            }
            throw NetError.decode("多仓里 \(list.count) 个子仓都不可用", tried.joined(separator: "\n"))
        }

        // 整体 Base64 响应
        if let s = String(data: body, encoding: .utf8),
           let d = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines), options: .ignoreUnknownCharacters),
           let cfg = try? decodeConfig(d), hasSites(cfg) {
            return cfg
        }

        // 结构对不上，把原文和站点计数一并抛出去
        let cfg = try decodeConfig(body)
        throw NetError.decode(
            "配置里没有可用站点",
            "读到 \(cfg.sites?.count ?? 0) 个站点，api 和 ext 全为空\n\n" + Net.preview(body)
        )
    }

    static func hasSites(_ c: BoxConfig) -> Bool {
        (c.sites ?? []).contains { $0.isUsable }
    }

    private static func decodeConfig(_ data: Data) throws -> BoxConfig {
        let cleaned = Net.stripJSONNoise(data)

        // 1. 原样解
        if let cfg = try? JSONDecoder().decode(BoxConfig.self, from: cleaned) { return cfg }

        // 2. 去注释 / 去尾逗号后再试（很多配置是 JSON5 风格）
        if let text = String(data: cleaned, encoding: .utf8) {
            let fixed = Net.sanitize(text)
            if let d = fixed.data(using: .utf8),
               let cfg = try? JSONDecoder().decode(BoxConfig.self, from: d) { return cfg }
        }

        // 3. 顶层直接是站点数组
        if let arr = try? JSONDecoder().decode([Site].self, from: cleaned) {
            var cfg = BoxConfig()
            cfg.sites = arr
            return cfg
        }

        // 4. 都不行，把真实原因和原文片段抛出去
        do {
            _ = try JSONDecoder().decode(BoxConfig.self, from: cleaned)
        } catch {
            throw NetError.decode("不是合法的 TVBox 配置：\(error)", Net.preview(cleaned))
        }
        throw NetError.decode("配置格式无法识别", Net.preview(cleaned))
    }

    /// 中文/空格路径的容错编码
    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}

struct MultiRepo: Codable {
    struct Repo: Codable {
        var url: String
        var name: String?
    }
    var urls: [Repo]?
}

// MARK: - CMS 接口客户端（type 0 / 1）
struct CMSApi {
    let base: String
    var headers: [String: String] = [:]

    /// 拼接参数，自动判断 base 里是否已有 query
    private func url(_ params: [String: String]) -> String {
        let sep = base.contains("?") ? "&" : "?"
        let q = params
            .map { k, v in "\(k)=\(ConfigLoader.encode(v))" }
            .joined(separator: "&")
        return base + sep + q
    }

    /// 分类列表
    func categories() async throws -> [VCategory] {
        let data = try await Net.shared.fetch(url(["ac": "list"]), headers: headers)

        if CMSXml.looksLikeXML(data) {
            let cats = CMSXml.list(data).cats
            // XML 源的 <class> 经常是空的（只给 tid 不给名字），至少留一个「全部」当兜底
            return cats.isEmpty ? [VCategory(type_id: "", type_name: "全部", type_pid: nil)] : cats
        }

        if let resp = try? JSONDecoder().decode(CMSListResponse.self, from: Net.stripJSONNoise(data)),
           let c = resp.class, !c.isEmpty {
            return c
        }

        // 部分源 ac=list 不返回 class，用 detail 首页兜底
        let d2 = try await Net.shared.fetch(url(["ac": "detail"]), headers: headers)
        if CMSXml.looksLikeXML(d2) {
            let cats = CMSXml.list(d2).cats
            if !cats.isEmpty { return cats }
            return [VCategory(type_id: "", type_name: "全部", type_pid: nil)]
        }
        let resp2 = try JSONDecoder().decode(CMSListResponse.self, from: Net.stripJSONNoise(d2))
        return resp2.class ?? []
    }

    /// 分类内容分页
    func list(tid: String, page: Int) async throws -> (items: [VItem], pagecount: Int) {
        var params: [String: String] = ["ac": "videolist", "pg": String(page)]
        // 没有分类（XML 源常见）时不传 t，接口默认给全量
        if !tid.isEmpty { params["t"] = tid }

        var r = try await loadList(params)
        if r.items.isEmpty {
            var alt = params
            alt["ac"] = "detail"
            let r2 = try await loadList(alt)
            if !r2.items.isEmpty { r = r2 }
        }
        return (r.items, r.pageCount)
    }

    /// 详情
    func detail(id: String) async throws -> VDetail? {
        let data = try await Net.shared.fetch(url(["ac": "detail", "ids": id]), headers: headers)
        if CMSXml.looksLikeXML(data) { return CMSXml.detail(data) }
        let resp = try JSONDecoder().decode(CMSDetailResponse.self, from: Net.stripJSONNoise(data))
        return resp.list?.first
    }

    /// 搜索
    func search(wd: String, page: Int = 1) async throws -> [VItem] {
        var params: [String: String] = ["wd": wd, "ac": "videolist", "pg": String(page)]
        var items = try await loadList(params).items
        if items.isEmpty {
            params["ac"] = "detail"
            items = try await loadList(params).items
        }
        return items
    }

    // MARK: 取数（JSON / XML 两种口径）

    private func loadList(_ params: [String: String]) async throws -> (items: [VItem], pageCount: Int) {
        let data = try await Net.shared.fetch(url(params), headers: headers)

        if CMSXml.looksLikeXML(data) {
            let r = CMSXml.list(data)
            return (r.items, r.pageCount)
        }

        do {
            let resp = try JSONDecoder().decode(CMSListResponse.self, from: Net.stripJSONNoise(data))
            return (resp.list ?? [], max(resp.pagecount ?? 1, 1))
        } catch {
            // 有的源 Content-Type 写着 json，内容还是 xml（`Unexpected character 'C'` 那种）
            let r = CMSXml.list(data)
            if !r.items.isEmpty { return (r.items, r.pageCount) }
            throw NetError.decode(String(describing: error),
                                  String(decoding: data.prefix(200), as: UTF8.self))
        }
    }
}

