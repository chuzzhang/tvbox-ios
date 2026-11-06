#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
配置体检器：判断一份 TVBox 配置里哪些站点在本项目（iOS 版）能跑。

用法：
    python tools/check_config.py <配置URL或本地文件> [--probe] [--limit N] [--json]

输出四类：
    CMS      type 0/1，maccms 接口 —— 直接可用
    规则     drpy / pyramid / 内联规则 —— 走内置解释器
    js       api 或 ext 是 .js —— 走 JSCore
    加固     csp_*Guard —— iOS 无 APK 运行时，跑不了（本工具会指出壳的特征）

--probe 会对 CMS 站点发一次真实请求（?ac=list），统计活着的比例。
复杂度：O(站点数)，探活并发 8，单请求 8 秒超时。
"""
import argparse
import concurrent.futures as futures
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.request

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def fetch(url, timeout=12, referer=None):
    """返回 (bytes, status, err)。非 2xx 也返回 body，交给上层判断。"""
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    if referer:
        req.add_header("Referer", referer)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
            return r.read(), r.status, None
    except urllib.error.HTTPError as e:
        try:
            return e.read(), e.code, None
        except Exception:
            return b"", e.code, None
    except Exception as e:
        return b"", 0, str(e)


def strip_suffix(url):
    """TVBox 的地址常带 `;md5;xxx` / `;pk;xxx` 校验后缀，必须先剥掉再请求。"""
    return (url or "").split(";")[0].strip()


def load_config(target):
    if os.path.exists(target):
        raw = open(target, "rb").read()
    else:
        raw, status, err = fetch(target)
        if err or (status < 200 or status >= 300):
            sys.exit(f"配置拉取失败：{target}  status={status}  err={err}")
    # 首字节不是 { 可能是 gbk 或带 BOM
    for enc in ("utf-8-sig", "utf-8", "gb18030"):
        try:
            text = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    else:
        sys.exit("配置编码无法识别")
    return json.loads(text)


def merge(obj):
    """支持 {urls:[...]} 多仓合并。"""
    if isinstance(obj.get("urls"), list):
        out = {"sites": [], "parses": [], "lives": [], "spider": ""}
        for u in obj["urls"]:
            sub, _, err = fetch(strip_suffix(u))
            if err:
                print(f"  ! 子仓拉取失败 {u}: {err}")
                continue
            try:
                s = merge(json.loads(sub.decode("utf-8-sig", "ignore")))
            except Exception as e:
                print(f"  ! 子仓解析失败 {u}: {e}")
                continue
            for k in ("sites", "parses", "lives"):
                out[k].extend(s.get(k) or [])
            out["spider"] = out["spider"] or s.get("spider", "")
        return out
    return obj


def site_kind(s):
    t = s.get("type")
    api = str(s.get("api") or "")
    ext = s.get("ext")
    ext_s = json.dumps(ext, ensure_ascii=False) if isinstance(ext, (dict, list)) else str(ext or "")

    if str(t) in ("0", "1"):
        return "CMS"
    if str(t) in ("3", "4"):
        if api.startswith("csp_"):
            return "加固" if api.endswith("Guard") or "Guard" in api else "spider"
        if "drpy" in api.lower() or "drpy" in ext_s[:300]:
            return "规则"
        if api.lower().startswith("py_") or api.lower().startswith("py/"):
            return "规则"
        if api.lower().startswith("http") and ".js" in api:
            return "js"
        if api.lower().startswith("http") and ".json" in api:
            return "规则"
        if not api and ext_s.lstrip().startswith(("{", "[")):
            return "规则"
        return "spider"
    return f"type{t}"


def inspect_spider(url):
    """下载 spider 包并判定形态：js 规则包 / 纯 dex jar / 加固壳。"""
    url = strip_suffix(url)
    if not url:
        return None
    data, status, err = fetch(url, timeout=30)
    if err or not data:
        return {"url": url, "error": err or f"HTTP {status}"}
    info = {"url": url, "size": len(data), "kind": "unknown"}
    if data[:2] == b"PK":
        import io
        import zipfile
        try:
            z = zipfile.ZipFile(io.BytesIO(data))
            names = z.namelist()
        except Exception as e:
            return {**info, "error": f"zip 打不开: {e}"}
        guards = [n for n in names if n.endswith(".guard")]
        sos = [n for n in names if n.endswith(".so")]
        dexs = [n for n in names if n.endswith(".dex")]
        jss = [n for n in names if n.endswith(".js")]
        info["entries"] = len(names)
        if guards or any("wexguard" in s for s in sos):
            info["kind"] = "加固壳"
            info["guard"] = guards
            info["so"] = sos
        elif jss:
            info["kind"] = "js 规则包"
            info["js"] = len(jss)
        elif dexs:
            info["kind"] = "纯 dex jar"
            info["dex"] = dexs
    elif data[:4] == b"dex\n":
        info["kind"] = "单个 dex"
    elif data.lstrip()[:1] in (b"{", b"["):
        info["kind"] = "内联规则 JSON"
    else:
        head = data[:200].lstrip()
        if head.startswith(b"//") or b"function" in head or b"var " in head:
            info["kind"] = "js 脚本"
    return info


def probe_cms(site, timeout=8):
    """对 CMS 站点发一次分类请求，判断活着没有。"""
    api = strip_suffix(site.get("api") or "")
    if not api.startswith("http"):
        return False, "api 不是 http"
    url = api + ("&" if "?" in api else "?") + "ac=list"
    data, status, err = fetch(url, timeout=timeout)
    if err:
        return False, err
    if status != 200:
        return False, f"HTTP {status}"
    body = data[:200000]
    txt = body.decode("utf-8", "ignore")
    if '"list"' in txt or '"class"' in txt:
        return True, "maccms 响应正常"
    if txt.lstrip()[:1] == "<":
        return False, "返回 HTML（接口不是 maccms）"
    return False, "响应里没有 list/class"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("target")
    ap.add_argument("--probe", action="store_true", help="对 CMS 站点发真实请求探活")
    ap.add_argument("--limit", type=int, default=0, help="只显示前 N 个站点（0 = 全显示）")
    ap.add_argument("--json", action="store_true", help="输出 JSON")
    args = ap.parse_args()

    cfg = merge(load_config(args.target))
    sites = cfg.get("sites") or []
    parses = cfg.get("parses") or []
    lives = cfg.get("lives") or []
    spider = inspect_spider(cfg.get("spider") or "")

    rows = []
    for s in sites:
        rows.append({
            "key": s.get("key", ""),
            "name": s.get("name", ""),
            "type": s.get("type"),
            "api": (s.get("api") or "")[:80],
            "kind": site_kind(s),
            "ok": None,
            "note": "",
        })

    if args.probe:
        cms = [r for r in rows if r["kind"] == "CMS"]
        with futures.ThreadPoolExecutor(max_workers=8) as ex:
            futs = {ex.submit(probe_cms, s): r for s, r in
                    zip([s for s in sites if site_kind(s) == "CMS"], cms)}
            for f in futures.as_completed(futs):
                ok, note = f.result()
                futs[f]["ok"] = ok
                futs[f]["note"] = note

    stat = {}
    for r in rows:
        stat[r["kind"]] = stat.get(r["kind"], 0) + 1

    if args.json:
        print(json.dumps({"spider": spider, "stat": stat, "sites": rows,
                          "parses": len(parses), "lives": len(lives)},
                         ensure_ascii=False, indent=2))
        return

    print(f"配置：{args.target}")
    print(f"站点 {len(sites)} 个 | parses {len(parses)} 个 | lives {len(lives)} 个")
    print("\n站点分型：")
    label = {"CMS": "直接可用", "规则": "内置解释器", "js": "JSCore", "spider": "未知 spider",
             "加固": "加固壳（iOS 跑不了）"}
    for k, v in sorted(stat.items(), key=lambda x: -x[1]):
        print(f"  {k:8s} {v:4d}   {label.get(k, '')}")

    if spider:
        print("\nspider 包：")
        print(f"  {spider.get('url', '')}")
        print(f"  形态：{spider.get('kind')}  大小 {spider.get('size', 0):,}B")
        if spider.get("guard"):
            print(f"  加固载荷：{spider['guard']}")
            print(f"  解密 so ：{spider.get('so')}")
            print("  判定：三层壳（OLLVM so → 运行期解密 → DexClassLoader），静态路径走不通")
        if spider.get("error"):
            print(f"  错误：{spider['error']}")

    show = rows if args.limit <= 0 else rows[:args.limit]
    print(f"\n站点明细（显示 {len(show)}/{len(rows)}）：")
    for r in show:
        tail = ""
        if r["ok"] is True:
            tail = "  ✅ 活"
        elif r["ok"] is False:
            tail = f"  ❌ {r['note']}"
        print(f"  {r['kind']:6s} {r['key'][:22]:22s} {(r['name'] or '')[:14]:14s} {tail}")

    usable = stat.get("CMS", 0) + stat.get("规则", 0) + stat.get("js", 0)
    print(f"\n结论：{usable}/{len(sites)} 个站点在本项目里可跑，"
          f"{stat.get('加固', 0)} 个加固壳无法在客户端执行。")


if __name__ == "__main__":
    main()
