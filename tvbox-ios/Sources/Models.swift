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
    /// 实际命中的配置地址目录（多仓时是子仓的地址），配置里的 ./xxx 相对它解析。
    /// 不参与编解码，只在加载过程里填。
    var resolvedBase: String = ""

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

    /// 实际该怎么走。
    /// 配置里 type 标错的很多：标成 3（spider）但 api 是 http 的 CMS 直链。
    /// 这种按 CMS 走直接出内容，比硬塞进 JS 引擎靠谱。
    /// 注意 `.py` 也要排除：它虽然不以 .js/.jar 结尾，但同样不是 CMS 接口。
    var effectiveType: Int {
        let a = api.trimmingCharacters(in: .whitespaces)
        let l = a.lowercased()
        let scriptLike = l.contains(".js") || l.contains(".jar") || l.contains(".py")
        if isSpider, l.hasPrefix("http"), !scriptLike {
            return 1
        }
        return type
    }

    var isCMSRoute: Bool { effectiveType == 0 || effectiveType == 1 }
    var isSpiderRoute: Bool { effectiveType == 3 || effectiveType == 4 }

    /// Pyramid（python 版 TVBox）站点：api 形如 `py_xxx`，规则或脚本在 ext 里。
    /// 规则型和 drpy 同源，内置解释器能直接吃；脚本型（.py）要 CPython。
    var isPyramid: Bool {
        let a = api.trimmingCharacters(in: .whitespaces).lowercased()
        if a.hasPrefix("py_") { return true }
        return a.contains("pyramid")
    }

    /// 站点类型。判定和展示都只走这一处，避免 routeLabel 和开关分组各判一套、互相打架。
    ///
    /// 曾经踩过的坑：ext 里 `contains(".js")` 就当 js 站点。csp_* 这类站点的 ext 是给
    /// spider 的参数对象，里面 `"userScript": "./js/x.user.js"`、`"blockList": ["*.js*"]`
    /// 都会命中，于是 18 个 jar 站点全被归成 js，关掉 jar 开关照样显示。
    var kind: SiteKind {
        if isCMSRoute { return .cms }
        let a = api.trimmingCharacters(in: .whitespaces).lowercased()
        // api 直接是脚本文件时 ext 基本是空的，先按 api 判
        if a.hasSuffix(".py") || a.contains(".py?") { return .python }
        if a.contains(".jar") { return .jar }
        if a.contains(".js") { return .js }

        let raw = Drpy.extText(ext).trimmingCharacters(in: .whitespacesAndNewlines)
        let e = raw.lowercased()

        if isPyramid {
            // pyramid：ext 是 python 源码算 python，其余（规则 JSON）算 js
            let pySource = e.hasSuffix(".py") || (e.contains("import ") && e.contains("def "))
            return pySource ? .python : .js
        }

        // ext 必须是「规则文件地址」或「内联规则」才算 js 站点。
        // 不能对整段 ext 做 contains：参数对象里的字段会误命中。
        if Self.extIsRuleURL(e) || Drpy.looksLikeRule(raw) { return .js }
        if !e.hasPrefix("{"), e.contains("import "), e.contains("def ") { return .python }
        return .jar
    }

    /// ext 整体是不是一个规则文件地址（`./json/x.json`、`https://…/x.js`）
    private static func extIsRuleURL(_ e: String) -> Bool {
        let pathLike = e.hasPrefix("http") || e.hasPrefix("./") || e.hasPrefix("/") || e.hasPrefix("../")
        guard pathLike else { return false }
        let tail = e.split(separator: "?").first.map(String.init) ?? e
        return tail.hasSuffix(".json") || tail.hasSuffix(".js")
    }

    /// 给站点列表做标注，一眼看出哪个能用
    var routeLabel: String {
        switch kind {
        case .cms:    return "CMS"
        case .js:     return "js 脚本"
        case .python: return "py 脚本"
        case .jar:    return "jar 内置"
        }
    }

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

    /// api 里的相对路径（`./api.php`、`/api.php/provide/vod`）要相对配置地址解析
    func apiURL(base: String?) -> String {
        URLKit.resolve(api, base: base)
    }
}

