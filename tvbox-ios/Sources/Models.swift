import Foundation

// MARK: - 任意 JSON（配置里的 ext 既可能是字符串也可能是对象）
enum JSONAny: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONAny])
    case object([String: JSONAny])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONAny].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONAny].self) { self = .object(v); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        default: return nil
        }
    }
}

// MARK: - 配置结构（TVBox 通用格式）
// 不用编译器合成的 Codable：线上配置里站点字段残缺是常态，
// 一个站点缺 api 不该让整份配置报废。所有字段走容错读取。

struct BoxConfig: Codable {
    var spider: String?
    var wallpaper: String?
    var sites: [Site]?
    var lives: [Live]?
    var parses: [Parse]?
    var flags: [String]?

    private enum BoxKeys: String, CodingKey {
        case spider, wallpaper, sites, lives, parses, flags
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: BoxKeys.self)
        spider = BoxConfig.str(c, .spider)
        wallpaper = BoxConfig.str(c, .wallpaper)
        flags = BoxConfig.strArray(c, .flags)
        let siteList: [Site]? = BoxConfig.lossy(c, .sites)
        let liveList: [Live]? = BoxConfig.lossy(c, .lives)
        let parseList: [Parse]? = BoxConfig.lossy(c, .parses)
        sites = siteList
        lives = liveList
        parses = parseList
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: BoxKeys.self)
        try c.encodeIfPresent(spider, forKey: .spider)
        try c.encodeIfPresent(wallpaper, forKey: .wallpaper)
        try c.encodeIfPresent(sites, forKey: .sites)
        try c.encodeIfPresent(lives, forKey: .lives)
        try c.encodeIfPresent(parses, forKey: .parses)
        try c.encodeIfPresent(flags, forKey: .flags)
    }

    private static func str(_ c: KeyedDecodingContainer<BoxKeys>, _ k: BoxKeys) -> String? {
        // try? 已经做过扁平化，绑定结果就是 String，不能再写 let v = d
        if let v = try? c.decodeIfPresent(String.self, forKey: k), !v.isEmpty { return v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: k) { return String(v) }
        return nil
    }

    private static func strArray(_ c: KeyedDecodingContainer<BoxKeys>, _ k: BoxKeys) -> [String]? {
        if let d = try? c.decodeIfPresent([String].self, forKey: k) { return d }
        return nil
    }

    /// 逐元素解码，坏元素吞掉继续，不让单个站点炸掉整份配置
    private static func lossy<T: Decodable>(_ c: KeyedDecodingContainer<BoxKeys>, _ k: BoxKeys) -> [T]? {
        guard var arr = try? c.nestedUnkeyedContainer(forKey: k) else { return nil }
        var out: [T] = []
        while !arr.isAtEnd {
            if let v = try? arr.decode(T.self) {
                out.append(v)
            } else if (try? arr.decode(JSONAny.self)) == nil {
                break   // 连任意 JSON 都吃不下，说明容器已坏，防止死循环
            }
        }
        return out
    }
}

struct Site: Codable, Identifiable {
    var key: String
    var name: String
    var type: Int
    var api: String
    var searchable: Int?
    var quickSearch: Int?
    var filterable: Int?
    var ext: JSONAny?

    var id: String { key }

    private enum SiteKeys: String, CodingKey {
        case key, name, type, api, searchable, quickSearch, filterable, ext
    }

    init(key: String, name: String, type: Int, api: String,
         searchable: Int? = nil, quickSearch: Int? = nil,
         filterable: Int? = nil, ext: JSONAny? = nil) {
        self.key = key
        self.name = name
        self.type = type
        self.api = api
        self.searchable = searchable
        self.quickSearch = quickSearch
        self.filterable = filterable
        self.ext = ext
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: SiteKeys.self)
        let nm = Site.str(c, .name)
        let ky = Site.str(c, .key)
        let ap = Site.str(c, .api) ?? ""

        name = nm ?? ky ?? "未命名站点"
        key = ky ?? nm ?? "site-\(UUID().uuidString.prefix(8))"
        api = ap

        if let t = Site.int(c, .type) {
            type = t
        } else if ap.contains("csp_") {
            type = 3            // csp_xxx 是内置 spider 的标记
        } else if ap.isEmpty {
            type = 3            // 只有 ext 没 api 的，按 spider 处理
        } else {
            type = 1
        }

        searchable = Site.int(c, .searchable)
        quickSearch = Site.int(c, .quickSearch)
        filterable = Site.int(c, .filterable)
        if let e = try? c.decodeIfPresent(JSONAny.self, forKey: .ext) { ext = e } else { ext = nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: SiteKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encode(api, forKey: .api)
        try c.encodeIfPresent(searchable, forKey: .searchable)
        try c.encodeIfPresent(quickSearch, forKey: .quickSearch)
        try c.encodeIfPresent(filterable, forKey: .filterable)
        try c.encodeIfPresent(ext, forKey: .ext)
    }

