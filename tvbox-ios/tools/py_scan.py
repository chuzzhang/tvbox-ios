#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
python 站点体检器：判断一批 .py spider 要跑起来还缺什么。

用法：
    python tools/py_scan.py <脚本目录>              # 扫目录下所有 .py
    python tools/py_scan.py <脚本.py>               # 扫单个
    python tools/py_scan.py <配置URL> [--limit N]   # 从配置里抽出所有 py 站点再扫
    python tools/py_scan.py <输入> --json           # 机器可读

输出每个脚本的四项：
    规模     行数、是否 class Spider、实现了哪几个入口
    依赖     标准库 / 需要 shim 的第三方库 / 需要 C 扩展的库
    结论     pure | http-shim | lxml-shim | native-shim | java-bridge
    缺什么   按结论列出需要补的模块

结论的含义（决定适配成本）：
    pure         只用标准库，嵌 CPython 后直接能跑
    http-shim    需要 requests / urllib3 的兼容层（桥到 NSURLSession）
    lxml-shim    需要 lxml.etree / pyquery（XPath / CSS 解析，桥到 SwiftSoup）
    native-shim  需要 Crypto / cryptography 的 AES（桥到 CommonCrypto）
    java-bridge  直接调 Android 类（com.github.catvod / jnius），iOS 无解，只能改写

复杂度：O(字节数)，纯文本扫描，不做 AST。
"""
import argparse
import collections
import json
import os
import re
import sys
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")

# 标准库：CPython 自带，嵌进去就有，不需要任何工作
STDLIB = {
    "re", "json", "sys", "os", "os.path", "time", "base64", "html", "gzip", "zlib",
    "hashlib", "hmac", "uuid", "copy", "threading", "functools", "itertools", "random",
    "string", "math", "datetime", "io", "binascii", "collections", "struct", "traceback",
    "typing", "warnings", "socket", "ssl", "queue", "decimal", "unicodedata", "calendar",
    "textwrap", "difflib", "codecs", "urllib", "urllib.parse", "urllib.request",
    "urllib.error", "urllib.robotparser", "http", "http.client", "http.cookiejar",
    "xml", "xml.etree", "xml.etree.ElementTree", "html.parser", "concurrent",
    "concurrent.futures", "logging", "platform", "subprocess", "shutil", "glob",
    "pathlib", "secrets", "statistics", "abc", "dataclasses", "enum", "types",
}

# 需要 shim 的第三方库 → (结论等级, 说明)
SHIM = {
    "requests": ("http-shim", "requests：Session/get/post、headers、params、timeout、verify、.text/.content/.json()"),
    "requests.adapters": ("http-shim", "requests.adapters：连接池配置，shim 里给空实现"),
    "requests.packages": ("http-shim", "requests.packages：urllib3 别名"),
    "urllib3": ("http-shim", "urllib3：一般只用于 disable_warnings / Retry"),
    "bs4": ("http-shim", "bs4：纯 Python，随包带上即可（依赖 html.parser）"),
    "lxml": ("lxml-shim", "lxml.etree：HTML() 建树 + xpath() 取节点"),
    "lxml.etree": ("lxml-shim", "lxml.etree：HTML() 建树 + xpath() 取节点"),
    "lxml.html": ("lxml-shim", "lxml.html：同上，另有 tostring"),
    "pyquery": ("lxml-shim", "pyquery：PyQuery(html) + CSS 选择器（依赖 lxml 语义）"),
    "cssselect": ("lxml-shim", "cssselect：纯 Python，CSS→XPath 编译"),
    "Crypto": ("native-shim", "Crypto.Cipher：AES-CBC/ECB（C 扩展，需桥到 CommonCrypto）"),
    "Crypto.Cipher": ("native-shim", "Crypto.Cipher：AES（C 扩展）"),
    "Crypto.Util": ("native-shim", "Crypto.Util.Padding：pad/unpad"),
    "Crypto.Hash": ("native-shim", "Crypto.Hash：摘要（可用 hashlib 替）"),
    "Cryptodome": ("native-shim", "Cryptodome.Cipher：同 Crypto，换了个包名"),
    "cryptography": ("native-shim", "cryptography.hazmat：AES + padding（C 扩展）"),
    "base.spider": ("pure", "base.spider：TVBox 的 Spider 基类，需要自写兼容层（纯 Python）"),
    "com.github.catvod": ("java-bridge", "com.github.catvod：直接调 Android 类，iOS 无解"),
    "jnius": ("java-bridge", "jnius：JNI 桥，iOS 无解"),
}

ENTRIES = ["init", "getName", "getDependencies", "getDependence", "homeContent",
           "homeVideoContent", "categoryContent", "detailContent", "searchContent",
           "playerContent"]

LEVEL_ORDER = ["pure", "http-shim", "lxml-shim", "native-shim", "java-bridge"]


def strip_comments(src):
    """去掉注释和字符串会误伤 URL 里的 // ——这里只去掉整行注释，够用。"""
    out = []
    for line in src.splitlines():
        s = line.lstrip()
        if s.startswith("#"):
            out.append("")
        else:
            out.append(line)
    return "\n".join(out)