/// 站点实现方式。配置页的四个开关就是这四类，默认只开 CMS 和 js。
enum SiteKind: String, CaseIterable, Identifiable, Hashable {
    case cms
    case js
    case python
    case jar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cms:    return "CMS 接口"
        case .js:     return "JS 脚本"
        case .python: return "Python 脚本"
        case .jar:    return "JAR / 内置"
        }
    }

    /// 标注在开关右边的短说明
    var short: String {
        switch self {
        case .cms:    return "type 0/1，maccms 接口"
        case .js:     return "drpy 规则、js spider"
        case .python: return "需要 CPython，暂不支持"
        case .jar:    return "dex 字节码，暂不支持"
        }
    }

    /// 当前版本能不能真跑起来。不能跑的不隐藏开关，但要标出来，
    /// 否则用户开了之后只看到一堆点进去就报错的站点
    var supported: Bool { self == .cms || self == .js }

    /// 首次启动的默认勾选：只开能用的两类
    static var defaultEnabled: Set<SiteKind> { [.cms, .js] }
}

struct Live: Codable, Identifiable {
    var name: String
    var url: String
    var epg: String?
    var ua: String?
    var id: String { name + url }
}

struct Parse: Codable, Identifiable {
    var name: String = ""
    var type: Int = 0
    var url: String = ""
    var ext: JSONAny?
    var id: String { name + url }

    private enum ParseKeys: String, CodingKey {
        case name, type, url, ext
    }

    init(name: String = "", type: Int = 0, url: String = "", ext: JSONAny? = nil) {
        self.name = name
        self.type = type
        self.url = url
        self.ext = ext
    }

    // 有的配置把 type 写成 "1"，缺字段也很常见 —— 宽松点，别让整条解析接口被丢掉
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ParseKeys.self)
        if let v = try? c.decodeIfPresent(String.self, forKey: .name) { name = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .url) { url = v }
        if let t = try? c.decodeIfPresent(Int.self, forKey: .type) {
            type = t
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .type), let t = Int(s) {
            type = t
        }
        ext = try? c.decodeIfPresent(JSONAny.self, forKey: .ext)
    }
}

// MARK: - 宽松解码
// 同一份 CMS 接口，type_id 有时是 "1" 有时是 1，pagecount 有时是字符串。
// 用动态 key + 逐个类型试探，避免一个字段类型不符就把整页内容丢掉。

enum Loose {
    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init(_ s: String) {
            stringValue = s
            intValue = Int(s)
        }
        // 外部标签用协议要求的名字，内部换名，避免构造器委托时自己调自己
        init?(stringValue s: String) { self.init(s) }
        init?(intValue i: Int) { self.init(String(i)) }
    }

    static func text(_ c: KeyedDecodingContainer<AnyKey>, _ name: String) -> String? {
        let k = AnyKey(name)
        if let v = try? c.decodeIfPresent(String.self, forKey: k), !v.isEmpty { return v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: k) { return String(v) }
        if let v = try? c.decodeIfPresent(Double.self, forKey: k) { return String(v) }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: k) { return v ? "1" : "0" }
        return nil
    }

    static func int(_ c: KeyedDecodingContainer<AnyKey>, _ name: String) -> Int? {
        let k = AnyKey(name)
        if let v = try? c.decodeIfPresent(Int.self, forKey: k) { return v }
        if let s = try? c.decodeIfPresent(String.self, forKey: k) {
            return Int(s.trimmingCharacters(in: .whitespaces))
        }
        if let v = try? c.decodeIfPresent(Double.self, forKey: k) { return Int(v) }
        return nil
    }
}

// MARK: - 内容模型
struct VCategory: Codable, Identifiable, Hashable {
    var type_id: String
    var type_name: String
    /// 父分类 id：0 或空表示顶层。有些源这一级（分组那一层）本身
    /// 不挂片子，只有子分类有内容，点父分类就会拿到空列表
    var type_pid: String?
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
                    // 相对路径和播放页地址也留着：PlayResolver 会补 host、抽 ?url=
                    if !url.isEmpty, url != "#" {
                        eps.append(Episode(name: name.isEmpty ? "第\(eps.count + 1)集" : name, url: url))
                    }
                } else if !seg.isEmpty, seg != "#" {
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
struct CMSListResponse: Decodable {
    var `class`: [VCategory]?
    var list: [VItem]?
    var page: Int?
    var pagecount: Int?
    var total: Int?
    var msg: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Loose.AnyKey.self)
        self.`class` = try? c.decodeIfPresent([VCategory].self, forKey: Loose.AnyKey("class"))
        self.list = try? c.decodeIfPresent([VItem].self, forKey: Loose.AnyKey("list"))
        self.page = Loose.int(c, "page")
        self.pagecount = Loose.int(c, "pagecount")
            ?? Loose.int(c, "page_count")
            ?? Loose.int(c, "total_page")
            ?? Loose.int(c, "pages")
        self.total = Loose.int(c, "total")
        self.msg = Loose.text(c, "msg")
    }
}

