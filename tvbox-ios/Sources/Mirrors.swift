import Foundation

/// drpy / dr_py 静态资源的公开镜像。
///
/// 现实情况：配置里这类资源几乎都挂在个人资源站上（`home.jundie.top:666/JS/dr_py/`），
/// 站点一关就是整目录 401/404，客户端换 UA、加 Referer 一点用都没有。
/// 这些规则文件在 GitHub 上被大量仓库镜像，路径尾部（`js/xxx.js`、`libs/drpy.min.js`）
/// 是一致的，所以按尾部拼镜像前缀重试，能救回相当一部分。
///
/// 全部失败不影响诊断：调用方只会多花几次短超时。
enum ScriptMirror {

    /// 镜像前缀。顺序就是尝试顺序，取前 3 个前缀的候选。
    static let bases = [
        "https://cdn.jsdelivr.net/gh/gaotianliuyun/gao@master/",
        "https://raw.gitmirror.com/gaotianliuyun/gao/master/",
        "https://ghproxy.net/https://raw.githubusercontent.com/gaotianliuyun/gao/master/",
        "https://cdn.jsdelivr.net/gh/hjdhnx/dr_py@main/"
    ]

    /// 从原始地址里取「dr_py / drpy 之后的尾部路径」，取不到就返回空
    static func tailPath(_ url: String) -> String {
        let lower = url.lowercased()
        guard let r = lower.range(of: "/dr_py/") ?? lower.range(of: "/drpy/") else { return "" }
        let idx = lower.distance(from: lower.startIndex, to: r.upperBound)
        guard idx < url.count else { return "" }
        var tail = String(url[url.index(url.startIndex, offsetBy: idx)...])
        // 去掉查询串，镜像站按路径取文件
        if let q = tail.firstIndex(of: "?") { tail = String(tail[tail.startIndex..<q]) }
        return tail
    }

    /// 给一个 drpy 资源地址，生成镜像候选。
    /// 只处理 dr_py 路径：别的站点的文件在镜像上不存在，白试。
    static func candidates(for url: String) -> [String] {
        let tail = tailPath(url)
        guard !tail.isEmpty else { return [] }

        let name = tail.split(separator: "/").last.map(String.init) ?? tail
        let isLib = name.lowercased().hasSuffix(".min.js")
        let stem = name.contains(".") ? String(name[..<name.lastIndex(of: ".")!]) : name

        var out: [String] = []
        // 尾部可能在 js/ 下，也可能在 libs/ 下，文件名两种都试
        for base in bases.prefix(3) {
            out.append(base + tail)
            if isLib {
                out.append(base + "libs/" + name)
                out.append(base + "js/" + name)
            } else {
                out.append(base + "js/" + name)
                out.append(base + "json/" + stem + ".json")
            }
        }

        // 去重 + 去掉原地址本身
        var seen = Set<String>()
        var res: [String] = []
        for u in out where u != url {
            if seen.insert(u).inserted { res.append(u) }
        }
        return Array(res.prefix(8))
    }
}
