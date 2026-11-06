/*
 * frida_hook_http.js —— 抓 TVBox jar 站点真正发出的 HTTP 请求
 *
 * 为什么用这个而不是纯静态逆向：像 clun.top/pg.jar 这种包，站点类只是薄壳，
 * 域名在运行期拼装、字符串还走了混淆层，dex 里扫不出来。但不管怎么混淆，
 * 最后都得走 okhttp 发出去 —— 在发的那一刻抄下来，地址、参数、请求头全有。
 *
 * 用法（Android 侧，需 root 或能跑 frida-server）：
 *   adb push frida_hook_http.js /data/local/tmp/
 *   adb shell "su -c '/data/local/tmp/frida-server &'"
 *   frida -U -f <TVBox包名> -l /data/local/tmp/frida_hook_http.js --no-pause
 *   # 然后在 App 里点开目标站点，进分类、进详情、点播放，各触发一次
 *
 * 产物：控制台实时打印，同时落盘到 /data/local/tmp/httpdump.log
 *   adb pull /data/local/tmp/httpdump.log
 *
 * 覆盖点：
 *   1. okhttp3.Request$Builder.build —— 请求发出前的 URL / header / body
 *   2. okhttp3.Response.body().string() —— 返回体（只截前 800 字，够看结构）
 *   3. java.net.URL.openConnection —— 兜底，有的实现不用 okhttp
 *
 * 复杂度：每个请求两次 Java 调用开销，正常使用无感。
 */
'use strict';

var LOG = '/data/local/tmp/httpdump.log';

function out(s) {
    console.log(s);
    try {
        var f = new File(LOG, 'a');
        f.write(s + '\n');
        f.flush();
        f.close();
    } catch (e) {}
}

function short(s, n) {
    if (!s) return '';
    s = String(s);
    return s.length > n ? s.slice(0, n) + '…' : s;
}

function looksInteresting(url) {
    if (!url) return false;
    // 图片/样式/字体不用看，日志会被刷没
    return !/\.(png|jpe?g|gif|webp|css|woff2?|svg|ico)(\?|$)/i.test(url);
}

Java.perform(function () {
    out('===== hook 开始 ' + new Date().toISOString() + ' =====');

    /* 1) okhttp3 请求 */
    try {
        var Builder = Java.use('okhttp3.Request$Builder');
        var build = Builder.build;
        build.implementation = function () {
            var req = build.call(this);
            try {
                var url = String(req.url().toString());
                if (looksInteresting(url)) {
                    var method = String(req.method());
                    out('\n--> ' + method + ' ' + url);
                    var h = req.headers();
                    var n = h.size();
                    for (var i = 0; i < n; i++) {
                        var name = String(h.name(i));
                        // cookie / authorization 打码，其余照打
                        var val = /cookie|authorization|token/i.test(name)
                            ? '***'
                            : short(String(h.value(i)), 160);
                        out('    ' + name + ': ' + val);
                    }
                    try {
                        var b = req.body();
                        if (b !== null) {
                            var cls = b.getClass().getName();
                            if (cls.indexOf('FormBody') >= 0) {
                                var fb = Java.cast(b, Java.use('okhttp3.FormBody'));
                                var parts = [];
                                for (var j = 0; j < fb.size(); j++) {
                                    parts.push(fb.name(j) + '=' + fb.value(j));
                                }
                                out('    body: ' + parts.join('&'));
                            } else {
                                out('    body: <' + cls + '>');
                            }
                        }
                    } catch (e) {}
                }
            } catch (e) {}
            return req;
        };
        out('[ok] okhttp3.Request$Builder');
    } catch (e) {
        out('[--] 没有 okhttp3：' + e);
    }

    /* 2) 响应体：只看 JSON/XML，够反推接口结构 */
    try {
        var Resp = Java.use('okhttp3.Response');
        var body = Resp.body;
        body.implementation = function () {
            var b = body.call(this);
            try {
                if (b !== null) {
                    var ct = String(b.contentType() || '');
                    if (/json|xml|text/i.test(ct)) {
                        var s = b.string();          // 会消费掉流，所以先 clone 不现实，直接打完再返回新 body
                        if (s) out('    <-- ' + short(s.replace(/\s+/g, ' '), 800));
                        return okhttpBody(s, ct);
                    }
                }
            } catch (e) {}
            return b;
        };
        out('[ok] okhttp3.Response.body');
    } catch (e) {
        out('[--] 响应体挂钩失败：' + e);
    }

    /* 读过的流要还给调用方，否则播放器拿不到数据 */
    function okhttpBody(text, contentType) {
        try {
            var MediaType = Java.use('okhttp3.MediaType');
            var ResponseBody = Java.use('okhttp3.ResponseBody');
            var mt = null;
            try { mt = MediaType.parse(contentType); } catch (e) {}
            return ResponseBody.create(mt, text);
        } catch (e) {
            return null;
        }
    }

    /* 3) 兜底：URLConnection */
    try {
        var URL = Java.use('java.net.URL');
        var open = URL.openConnection;
        open.implementation = function () {
            var conn = open.call(this);
            try {
                var u = String(this.toString());
                if (looksInteresting(u)) out('--> [urlconn] ' + u);
            } catch (e) {}
            return conn;
        };
        out('[ok] java.net.URL.openConnection');
    } catch (e) {}
});
