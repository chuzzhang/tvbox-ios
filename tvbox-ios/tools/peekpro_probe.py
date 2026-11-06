#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
PeekPro / 羊壳订阅体检：验证一个 node 型订阅包能不能用，并列出它里面的站点。

用法：
    python tools/peekpro_probe.py <订阅URL> [--user 用户名:密码] [--limit N]
                                 [--port 9978] [--node node] [--keep] [--json]

订阅形态（TVS / CatVodSpiderios 这套）：
    <base>.md5   32 字节文本，是 bundle 的 md5
    <base>       一个 esbuild 打出来的 Node 包，导出 start/stop，内部是 fastify

本工具做的事：
    1. 拉 .md5 → 拉 bundle → 校验 md5（对不上就直接说，别往下跑）
    2. 生成一个最小 bootstrap（等价于 assets/js/node-main-template.js），起 node
    3. GET  /health  /config，打印站点数量与分节（video / pan / music / comic / read）
    4. 对前 N 个站点依次 POST /spider/<key>/3/home，报告每个站能不能出分类
    5. 关掉 node（--keep 保留目录，方便手动 curl）

为什么必须真跑：这类订阅的站点表、云盘配置都是运行期从远端拉的
（bundle 里 RemoteWexConfig 会去取 api.txt / ioswex.txt / site.jpg），
静态看 JS 只能看到壳，看不到站点。
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")

# 等价于 TVS 的 node-main-template.js 里那一段。只保留订阅包真正依赖的：
# catServerFactory（它用这个开 http server）、jsProxy、local、以及 db.json 初始结构。
HARNESS = r"""
const http = require('http');
const fs = require('fs');
const path = require('path');
const dir = __dirname;

process.env.PORT = process.env.PROBE_PORT;
process.env.DART_PORT = '0';
process.env.NODE_PATH = path.join(dir, 'node');
process.env.BUNDLE_PATH = path.join(dir, 'bundle.js');

// iOS 上 V8 没有 JIT，WebAssembly 不可用，undici 会崩；这里照抄同样的 polyfill
if (typeof globalThis.WebAssembly === 'undefined') {
    const m = { exports: { instances: {} } }, i = { exports: {} };
    globalThis.WebAssembly = {
        compile: () => Promise.resolve(m),
        instantiate: () => Promise.resolve({ module: m, instance: i }),
        validate: () => true,
        Module: function () { return m; },
        Instance: function () { return i; },
        Memory: function (o) { this.buffer = new ArrayBuffer(o.initial * 65536); },
        Table: function () {},
    };
}

globalThis.__catServers = [];
globalThis.catServerFactory = function (handler) {
    const server = http.createServer(handler);
    globalThis.__catServers.push(server);
    return server;
};
globalThis.catDartServerPort = () => 0;
globalThis.jsProxy = 'http://127.0.0.1:' + process.env.PORT + '/proxy?do=js&url=';
globalThis.local = { get: (k, d) => (d || ''), set: () => {} };
process.on('unhandledRejection', () => {});
process.on('uncaughtException', (e) => console.log('[uncaught]', e && e.message));

fs.mkdirSync(process.env.NODE_PATH, { recursive: true });
fs.writeFileSync(
    path.join(process.env.NODE_PATH, 'db.json'),
    JSON.stringify({ pans: { list: [] }, sites: { list: [] }, flags: [] }),
);

const startOpts = {
    color: [], sites: { list: [] }, pans: { list: [] }, ali: { token: '' }, baidu: { cookie: '' },
    bilibili_all: { cookie: '', classes_all: '', filters_all: '' }, cms: {}, danmu: {}, dudb: {},
    guazi: { url: '', token: '' }, live: [], mycloud: { text: '' }, pan123: { username: '', password: '' },
    pikpak: { username: '', email: '', password: '', refresh_token: '', device_id: '', user_id: '' },
    quark: { cookie: '' }, server: {}, sharemount: { text: '', batchTiers: {} }, t4: {}, tgsou: {},
    tianyi: { username: '', password: '' }, uc: { cookie: '', token: '', ut: '' },
    xunlei: { username: '', password: '' }, y115: { cookie: '', offline: {} },
};

const bundle = require(process.env.BUNDLE_PATH);
bundle.start(startOpts)
    .then(() => console.log('[probe] started on ' + process.env.PORT))
    .catch((e) => {
        console.log('[probe] start failed: ' + (e && e.message));
        console.log(e && e.stack);
    });
// 不主动退出：由外面 kill
"""


def fetch(url, user=None, timeout=60, binary=True):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    if user:
        import base64
        tok = base64.b64encode(user.encode()).decode()
        req.add_header("Authorization", "Basic " + tok)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = r.read()
        return data, r.geturl(), r.status