    private static func str(_ c: KeyedDecodingContainer<SiteKeys>, _ k: SiteKeys) -> String? {
        if let v = try? c.decodeIfPresent(String.self, forKey: k), !v.isEmpty { return v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: k) { return String(v) }
        if let v = try? c.decodeIfPresent(Double.self, forKey: k) { return String(v) }
        return nil
    }

    /// type 在部分配置里被写成字符串 "1"
    private static func int(_ c: KeyedDecodingContainer<SiteKeys>, _ k: SiteKeys) -> Int? {
        if let v = try? c.decodeIfPresent(Int.self, forKey: k) { return v }
        if let s = try? c.decodeIfPresent(String.self, forKey: k),
           let v = Int(s.trimmingCharacters(in: .whitespaces)) { return v }
        return nil
    }

    var canSearch: Bool { (searchable ?? 1) == 1 }

    // type 说明：0=xml cms, 1=json cms, 3=spider(jar/js), 4=spider+ext
    var isCMS: Bool { type == 0 || type == 1 }
    var isSpider: Bool { type == 3 || type == 4 }

    /// 有没有可用入口：有 api，或至少给了 ext（脚本站点常把入口放在 ext 里）
    var isUsable: Bool {
        if !api.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        guard let e = ext else { return false }
        switch e {
        case .object(let o): return !o.isEmpty
        case .string(let s): return !s.isEmpty
        default: return false
        }
    }
}

struct Live: Codable, Identifiable {
    var name: String
    var url: String
    var epg: String?
    var ua: String?
    var id: String { name + url }
}

struct Parse: Codable, Identifiable {
    var name: String
    var type: Int
    var url: String
    var ext: JSONAny?
    var id: String { name + url }
}

// MARK: - 内容模型
struct VCategory: Codable, Identifiable, Hashable {
    var type_id: String
    var type_name: String
    var id: String { type_id }
}

struct VItem: Codable, Identifiable, Hashable {
    var vod_id: String
    var vod_name: String
    var vod_pic: String?
    var vod_remarks: String?
    var id: String { vod_id }
}

struct VDetail: Codable, Identifiable {
    var vod_id: String
    var vod_name: String
    var vod_pic: String?
    var vod_content: String?
    var vod_remarks: String?
    var vod_year: String?
    var vod_area: String?
    var vod_actor: String?
    var vod_director: String?
    var type_name: String?
    var vod_play_from: String?
    var vod_play_url: String?

    var id: String { vod_id }

    /// 解析 "线路A$$$线路B" + "第1集$url#第2集$url$$$..."
    var playLines: [PlayLine] {
        guard let from = vod_play_from, let urls = vod_play_url else { return [] }
        let froms = from.components(separatedBy: "$$$")
        let groups = urls.components(separatedBy: "$$$")
        var result: [PlayLine] = []
        for (i, group) in groups.enumerated() {
            guard !group.isEmpty else { continue }
            var eps: [Episode] = []
            for seg in group.components(separatedBy: "#") {
                guard !seg.isEmpty else { continue }
                let parts = seg.components(separatedBy: "$")
                if parts.count >= 2 {
                    let name = parts[0].trimmingCharacters(in: .whitespaces)
                    // 部分源用 "name$url$extra"，只取前两段
                    let url = parts[1].trimmingCharacters(in: .whitespaces)
                    if url.hasPrefix("http") || url.contains("://") {
                        eps.append(Episode(name: name.isEmpty ? "第\(eps.count + 1)集" : name, url: url))
                    }
                } else if seg.hasPrefix("http") {
                    eps.append(Episode(name: "第\(eps.count + 1)集", url: seg))
                }
            }
            if !eps.isEmpty {
                let title = i < froms.count ? froms[i] : "线路\(i + 1)"
                result.append(PlayLine(name: title, episodes: eps))
            }
        }
        return result
    }
}

struct PlayLine: Identifiable {
    var name: String
    var episodes: [Episode]
    var id: String { name + String(episodes.count) }
}

struct Episode: Identifiable, Hashable {
    var name: String
    var url: String
    var id: String { url + name }
}

// MARK: - CMS 接口响应包
struct CMSListResponse: Codable {
    var `class`: [VCategory]?
    var list: [VItem]?
    var page: Int?
    var pagecount: Int?
    var total: Int?
    var msg: String?
}

struct CMSDetailResponse: Codable {
    var list: [VDetail]?
    var msg: String?
}
