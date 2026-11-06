import Foundation

/// Wex / AI 卫士加固包（`csp_xxxGuard`）的识别与诊断。
///
/// 实测样本：`https://9280.kstore.space/aiwex.json` 的顶层 spider
/// `http://oss4liview.moji.com/thd_file/2026/11/04/690e7f13e63718e6ea88add0c59d4289.jpg`
/// （md5 86cb2cdcd99e29334004b80e48007e9a，1 008 KB）：
///
///   classes.dex                 39 KB   143 类 / 373 个方法引用 / 477 条字符串
///   assets/wexguard_v7.so       47 KB   Obfuscator-LLVM 8.0
///   assets/wexguard_v8.so       48 KB   同上，多一个可执行的 .mytext 段
///   assets/wexshinidie.guard   946 KB   熵 7.993，全加密载荷
///
/// 143 个 `XxxGuard` 类全部是 `extends BaseSpiderGuard extends Spider` 的空壳
/// （`BaseSpiderGuard` 只有 1 个构造 + 10 个覆写，平均每类 2.6 个方法），
/// 真实站点逻辑在 .guard 里，由 so 在运行期解开，再交给宿主 app 的
/// `libDexNative.so` 走 `InMemoryDexClassLoader` 加载。
///
/// 所以这类站点在 iOS 上没有「重写某个类」这条路径：
/// 反编译拿到的是壳，真正的接口地址在加密段里。
enum GuardSites {

    /// 站点 api 是不是加固壳：`csp_` 前缀，或者类名以 Guard 结尾
    static func isGuard(api: String) -> Bool {
        let a = api.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return false }
        let lower = a.lowercased()
        if lower.hasPrefix("csp_") && lower.hasSuffix("guard") { return true }
        // 少数配置直接写类名（不带 csp_）
        if lower.hasSuffix("guard") && !lower.hasPrefix("http") && !lower.contains("/") { return true }
        return false
    }

    /// 包内是否带加固载荷。命中就说明这个 jar 不是普通 spider。
    static func hasGuardPayload(_ entries: [String]) -> Bool {
        for e in entries {
            let l = e.lowercased()
            if l.hasSuffix(".guard") { return true }
            if l.contains("wexguard") { return true }
            if l.contains("guard_v") && l.hasSuffix(".so") { return true }
        }
        return false
    }

    /// 从 entries 里挑出加固相关文件，按体积从大到小
    static func payloadLine(_ entries: [String]) -> String {
        let hits = entries.filter {
            let l = $0.lowercased()
            return l.hasSuffix(".guard") || l.contains("wexguard") || (l.contains("guard") && l.hasSuffix(".so"))
        }
        if hits.isEmpty { return "" }
        return hits.prefix(6).joined(separator: ", ")
    }

    /// 命中加固包时给出的结论，替掉「缺可执行脚本」这种没法行动的提示
    static func verdict(entries: [String], dex: [DexInfo]) -> [String] {
        var out: [String] = []
        out.append("—— 结论：这个 spider 包是加固壳（Wex / AI 卫士），不是能直接读的 jar")

        if !dex.isEmpty {
            let classes = dex.reduce(0) { $0 + $1.classNames.count }
            let methods = dex.reduce(0) { $0 + $1.methodCount }
            out.append("dex 里 \(classes) 个类 / \(methods) 个方法引用，站点类全是 `XxxGuard` 空壳，没有任何网络请求代码")
        }
        let payload = payloadLine(entries)
        if !payload.isEmpty {
            out.append("加固载荷：\(payload)")
            out.append("真代码在 .guard 里（加密，熵 7.99），由同包的 wexguard_*.so 在运行期解开")
            out.append("该 so 用 Obfuscator-LLVM 8.0 混淆：控制流平坦化 + 数据段逐位解密 + 自定义 .mytext 代码段")
            out.append("解开后还要宿主 app 的 libDexNative.so 用 InMemoryDexClassLoader 加载 —— TVBox 主程序自带这个库")
        }
        out.append("静态还原过一遍：密钥 = strftime(「%Y%m%d」) 即当天日期（如 20261105），")
        out.append("解密产物写到 <cache>/sharedb/config.db，再用 DexClassLoader 加载 —— 落地文件就是 dex")
        out.append("iOS 上没有 libDexNative.so，也没有 ART：这套东西一层都过不去，且解开仍是 dex")
        out.append("要拿到真实接口只有一条路：在 Android 上跑一次，把解密产物 dump 出来，再反编译")
        out.append("脚本见 _work/dump_wex_dex.js：hook FileOutputStream.write 直接截 config.db 内容")
        out.append("  frida -U -f com.fongmi.android.tv -l dump_wex_dex.js --no-pause")
        out.append("  进 app 打开任意加固站点一次 → 产物在 /sdcard/wex_dump/ → adb pull 回来")
        out.append("拿到 dex 后 jadx 打开对应 XxxGuard，catOpen/categoryContent 里就是域名和接口")
        return out
    }

    /// 整份配置的加固占比。给用户一句能直接判断的话，比逐站点开诊断快。
    static func configStat(_ sites: [Site]) -> String? {
        let usable = sites.filter { $0.isUsable }
        guard !usable.isEmpty else { return nil }
        let guards = usable.filter { isGuard(api: $0.api) }
        if guards.isEmpty { return nil }
        if guards.count == usable.count {
            return "本配置 \(usable.count) 个点播站点全部是加固壳，没有一个能走 CMS 或脚本路径"
        }
        return "本配置 \(guards.count)/\(usable.count) 个点播站点是加固壳，其余可正常尝试"
    }
}