def main():
    ap = argparse.ArgumentParser(description="PeekPro/羊壳 node 型订阅体检")
    ap.add_argument("url", help="订阅地址，通常以 .js.md5 结尾")
    ap.add_argument("--user", default="", help="HTTP Basic 认证，形如 用户名:密码")
    ap.add_argument("--limit", type=int, default=3, help="抽几个站点做 home 探测")
    ap.add_argument("--port", type=int, default=9978)
    ap.add_argument("--node", default="node")
    ap.add_argument("--keep", action="store_true", help="保留临时目录与进程，方便手动 curl")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    out = {"subscription": args.url}

    # 1) md5
    md5_url = args.url if args.url.lower().endswith(".md5") else args.url + ".md5"
    bundle_url = md5_url[:-4]
    try:
        data, final, _ = fetch(md5_url, args.user, timeout=30)
        want = data.decode("utf-8", "replace").strip().split()[0].lower()
        out["md5"] = want
        print(f"md5 文件      {md5_url}  →  {want}（{len(data)} 字节）")
    except Exception as e:
        print(f"md5 取不到：{e}")
        return 2

    # 2) bundle
    try:
        data, final, status = fetch(bundle_url, args.user, timeout=180)
    except Exception as e:
        print(f"bundle 取不到：{e}")
        return 2
    got = hashlib.md5(data).hexdigest()
    out["bundle"] = {"url": final, "bytes": len(data), "md5": got, "match": got == want}
    print(f"bundle        {final}")
    print(f"              {len(data):,} 字节  md5 {got}  {'✓ 一致' if got == want else '✗ 与 .md5 不一致'}")
    if got != want:
        print("md5 对不上：可能是 CDN 缓存了旧版本，或订阅方更新了包但没刷 .md5。"
              "继续跑能验证内容，但别把它当权威版本。")

    text = data.decode("utf-8", "replace")
    signs = {
        "esbuild 打包": "__esModule" in text,
        "导出 start/stop": bool(re.search(r"module\.exports\s*=", text)) and "start:" in text,
        "fastify": "fastify" in text.lower(),
        "cheerio": "cheerio" in text,
        "axios": "axios" in text,
        "云盘驱动": all(k in text for k in ("quark", "xunlei")) or "pan.priority" in text,
        "catServerFactory": "catServerFactory" in text,
    }
    out["signs"] = signs
    print("包特征        " + "  ".join(f"{k}={'✓' if v else '✗'}" for k, v in signs.items()))

    # 3) 起服务
    node = shutil.which(args.node) or args.node
    if not node:
        print("找不到 node，跳过运行期探测（只做了静态判断）")
        return 0
    work = tempfile.mkdtemp(prefix="peekpro_")
    open(os.path.join(work, "bundle.js"), "wb").write(data)
    open(os.path.join(work, "main.js"), "w", encoding="utf-8").write(HARNESS)
    env = dict(os.environ, PROBE_PORT=str(args.port))
    log_path = os.path.join(work, "node.log")
    log = open(log_path, "w", encoding="utf-8", errors="replace")
    proc = subprocess.Popen([node, "main.js"], cwd=work, env=env,
                            stdout=log, stderr=subprocess.STDOUT)

    base = f"http://127.0.0.1:{args.port}"
    up = False
    for _ in range(60):
        time.sleep(1)
        try:
            with urllib.request.urlopen(base + "/health", timeout=3) as r:
                if r.status == 200:
                    up = True
                    break
        except Exception:
            continue
    if not up:
        log.close()
        print(f"服务没起来，日志尾部：\n" + tail(log_path))
        if not args.keep:
            shutil.rmtree(work, ignore_errors=True)
        return 3
    print(f"服务          {base}  已就绪")

    def post(path, body):
        req = urllib.request.Request(base + path, method="POST",
                                     data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode("utf-8", "replace"))

    def get(path):
        with urllib.request.urlopen(base + path, timeout=30) as r:
            return json.loads(r.read().decode("utf-8", "replace"))

    cfg = get("/config")
    v = cfg.get("video") or {}
    sites = v.get("sites") or []
    sections = {k: len(cfg.get(k, {}).get("sites") or []) for k in ("video", "read", "comic", "music", "pan") if k in cfg}
    out["sections"] = sections
    out["sites"] = len(sites)
    print(f"配置          /config  {len(sites)} 个站点，分节 " +
          " ".join(f"{k}={n}" for k, n in sections.items()))

    # 站点 api 只有 /spider/<key>/<type> 这一种
    keys = []
    for s in sites:
        api = str(s.get("api") or "")
        m = re.match(r"^/spider/([^/]+)/(\d+)$", api)
        if m:
            keys.append((s.get("key"), s.get("name"), m.group(1), m.group(2)))
    out["spider_sites"] = len(keys)
    print(f"              {len(keys)} 个走本地 node（api=/spider/<key>/<type>），"
          f"其余 {len(sites) - len(keys)} 个是别的形态")

    # 4) 逐个探 home
    probes = []
    for key, name, sk, st in keys[: max(args.limit, 0)]:
        rec = {"key": key, "name": name, "spider": sk, "type": st}
        try:
            h = post(f"/spider/{sk}/{st}/home", {})
            cls = h.get("class") or []
            rec["class"] = len(cls)
            rec["first_class"] = cls[0].get("type_name") if cls else None
            rec["list"] = len(h.get("list") or [])
            if cls:
                cid = cls[0].get("type_id")
                c = post(f"/spider/{sk}/{st}/category", {"id": cid, "page": 1, "filters": {}})
                rec["category_items"] = len(c.get("list") or [])
                rec["pagecount"] = c.get("pagecount")
                rec["sample"] = (c.get("list") or [{}])[0].get("vod_name")
            rec["ok"] = bool(cls)
        except Exception as e:
            rec["ok"] = False
            rec["error"] = str(e)[:160]
        probes.append(rec)
        flag = "✓" if rec.get("ok") else "✗"
        print(f"  {flag} {name or key:18s} 分类 {rec.get('class','-')}  "
              f"条目 {rec.get('category_items','-')} 页数 {rec.get('pagecount','-')}  "
              f"{(rec.get('sample') or rec.get('error') or '')[:36]}")
    out["probes"] = probes

    proc.terminate()
    try:
        proc.wait(timeout=8)
    except Exception:
        proc.kill()
    log.close()

    if args.keep:
        print(f"\n--keep：目录留在 {work}，可自行 curl {base}/spider/<key>/3/home")
    else:
        shutil.rmtree(work, ignore_errors=True)

    if args.json:
        print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0


def tail(path, n=25):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return "".join(f.readlines()[-n:])
    except Exception:
        return "（日志读不到）"


if __name__ == "__main__":
    sys.exit(main())
