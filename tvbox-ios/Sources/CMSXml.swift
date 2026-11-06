import Foundation

/// maccms 的 XML 输出（`api/xml.php` 这类源，或 `?at=xml`）。
///
/// 为什么必须单独一条路：这些接口返回的是
/// `<rss><list pagecount="1284"><video><id>258420</id><name><![CDATA[…]]></name>…`
/// 用 JSON 解会直接报 `Unexpected character 'C' around line 1, column 2`——
/// 那个 C 来自 `<![CDATA[`。
///
/// 结构（实测 `www.msnii.com/api/xml.php`）：
/// ```
/// <rss version="5.1">
///   <list page="1" pagecount="1284" recordcount="25673">
///     <video><id/><tid/><name/><pic/><note/><des/>
///       <dl><dd flag="ckplayer"><![CDATA[第1集$url#第2集$url]]></dd></dl>
///     </video>
///   </list>
///   <class><ty id="26">国产剧</ty></class>     ← 很多源这里是空 <class></class>
/// </rss>
/// ```
enum CMSXml {

    struct ListResult {
        var items: [VItem] = []
        var cats: [VCategory] = []
        var pageCount: Int = 1
    }

    static func looksLikeXML(_ data: Data) -> Bool {
        // XML 一定以 < 开头（可能有 BOM 或空白）
        let head = data.prefix(64)
        for enc in [String.Encoding.utf8, .isoLatin1] {
            if let s = String(data: head, encoding: enc) {
                let t = s.replacingOccurrences(of: "\u{feff}", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return t.hasPrefix("<")
            }
        }
        return false
    }

    /// 先 UTF-8，再 GB18030 —— 老 maccms 站不少是 GBK 输出
    static func decodeText(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 解析

    static func list(_ data: Data) -> ListResult {
        var out = ListResult()
        guard let root = Dom().parse(data) else { return out }

        // pagecount 在 <list> 的属性上，不在子节点里
        if let listNode = firstNode(named: "list", in: root) ?? (root.name == "list" ? root : nil) {
            out.pageCount = max(Int(listNode.attrs["pagecount"] ?? "") ?? 1, 1)
        }

        for v in allNodes(named: "video", in: root) {
            let id = v.value("id")
            guard !id.isEmpty else { continue }
            let name = v.value("name")
            let pic = v.value("pic")
            let note = v.value("note")
            out.items.append(VItem(
                vod_id: id,
                vod_name: name.isEmpty ? id : name,
                vod_pic: pic.isEmpty ? nil : pic,
                vod_remarks: note.isEmpty ? nil : note
            ))
        }

        for ty in allNodes(named: "ty", in: root) {
            let id = ty.attrs["id"] ?? ""
            let name = ty.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !name.isEmpty else { continue }
            // XML 的 <ty> 不带 pid，按顶层处理
            out.cats.append(VCategory(type_id: id, type_name: name, type_pid: nil))
        }
        return out
    }

    static func detail(_ data: Data) -> VDetail? {
        guard let root = Dom().parse(data) else { return nil }
        guard let v = firstNode(named: "video", in: root) ?? (root.name == "video" ? root : nil) else { return nil }

        let id = v.value("id")
        guard !id.isEmpty else { return nil }

        // <dl> 里每组 <dd flag="线路名"> 是一整条线路，内容是 "集名$地址#集名$地址"
        var froms: [String] = []
        var urls: [String] = []
        for dl in v.all("dl") {
            // <dt>线路名</dt><dd>集名$地址#…</dd> 可能成对出现，也可能只给 dd 的 flag 属性，
            // 所以按出现顺序走，记住最近一个 dt
            var lastFlag = ""
            for child in dl.children {
                if child.name == "dt" {
                    lastFlag = child.text.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if child.name == "dd" {
                    let body = child.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !body.isEmpty else { continue }
                    var flag = child.attrs["flag"] ?? lastFlag
                    if flag.isEmpty { flag = "线路\(froms.count + 1)" }
                    froms.append(flag)
                    urls.append(body)
                }
            }
        }
        // 少数源把 dd 直接挂在 video 下
        for (i, dd) in v.all("dd").enumerated() {
            let body = dd.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let flag = dd.attrs["flag"] ?? "线路\(i + 1)"
            froms.append(flag)
            urls.append(body)
        }

        func opt(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }

        return VDetail(
            vod_id: id,
            vod_name: v.value("name").isEmpty ? id : v.value("name"),
            vod_pic: opt(v.value("pic")),
            vod_content: opt(v.value("des")),
            vod_remarks: opt(v.value("note")),
            vod_year: opt(v.value("year")),
            vod_area: opt(v.value("area")),
            vod_actor: opt(v.value("actor")),
            vod_director: opt(v.value("director")),
            type_name: opt(v.value("type")),
            vod_play_from: froms.isEmpty ? nil : froms.joined(separator: "$$$"),
            vod_play_url: urls.isEmpty ? nil : urls.joined(separator: "$$$")
        )
    }

    // MARK: - 极简 DOM

    private static func allNodes(named: String, in node: XmlNode) -> [XmlNode] {
        var out: [XmlNode] = []
        for c in node.children {
            if c.name == named { out.append(c) }
            out.append(contentsOf: allNodes(named: named, in: c))
        }
        return out
    }

    private static func firstNode(named: String, in node: XmlNode) -> XmlNode? {
        allNodes(named: named, in: node).first
    }
}

final class XmlNode {
    let name: String
    var attrs: [String: String] = [:]
    var text: String = ""
    var children: [XmlNode] = []

    init(_ name: String) { self.name = name }

    func all(_ n: String) -> [XmlNode] { children.filter { $0.name == n } }
    func first(_ n: String) -> XmlNode? { children.first { $0.name == n } }

    func value(_ n: String) -> String {
        first(n)?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// XMLParser 不保证遇到不规范 XML 时不中断，能拿到多少算多少，
/// 拿到的部分一般够用（缺字段当空处理）
private final class Dom: NSObject, XMLParserDelegate {
    private var stack: [XmlNode] = []
    private var root: XmlNode?

    func parse(_ data: Data) -> XmlNode? {
        let p = XMLParser(data: data)
        p.delegate = self
        p.shouldResolveExternalEntities = false
        _ = p.parse()
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let n = XmlNode(elementName)
        n.attrs = attributeDict
        if let parent = stack.last {
            parent.children.append(n)
        } else {
            root = n
        }
        stack.append(n)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        // CDATA 不走 foundCharacters，漏了这个所有中文名和播放地址都是空
        stack.last?.text += CMSXml.decodeText(CDATABlock)
    }
}
