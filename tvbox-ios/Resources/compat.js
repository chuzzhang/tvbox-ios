// 新版 TVBox js spider 的兼容层。
//
// 这类脚本（`api` 指向 .js）用的是 ESM + cheerio + req() 那一套：
//   import cheerio from 'assets://js/lib/cheerio.min.js'
//   const html = (await req(url)).content
//   const $ = cheerio.load(html); $('.item').each((i, el) => $(el).find('a').attr('href'))
//   export default { init, home, category, detail, search, play }
//
// JSCore 里没有 module、没有 cheerio、没有 req，直接 eval 会在第 1 行语法错。
// 原生侧负责：剥掉 import/export、提供 __reqSync / __sel / __text / __attr / __log。
// 这个文件负责把它们拼成脚本期望的 API。
//
// 注意：这里所有网络都是同步的（原生侧信号量等 HTTP），所以 req 返回的
// content 是一个「立刻就能当字符串用、又能被 await」的 thenable String。
// 只给 Promise 的话，`(await req(u)).content` 这种写法会拿到 Promise 对象，
// 后面 .length / atob / substring 全崩。

(function () {
    'use strict';

    if (typeof globalThis === 'undefined') { return; }

    // ---------- console ----------
    function toText(args) {
        var out = [];
        for (var i = 0; i < args.length; i++) {
            var a = args[i];
            if (typeof a === 'string') { out.push(a); }
            else {
                try { out.push(JSON.stringify(a)); } catch (e) { out.push(String(a)); }
            }
        }
        return out.join(' ');
    }
    function emit(level, args) {
        try {
            if (typeof __log === 'function') { __log(level + ' ' + toText(args)); }
        } catch (e) { /* 日志通道断了不该影响脚本 */ }
    }
    globalThis.console = {
        log: function () { emit('', arguments); },
        info: function () { emit('', arguments); },
        warn: function () { emit('[warn]', arguments); },
        error: function () { emit('[error]', arguments); },
        debug: function () { emit('', arguments); },
    };

    // ---------- req ----------
    // 把同步拿到的字符串包成 String 对象，再挂一个 then：
    //   await req(u).content      → await 走 then，拿到原始字符串
    //   (await req(u)).content    → await 原对象（无 then 链），.content 本身就是字符串
    function makeContent(text) {
        var s;
        try { s = new String(text == null ? '' : text); }
        catch (e) { return text == null ? '' : text; }
        s.then = function (ok, fail) {
            try { return Promise.resolve(String(s)).then(ok, fail); }
            catch (e) { return Promise.resolve(String(s)); }
        };
        return s;
    }

    function headerJSON(opt) {
        var h = {};
        if (opt && opt.headers) {
            for (var k in opt.headers) {
                if (Object.prototype.hasOwnProperty.call(opt.headers, k)) { h[k] = String(opt.headers[k]); }
            }
        }
        return JSON.stringify(h);
    }

    globalThis.req = function (url, opt) {
        opt = opt || {};
        var method = String(opt.method || 'GET').toUpperCase();
        var body = '';
        if (opt.body != null) { body = typeof opt.body === 'string' ? opt.body : JSON.stringify(opt.body); }
        else if (opt.data != null) { body = typeof opt.data === 'string' ? opt.data : JSON.stringify(opt.data); }
        // buffer: 2 是 TVBox 的约定：返回 base64 而不是文本，脚本拿去做解密
        var asBase64 = opt.buffer === 2 || opt.buffer === true;
        var text = '';
        try {
            text = __reqSync(String(url), headerJSON(opt), method, body, asBase64 ? 1 : 0) || '';
        } catch (e) {
            text = '';
        }
        return {
            content: makeContent(text),
            text: makeContent(text),
            status: text ? 200 : 0,
            headers: {},
            json: function () {
                return Promise.resolve(text).then(function (t) { return JSON.parse(t); });
            },
        };
    };

    // ---------- cheerio ----------
    // 原生只认 CSS 选择器（SwiftSoup）。节点用 {h: outerHTML} 表示，
    // 需要取子节点时把 outerHTML 再丢回原生选一次 —— 解析开销在小页面上可忽略。
    function sel(html, s) {
        try {
            var raw = __sel(html, s);
            var arr = JSON.parse(raw || '[]');
            var out = [];
            for (var i = 0; i < arr.length; i++) { out.push({ h: arr[i] }); }
            return out;
        } catch (e) { return []; }
    }
    function nodeText(n) { try { return __text(n.h) || ''; } catch (e) { return ''; } }
    function nodeHtml(n) { try { return __innerHtml(n.h) || ''; } catch (e) { return ''; } }
    function nodeAttr(n, k) {
        try {
            var v = __attr(n.h, k);
            return (v === undefined || v === null || v === '') ? undefined : v;
        } catch (e) { return undefined; }
    }

    function Collection(nodes) {
        this._n = nodes || [];
        this.length = this._n.length;
    }
    Collection.prototype.each = function (fn) {
        for (var i = 0; i < this._n.length; i++) { fn.call(this._n[i], i, this._n[i]); }
        return this;
    };
    Collection.prototype.map = function (fn) {
        var out = [];
        for (var i = 0; i < this._n.length; i++) { out.push(fn.call(this._n[i], i, this._n[i])); }
        return new Collection(out);
    };
    Collection.prototype.get = function (i) {
        if (i === undefined) { return this._n.slice(); }
        return this._n[i];
    };
    Collection.prototype.toArray = function () { return this._n.slice(); };
    Collection.prototype.text = function () {
        var out = '';
        for (var i = 0; i < this._n.length; i++) { out += nodeText(this._n[i]); }
        return out;
    };
    Collection.prototype.html = function () {
        return this._n.length ? nodeHtml(this._n[0]) : null;
    };
    Collection.prototype.outerHtml = function () {
        return this._n.length ? this._n[0].h : null;
    };
    Collection.prototype.attr = function (name) {
        return this._n.length ? nodeAttr(this._n[0], name) : undefined;
    };
    Collection.prototype.find = function (s) {
        var out = [];
        for (var i = 0; i < this._n.length; i++) { out = out.concat(sel(this._n[i].h, s)); }
        return new Collection(out);
    };
    Collection.prototype.first = function () { return this.eq(0); };
    Collection.prototype.last = function () { return this.eq(this._n.length - 1); };
    Collection.prototype.eq = function (i) {
        var idx = i < 0 ? this._n.length + i : i;
        return new Collection(this._n[idx] ? [this._n[idx]] : []);
    };
    Collection.prototype.hasClass = function (c) {
        var v = this._n.length ? nodeAttr(this._n[0], 'class') : '';
        return !!v && (' ' + v + ' ').indexOf(' ' + c + ' ') >= 0;
    };

    function makeLoad(root) {
        function $(a) {
            if (a == null) { return new Collection([]); }
            if (typeof a === 'string') {
                // '<div>…' 当成一段 HTML，其余当选择器
                if (a.charAt(0) === '<') { return new Collection([{ h: a }]); }
                return new Collection(sel(root, a));
            }
            if (a instanceof Collection) { return a; }
            if (typeof a === 'object' && typeof a.h === 'string') { return new Collection([a]); }
            return new Collection([]);
        }
        $.html = function () { return root; };
        $.root = function () { return new Collection([{ h: root }]); };
        return $;
    }

    globalThis.cheerio = {
        load: function (html) { return makeLoad(html == null ? '' : String(html)); },
    };

    // ---------- Promise 抽头 ----------
    // 原生侧调完 home/category/... 拿到的是 Promise，JSCore 的微任务要靠
    // 反复进入 JS 才会被抽干。原生循环里读这三个变量。
    globalThis.__tb_state = 0;
    globalThis.__tb_value = null;
    globalThis.__tb_error = null;
    globalThis.__tb_watch = function (p) {
        globalThis.__tb_state = 0;
        globalThis.__tb_value = null;
        globalThis.__tb_error = null;
        if (!p || typeof p.then !== 'function') {
            globalThis.__tb_state = 1;
            globalThis.__tb_value = p;
            return 0;
        }
        p.then(
            function (v) { globalThis.__tb_value = v; globalThis.__tb_state = 1; },
            function (e) {
                globalThis.__tb_error = String((e && e.stack) || (e && e.message) || e);
                globalThis.__tb_state = 2;
            }
        );
        return 0;
    };

    // ---------- 老引擎缺的方法（iOS 15 的 JSCore 少一批 ES2022） ----------
    if (typeof Object.hasOwn !== 'function') {
        Object.hasOwn = function (o, k) { return Object.prototype.hasOwnProperty.call(o, k); };
    }
    if (typeof String.prototype.replaceAll !== 'function') {
        String.prototype.replaceAll = function (p, r) {
            if (p instanceof RegExp) { return this.replace(p, r); }
            return this.split(String(p)).join(String(r));
        };
    }
    if (typeof Array.prototype.at !== 'function') {
        Array.prototype.at = function (i) {
            var n = this.length;
            var idx = i < 0 ? n + i : i;
            return (idx < 0 || idx >= n) ? undefined : this[idx];
        };
    }
    if (typeof Array.prototype.findLast !== 'function') {
        Array.prototype.findLast = function (fn) {
            for (var i = this.length - 1; i >= 0; i--) { if (fn(this[i], i, this)) { return this[i]; } }
            return undefined;
        };
    }
    if (typeof globalThis.structuredClone !== 'function') {
        globalThis.structuredClone = function (v) {
            try { return JSON.parse(JSON.stringify(v)); } catch (e) { return v; }
        };
    }
})();