struct CMSDetailResponse: Decodable {
    var list: [VDetail]?
    var msg: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Loose.AnyKey.self)
        self.list = try? c.decodeIfPresent([VDetail].self, forKey: Loose.AnyKey("list"))
        self.msg = Loose.text(c, "msg")
    }
}

// MARK: - 内容模型的宽松解码
// 写在 extension 里，保留各 struct 的 memberwise init

extension VCategory {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Loose.AnyKey.self)
        let tid = Loose.text(c, "type_id") ?? Loose.text(c, "type") ?? ""
        let name = Loose.text(c, "type_name") ?? Loose.text(c, "name") ?? ""
        self.type_id = tid
        self.type_name = name.isEmpty ? tid : name
        // maccms 里 type_pid 是数字，Loose.text 会转成字符串
        self.type_pid = Loose.text(c, "type_pid")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Loose.AnyKey.self)
        try c.encode(type_id, forKey: Loose.AnyKey("type_id"))
        try c.encode(type_name, forKey: Loose.AnyKey("type_name"))
        try c.encodeIfPresent(type_pid, forKey: Loose.AnyKey("type_pid"))
    }
}

extension VItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Loose.AnyKey.self)
        let vid = Loose.text(c, "vod_id") ?? Loose.text(c, "id") ?? ""
        let name = Loose.text(c, "vod_name") ?? Loose.text(c, "name") ?? ""
        self.vod_id = vid
        self.vod_name = name.isEmpty ? vid : name
        self.vod_pic = Loose.text(c, "vod_pic")
        self.vod_remarks = Loose.text(c, "vod_remarks") ?? Loose.text(c, "note")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Loose.AnyKey.self)
        try c.encode(vod_id, forKey: Loose.AnyKey("vod_id"))
        try c.encode(vod_name, forKey: Loose.AnyKey("vod_name"))
        try c.encodeIfPresent(vod_pic, forKey: Loose.AnyKey("vod_pic"))
        try c.encodeIfPresent(vod_remarks, forKey: Loose.AnyKey("vod_remarks"))
    }
}

extension VDetail {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Loose.AnyKey.self)
        let vid = Loose.text(c, "vod_id") ?? ""
        let name = Loose.text(c, "vod_name") ?? ""
        self.vod_id = vid
        self.vod_name = name.isEmpty ? vid : name
        self.vod_pic = Loose.text(c, "vod_pic")
        self.vod_content = Loose.text(c, "vod_content") ?? Loose.text(c, "vod_blurb")
        self.vod_remarks = Loose.text(c, "vod_remarks")
        self.vod_year = Loose.text(c, "vod_year")
        self.vod_area = Loose.text(c, "vod_area")
        self.vod_actor = Loose.text(c, "vod_actor")
        self.vod_director = Loose.text(c, "vod_director")
        self.type_name = Loose.text(c, "type_name")
        self.vod_play_from = Loose.text(c, "vod_play_from")
        self.vod_play_url = Loose.text(c, "vod_play_url")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Loose.AnyKey.self)
        try c.encode(vod_id, forKey: Loose.AnyKey("vod_id"))
        try c.encode(vod_name, forKey: Loose.AnyKey("vod_name"))
        try c.encodeIfPresent(vod_pic, forKey: Loose.AnyKey("vod_pic"))
        try c.encodeIfPresent(vod_content, forKey: Loose.AnyKey("vod_content"))
        try c.encodeIfPresent(vod_remarks, forKey: Loose.AnyKey("vod_remarks"))
        try c.encodeIfPresent(vod_year, forKey: Loose.AnyKey("vod_year"))
        try c.encodeIfPresent(vod_area, forKey: Loose.AnyKey("vod_area"))
        try c.encodeIfPresent(vod_actor, forKey: Loose.AnyKey("vod_actor"))
        try c.encodeIfPresent(vod_director, forKey: Loose.AnyKey("vod_director"))
        try c.encodeIfPresent(type_name, forKey: Loose.AnyKey("type_name"))
        try c.encodeIfPresent(vod_play_from, forKey: Loose.AnyKey("vod_play_from"))
        try c.encodeIfPresent(vod_play_url, forKey: Loose.AnyKey("vod_play_url"))
    }
}
