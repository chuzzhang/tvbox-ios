import Foundation

/// DEX 只读扫描：不解字节码，只读字符串表、类型表、类定义表。
///
/// 用途只有一个：jar 里只有 classes.dex 时，把「这个包到底带了什么」摊开——
/// 有哪些站点实现、依赖哪些外部 API。这决定它能不能在 iOS 上被别的实现顶掉：
/// 依赖 java.util.regex 可以桥到 NSRegularExpression，依赖 okhttp3 + rxhttp
/// 就是另一回事了。
///
/// 解析全程做越界检查，任何一处不合规就返回 nil，绝不抛异常。
struct DexInfo {

    /// dex 内定义的类，点分形式：com.github.catvod.spider.XBPQ
    let classNames: [String]
    /// 外部引用类型按包计数：["okhttp3": 17, "java.util": 32]
    let externalPackages: [String: Int]
    /// 方法总数
    let methodCount: Int

    /// 站点类：com.github.catvod.spider.Xxx，去掉混淆的 merge.* 与内部类
    var siteClasses: [String] {
        let prefix = "com.github.catvod.spider."
        var seen = Set<String>()
        var out: [String] = []
        for full in classNames where full.hasPrefix(prefix) {
            let rest = String(full.dropFirst(prefix.count))
            guard !rest.isEmpty, !rest.contains("."), !rest.contains("$") else { continue }
            if seen.insert(rest).inserted { out.append(rest) }
        }
        return out
    }

    /// 混淆类数量：com.github.catvod.spider.merge.* 是改名后的 jsoup，类名只剩一两个字母
    var obscuredCount: Int {
        classNames.filter { $0.hasPrefix("com.github.catvod.spider.merge.") }.count
    }

    /// 外部依赖摘要，按引用数倒序，最多 8 项
    var dependencyLine: String {
        let items = externalPackages
            .filter { $0.value > 0 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(8)
            .map { "\($0.key)(\($0.value))" }
        return items.isEmpty ? "无" : items.joined(separator: " ")
    }

    /// 是否只有标准库依赖（这类才有可能靠 JS/Swift 重新实现）
    var isPlainJava: Bool {
        let allowed = ["java.lang", "java.util", "java.io", "java.text", "java.math",
                       "java.nio", "java.security", "java.util.regex", "org.json",
                       "android.util", "android.text", "android.os", "android.net",
                       "com.github.catvod.crawler", "dalvik.annotation"]
        return externalPackages.keys.allSatisfy { pkg in
            allowed.contains { pkg == $0 || pkg.hasPrefix($0 + ".") }
        }
    }

    // MARK: - 解析

    static func scan(_ data: Data) -> DexInfo? {
        guard data.count > 0x70 else { return nil }
        let bytes = [UInt8](data)
        // magic: "dex\n035\0" / "dex\n035\0" 之后的校验和与签名不校验
        guard bytes[0] == 0x64, bytes[1] == 0x65, bytes[2] == 0x78, bytes[3] == 0x0A else { return nil }

        func u32(_ off: Int) -> Int? {
            guard off >= 0, off + 4 <= bytes.count else { return nil }
            return Int(bytes[off])
                | Int(bytes[off + 1]) << 8
                | Int(bytes[off + 2]) << 16
                | Int(bytes[off + 3]) << 24
        }

        /// uleb128 解出 (值, 下一偏移)。超过 5 字节直接判非法。
        func uleb(_ off: Int) -> (Int, Int)? {
            var p = off
            var value = 0
            var shift = 0
            while p < bytes.count && shift <= 28 {
                let b = Int(bytes[p])
                p += 1
                value |= (b & 0x7F) << shift
                if b & 0x80 == 0 { return (value, p) }
                shift += 7
            }
            return nil
        }

        /// string_ids[idx] → MUTF-8 字符串。类名基本是 ASCII，按 UTF-8 解即可。
        func string(_ idx: Int, table: Int) -> String? {
            guard idx >= 0, let off = u32(table + idx * 4) else { return nil }
            guard off >= 0, off < bytes.count else { return nil }
            var p = off
            // 跳过 uleb128 的 UTF-16 长度
            var shift = 0
            while p < bytes.count {
                let b = bytes[p]
                p += 1
                if b & 0x80 == 0 { break }
                shift += 7
                if shift > 28 { return nil }
            }
            var buf = [UInt8]()
            while p < bytes.count && bytes[p] != 0 {
                buf.append(bytes[p])
                p += 1
            }
            return String(decoding: buf, as: UTF8.self)
        }

        guard let stringOff = u32(0x3C),
              let typeSize = u32(0x40), let typeOff = u32(0x44),
              let classSize = u32(0x60), let classOff = u32(0x64) else { return nil }

        // 1) 类定义里的类型索引
        var definedIdx = Set<Int>()
        var definedNames: [String] = []
        definedNames.reserveCapacity(classSize)
        var methods = 0

        for i in 0..<classSize {
            let base = classOff + i * 32
            guard let classIdx = u32(base) else { break }
            guard let descIdx = u32(typeOff + classIdx * 4) else { continue }
            definedIdx.insert(descIdx)
            if let desc = string(descIdx, table: stringOff) {
                definedNames.append(descriptorToName(desc))
            }

            // class_data_off 在 class_def 的第 6 个字段（索引 24）
            guard let dataOff = u32(base + 24), dataOff > 0 else { continue }
            var p = dataOff
            var sizes: [Int] = []
            for _ in 0..<4 {
                guard let (v, next) = uleb(p) else { break }
                sizes.append(v)
                p = next
            }
            guard sizes.count == 4 else { continue }
            // 字段：static_fields + instance_fields，每项 (idx_diff, access_flags)
            for _ in 0..<(sizes[0] + sizes[1]) {
                guard let (_, a) = uleb(p), let (_, b) = uleb(a) else { break }
                p = b
            }
            // 方法：direct + virtual，每项 (idx_diff, access_flags, code_off)
            for _ in 0..<(sizes[2] + sizes[3]) {
                guard let (_, a) = uleb(p), let (_, b) = uleb(a), let (_, c) = uleb(b) else { break }
                p = c
                methods += 1
            }
        }

        // 2) 外部引用：type_ids 里没在本 dex 定义的类型
        var external: [String: Int] = [:]
        for i in 0..<typeSize {
            guard let descIdx = u32(typeOff + i * 4) else { break }
            if definedIdx.contains(descIdx) { continue }
            guard let desc = string(descIdx, table: stringOff) else { continue }
            guard desc.hasPrefix("L"), desc.hasSuffix(";") else { continue }
            let full = descriptorToName(desc)
            // 取包路径：com.github.catvod.spider.XBPQ → com.github.catvod.spider
            //          okhttp3.Request            → okhttp3
            let pkg: String
            if let dot = full.lastIndex(of: ".") {
                pkg = String(full[full.startIndex..<dot])
            } else {
                pkg = full
            }
            guard !pkg.isEmpty else { continue }
            external[pkg, default: 0] += 1
        }

        return DexInfo(classNames: definedNames,
                       externalPackages: external,
                       methodCount: methods)
    }

    /// `Lcom/github/catvod/spider/XBPQ;` → `com.github.catvod.spider.XBPQ`
    private static func descriptorToName(_ d: String) -> String {
        var s = d
        if s.hasPrefix("L") { s.removeFirst() }
        if s.hasSuffix(";") { s.removeLast() }
        return s.replacingOccurrences(of: "/", with: ".")
    }
}