def parse_imports(src):
    """返回 (顶层模块集合, 完整模块名集合)。不做 AST，正则够了。"""
    mods = set()
    for m in re.finditer(r"^[ \t]*import[ \t]+([\w\., \t]+)", src, re.M):
        for part in m.group(1).split(","):
            mod = part.strip().split(" ")[0].strip()
            if mod:
                mods.add(mod)
    for m in re.finditer(r"^[ \t]*from[ \t]+(\.?[\w\.]+)[ \t]+import", src, re.M):
        mod = m.group(1).strip()
        if mod and mod != ".":
            mods.add(mod)
    return mods


def module_key(mod):
    """把 `lxml.etree` 归到 `lxml`，`requests.adapters` 归到 `requests`，用于汇总。"""
    for cand in (mod, mod.split(".")[0]):
        if cand in SHIM or cand in STDLIB:
            return cand
    # 再试一级前缀（urllib.parse 这种）
    if "." in mod:
        head = mod.rsplit(".", 1)[0]
        if head in SHIM or head in STDLIB:
            return head
    return mod


def analyse(src):
    s = strip_comments(src)
    mods = parse_imports(s)

    stdlib, shim, unknown = [], [], []
    for m in sorted(mods):
        k = module_key(m)
        if k in STDLIB:
            stdlib.append(k)
        elif k in SHIM:
            shim.append((k, m))
        else:
            unknown.append(m)

    # 结论取最重的一级
    level = "pure"
    for k, _ in shim:
        lv = SHIM[k][0]
        if LEVEL_ORDER.index(lv) > LEVEL_ORDER.index(level):
            level = lv
    if unknown:
        # 不认识的模块不当成没事，标成待确认
        level = level if LEVEL_ORDER.index(level) >= 1 else "http-shim"

    entries = [e for e in ENTRIES if re.search(r"^[ \t]+def[ \t]+%s[ \t]*\(" % re.escape(e), s, re.M)]
    has_class = bool(re.search(r"^[ \t]*class[ \t]+Spider\b", s, re.M))
    has_base = bool(re.search(r"^[ \t]*class[ \t]+\w+\([^)]*Spider[^)]*\)", s, re.M))

    feats = {
        "fstring": bool(re.search(r'\bf["\']', s)),
        "lambda": "lambda" in s,
        "decorator": bool(re.search(r"^[ \t]*@\w+", s, re.M)),
        "yield": bool(re.search(r"\byield\b", s)),
        "async": "async def" in s,
        "global": bool(re.search(r"^[ \t]*global[ \t]+", s, re.M)),
        "exec_eval": bool(re.search(r"\b(eval|exec)\s*\(", s)),
        "getattr": "getattr(" in s,
        "dunder_init": "__init__" in s,
        "try_except": "try:" in s,
    }

    return {
        "lines": src.count("\n") + (0 if src.endswith("\n") else 1),
        "bytes": len(src.encode("utf-8", "replace")),
        "std": stdlib,
        "shim": [{"key": k, "module": m, "level": SHIM[k][0], "need": SHIM[k][1]} for k, m in shim],
        "unknown": unknown,
        "level": level,
        "class_spider": has_class or has_base,
        "entries": entries,
        "feats": feats,
        # 有 class 但没有 entry：多半是规则型脚本（只给 rule 或只给函数）
        "no_entry": not entries,
    }


def fmt_one(name, r):
    out = []
    out.append("=" * 66)
    out.append("%s   %d 行 / %.1f KB   结论：%s" % (name, r["lines"], r["bytes"] / 1024.0, r["level"]))
    out.append("  class Spider：%-3s   入口：%s" % (
        "有" if r["class_spider"] else "无",
        ", ".join(r["entries"]) if r["entries"] else "（没找到常规入口）"))
    if r["std"]:
        out.append("  标准库：" + ", ".join(r["std"]))
    if r["shim"]:
        out.append("  需要补：")
        for s in r["shim"]:
            out.append("    [%s] %s" % (s["level"], s["need"]))
    if r["unknown"]:
        out.append("  未知模块（要人工确认）：" + ", ".join(r["unknown"]))
    f = [k for k, v in r["feats"].items() if v]
    if f:
        out.append("  语法点：" + ", ".join(f))
    return "\n".join(out)


