#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
TLS 体检器：找出配置里「https 握手被掐、但 http 还通」的源站。

症状对照：iOS 上点站点报「TLS 错误，无法建立安全连接」（NSURLErrorSecureConnectionFailed / -1200）。
这不是证书问题——证书错会报 -1201/-1202，而且客户端已经放开校验。真正的成因是
ClientHello 带着 SNI 发出去之后对端一个字节都不回（链路按 SNI 掐断）。

本工具对每个站点分三步判定：
    1. TCP 连 443 能不能连上
    2. 带 SNI 做 TLS 握手能不能完成
    3. 80 端口能不能拿到 2xx/3xx

输出四类：
    ok            https 正常
    sni-blocked   TLS 握手拿不到任何响应，但 http 通   → 客户端降级到 http 即可用
    tls-broken    TLS 握手失败且 http 也不通            → 站点死了或只支持被废掉的协议
    dead          443 连不上

用法：
    python tools/check_tls.py <配置URL或文件> [--limit N] [--json]

复杂度：按域名去重，每个域名三次网络往返；并发 10，单步超时 6 秒。
"""
import argparse
import concurrent.futures as futures
import json
import os
import socket
import ssl
import sys
import urllib.error
import urllib.request
from urllib.parse import urlsplit

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")

# 关掉环境代理：这里要测的是直连，走代理会把结论测反
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def strip_suffix(u):
    return (u or "").split(";")[0].strip()


def load_config(target):
    if os.path.exists(target):
        raw = open(target, "rb").read()
    else:
        req = urllib.request.Request(target, headers={"User-Agent": UA})
        with _OPENER.open(req, timeout=20) as r:
            raw = r.read()
    for enc in ("utf-8-sig", "utf-8", "gb18030"):
        try:
            return json.loads(raw.decode(enc))
        except Exception:
            continue
    sys.exit("配置解析失败（编码或 JSON 结构问题）")


def tcp_ok(host, port, timeout=6):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True, ""
    except Exception as e:
        return False, str(e)


def tls_probe(host, port=443, timeout=6):
    """返回 (ok, detail)。拿不到 ServerHello 视作失败，区分于「证书不对」。"""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        ctx.set_ciphers("DEFAULT:@SECLEVEL=0")
    except Exception:
        pass
    try:
        with socket.create_connection((host, port), timeout=timeout) as sock:
            with ctx.wrap_socket(sock, server_hostname=host) as ss:
                return True, f"{ss.version()} {ss.cipher()[0]}"
    except socket.timeout:
        return False, "超时（ClientHello 无响应）"
    except (ssl.SSLEOFError, ConnectionResetError):
        return False, "连接被重置（ClientHello 后被掐）"
    except ssl.SSLError as e:
        return False, f"SSL 错误：{getattr(e, 'reason', e)}"
    except Exception as e:
        return False, str(e)


def http_probe(url, timeout=6):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with _OPENER.open(req, timeout=timeout) as r:
            body = r.read(4096)
            return r.status, body
    except urllib.error.HTTPError as e:
        return e.code, b""
    except Exception:
        return 0, b""


def classify(host, path):
    ok443, detail443 = tcp_ok(host, 443)
    if not ok443:
        code80, _ = http_probe(f"http://{host}{path}")
        return ("dead", f"443 连不上（{detail443}）；80 → HTTP {code80}")

    ok_tls, detail = tls_probe(host)
    code80, body80 = http_probe(f"http://{host}{path}")
    http_ok = 200 <= code80 < 400 and len(body80) > 0

    if ok_tls:
        if http_ok:
            return ("ok", detail)
        return ("ok", detail + "；80 端口不可用（只能走 https）")
    if http_ok:
        return ("sni-blocked", f"{detail}；80 → HTTP {code80}，有响应体")
    return ("tls-broken", f"{detail}；80 → HTTP {code80}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("target")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    cfg = load_config(args.target)
    sites = cfg.get("sites") or []

    # 域名去重：同一个 host 只测一次
    host_map = {}
    for s in sites:
        api = strip_suffix(s.get("api") or "")
        if not api.lower().startswith(("http://", "https://")):
            continue
        sp = urlsplit(api)
        if not sp.hostname:
            continue
        host_map.setdefault(sp.hostname, []).append((s.get("key", ""), api))

    print(f"配置：{args.target}")
    print(f"站点 {len(sites)} 个，可测域名 {len(host_map)} 个\n")

    results = {}
    with futures.ThreadPoolExecutor(max_workers=10) as ex:
        futs = {}
        for host, items in host_map.items():
            path = urlsplit(items[0][1]).path or "/"
            futs[ex.submit(classify, host, path)] = host
        for f in futures.as_completed(futs):
            host = futs[f]
            try:
                results[host] = f.result()
            except Exception as e:
                results[host] = ("error", str(e))

    order = {"sni-blocked": 0, "tls-broken": 1, "dead": 2, "error": 3, "ok": 9}
    rows = sorted(results.items(), key=lambda kv: (order.get(kv[1][0], 5), kv[0]))
    if args.limit > 0:
        rows = rows[:args.limit]

    if args.json:
        print(json.dumps({h: {"verdict": v[0], "detail": v[1],
                              "sites": [k for k, _ in host_map[h]]}
                          for h, v in results.items()}, ensure_ascii=False, indent=2))
        return

    stat = {}
    for h, (v, _) in results.items():
        stat[v] = stat.get(v, 0) + 1

    for host, (verdict, detail) in rows:
        keys = ", ".join(k for k, _ in host_map[host][:3])
        mark = {"ok": "OK  ", "sni-blocked": "SNI ", "tls-broken": "TLS ", "dead": "DEAD"}.get(verdict, "??  ")
        print(f"  [{mark}] {host:34s} {detail[:70]}")
        print(f"         站点：{keys}")

    print("\n判定统计：")
    meaning = {"ok": "https 正常", "sni-blocked": "降级 http 可用", "tls-broken": "https 挂、http 也挂",
               "dead": "连不上", "error": "探测异常"}
    for k, v in sorted(stat.items(), key=lambda kv: -kv[1]):
        print(f"  {k:12s} {v:3d}   {meaning.get(k, '')}")

    n = stat.get("sni-blocked", 0)
    print(f"\n结论：{stat.get('ok', 0)} 个域名 https 可用；"
          f"{n} 个 TLS 握手被掐但 http 通（客户端降级后可用）；"
          f"{stat.get('tls-broken', 0) + stat.get('dead', 0)} 个站点本身已不可用。")


if __name__ == "__main__":
    main()