def collect_from_config(target, limit):
    """从配置里抽出所有 py 站点，下载到内存。返回 [(name, text)]。"""
    req = urllib.request.Request(target, headers={"User-Agent": UA})
    raw = urllib.request.urlopen(req, timeout=20).read()
    cfg = json.loads(raw.decode("utf-8", "replace"))
    sites = cfg.get("sites") or []
    picked = []
    for s in sites:
        api = str(s.get("api") or "")
        if api.lower().endswith(".py"):
            picked.append((s.get("key") or "", api))
    if limit:
        picked = picked[:limit]

    out = []
    for key, api in picked:
        url = urllib.parse.urljoin(target, api)
        name = urllib.parse.unquote(url.rsplit("/", 1)[-1]) or key
        try:
            rq = urllib.request.Request(url, headers={"User-Agent": UA})
            data = urllib.request.urlopen(rq, timeout=25).read()
            text = data.decode("utf-8", "replace")
            if text.lstrip().lower().startswith("<!doctype") or "<html" in text[:400].lower():
                out.append((name, None, "上游返回网页（%d 字节），不是脚本" % len(data)))
            else:
                out.append((name, text, ""))
        except Exception as e:
            out.append((name, None, "下载失败：%s" % e))
    return out


def main():
    ap = argparse.ArgumentParser(description="python 站点体检：判断要跑起来还缺什么")
    ap.add_argument("target", help="脚本、脚本目录，或配置 URL")
    ap.add_argument("--limit", type=int, default=0, help="从配置抽站点时最多看几个")
    ap.add_argument("--json", action="store_true", help="输出 JSON")
    args = ap.parse_args()

    items = []       # (name, text|None, err)

    if args.target.lower().startswith(("http://", "https://")):
        items = collect_from_config(args.target, args.limit)
    elif os.path.isdir(args.target):
        for f in sorted(os.listdir(args.target)):
            if not f.endswith(".py"):
                continue
            p = os.path.join(args.target, f)
            try:
                items.append((f, open(p, encoding="utf-8", errors="replace").read(), ""))
            except Exception as e:
                items.append((f, None, str(e)))
    else:
        try:
            items.append((os.path.basename(args.target),
                          open(args.target, encoding="utf-8", errors="replace").read(), ""))
        except Exception as e:
            print("读不到文件：%s" % e)
            return 2

    results = []
    for name, text, err in items:
        if text is None:
            print("=" * 66)
            print("%s   ✗ %s" % (name, err))
            results.append({"name": name, "error": err})
            continue
        r = analyse(text)
        r["name"] = name
        results.append(r)
        if not args.json:
            print(fmt_one(name, r))

    ok = [r for r in results if "error" not in r]
    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=2))
        return 0

    print("\n" + "=" * 66)
    print("汇总：%d 个可分析，%d 个取不到" % (len(ok), len(results) - len(ok)))
    by_level = collections.Counter(r["level"] for r in ok)
    for lv in LEVEL_ORDER:
        if by_level.get(lv):
            print("  %-12s %d 个" % (lv, by_level[lv]))
    if ok:
        print("  合计 %d 行 / %.1f KB，平均 %d 行" % (
            sum(r["lines"] for r in ok),
            sum(r["bytes"] for r in ok) / 1024.0,
            sum(r["lines"] for r in ok) // len(ok)))

    # 需要补的模块按出现次数排，这就是 shim 的实现清单
    need = collections.Counter()
    for r in ok:
        for s in r["shim"]:
            need[s["key"]] += 1
    if need:
        print("\n要补的模块（按站点数排）：")
        for k, v in need.most_common():
            print("  %-22s %2d 个站点   [%s]" % (k, v, SHIM[k][0]))

    # 入口覆盖：缺 detailContent 或 categoryContent 的脚本，装了 CPython 也跑不出列表
    no_entry = [r["name"] for r in ok if r["no_entry"]]
    if no_entry:
        print("\n没找到常规入口（可能是规则型或 HTML 已经换成网页）：")
        for n in no_entry:
            print("  " + n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
