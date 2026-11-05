/*
 * drpy_lite.js —— drpy / hipy 的 json 规则解释器（iOS / JavaScriptCore）
 *
 * 由 Swift 端注入 __drpy_rule__（规则对象）与 __drpy_host__（站点 origin），
 * 依赖宿主提供的原生桥：pdfh(html, sel) / pdfa(html, sel) / request(url, opt) / joinUrl。
 *
 * 整段包在 IIFE 里：原版 drpy.min.js 能下到时优先用它的实现，
 * 只有它没定义某个函数时才由这里接管，避免互相覆盖。
 *
 * 规则语法（cat 系通用）：
 *   一级/列表 = "父选择器;标题;链接;图片;副标题"
 *   二级/详情 = "父选择器;标题;图片;简介;线路容器;线路名;线路链接"
 *   分类url   = "https://x.com/vodshow/fyclass/page/fypage.html"
 *   搜索url   = "https://x.com/search.php?wd=**&page=fypage"
 * 选择器链用 && 串：`a&&Text`、`img&&data-original`、`a&&title`。
 */

(function (__G) {

var __drpy_rule__ = (typeof __G.__drpy_rule__ !== 'undefined' && __G.__drpy_rule__) ? __G.__drpy_rule__ : {};
var __drpy_host__ = (typeof __G.__drpy_host__ !== 'undefined') ? __G.__drpy_host__ : '';

function init(r) {
    if (r) __drpy_rule__ = r;
}

/* ---------------- 基础工具 ---------------- */

function _s(v) {
    if (v === undefined || v === null) return '';
    if (typeof v === 'string') return v;
    if (typeof v === 'number' || typeof v === 'boolean') return String(v);
    return '';
}

function _pick(o, names) {
    if (!o) return '';
    for (var i = 0; i < names.length; i++) {
        var k = names[i];
        if (o[k] === undefined || o[k] === null) continue;
        var v = o[k];
        if (typeof v === 'string') {
            if (v.replace(/\s/g, '') !== '' && v !== 'undefined') return v;
            continue;
        }
        if (typeof v === 'object') return v;
        return String(v);
    }
    return '';
}

/* 规则本体可能包在 "规则" / "rule" 里，也可能直接是顶层 */
function _rules() {
    var r = __drpy_rule__ || {};
    if (!_isEmpty(r)) {
        if (r['规则'] && typeof r['规则'] === 'object') return r['规则'];
        if (r['rule'] && typeof r['rule'] === 'object') return r.rule;
        return r;
    }
    // ext 是 js 规则时，规则就写在全局 rule 里
    if (typeof __G.rule !== 'undefined' && __G.rule && typeof __G.rule === 'object') return __G.rule;
    return r;
}

function _isEmpty(o) {
    if (!o) return true;
    for (var k in o) {
        if (Object.prototype.hasOwnProperty.call(o, k)) return false;
    }
    return true;
}

function _unesc(s) {
    return String(s || '')
        .replace(/&nbsp;/gi, ' ')
        .replace(/&amp;/gi, '&')
        .replace(/&lt;/gi, '<')
        .replace(/&gt;/gi, '>')
        .replace(/&quot;/gi, '"')
        .replace(/&#39;|&apos;/gi, "'")
        .replace(/&#(\d+);/g, function (m, d) { return String.fromCharCode(parseInt(d, 10)); });
}

function _plain(block) {
    var s = String(block || '');
    s = s.replace(/<script[\s\S]*?<\/script>/gi, ' ');
    s = s.replace(/<style[\s\S]*?<\/style>/gi, ' ');
    s = s.replace(/<[^>]*>/g, ' ');
    return _unesc(s).replace(/[\s\u3000]+/g, ' ').trim();
}

function _attr(block, name) {
    var re = new RegExp(name + '\\s*=\\s*["\']([^"\']*)["\']', 'i');
    var m = re.exec(String(block || ''));
    if (!m) {
        re = new RegExp(name + '\\s*=\\s*([^\\s>]+)', 'i');
        m = re.exec(String(block || ''));
    }
    return m ? _unesc(m[1]) : '';
}

var _TAGS = /^(a|div|span|img|li|ul|ol|p|em|i|b|strong|font|td|th|tr|table|section|article|body|html|h[1-6]|dd|dt|dl|video|source|iframe|nav|header|footer|main|time|small|label|option|input)$/i;

function _isMode(s) {
    if (/^(Text|Html|OuterHtml|text|html)$/i.test(s)) return true;
    if (!s || s.length > 24) return false;
    if (_TAGS.test(s)) return false;
    if (/[\s.#>\[]/.test(s)) return false;
    return /^[A-Za-z_][\w:-]*$/.test(s);
}

/* 在单块 html 上取一个值 */
function _txt(block, sel) {
    var s = String(sel || '').trim();
    if (!s) return '';
    if (s.indexOf('&&') < 0 && _isMode(s)) {
        if (/^Text$/i.test(s)) return _plain(block);
        if (/^Html$|^OuterHtml$/i.test(s)) return String(block || '');
        return _attr(block, s);
    }
    try {
        var v = pdfh(block, s);
        return v ? _unesc(String(v)).trim() : '';
    } catch (e) {
        return '';
    }
}

/* 取一组元素，按模式映射成字符串数组 */
function _collect(html, sel) {
    var s = String(sel || '').trim();
    if (!s) return [];
    var mode = 'Text';
    var css = s;
    var i = s.lastIndexOf('&&');
    if (i > 0) {
        var tail = s.substring(i + 2).trim();
        if (_isMode(tail)) {
            mode = tail;
            css = s.substring(0, i);
        }
    }
    var els = [];
    try { els = pdfa(html, _css(css)) || []; } catch (e) { els = []; }
    var out = [];
    for (var k = 0; k < els.length; k++) {
        var v;
        if (/^Text$/i.test(mode)) v = _plain(els[k]);
        else if (/^Html$|^OuterHtml$/i.test(mode)) v = String(els[k] || '');
        else v = _attr(els[k], mode);
        out.push(v || '');
    }
    return out;
}

/* 规则里的选择器常写成 `body&&.list .item`，pdfa 不认 body&& 前缀 */
function _css(s) {
    var t = String(s || '').replace(/^\s+|\s+$/g, '');
    t = t.replace(/^body\s*&&\s*/i, '');
    if (!t || t === 'body') return 'body';
    return t;
}

function _split(spec) {
    var raw = _s(spec).split(';');
    var out = [];
    for (var i = 0; i < raw.length; i++) out.push(raw[i].replace(/^\s+|\s+$/g, ''));
    while (out.length && out[out.length - 1] === '') out.pop();
    return out;
}

/* ---------------- 地址 ---------------- */

function _host() {
    if (__drpy_host__) return String(__drpy_host__).replace(/\/+$/, '');
    var r = _rules();
    var h = _s(_pick(r, ['host', '域名', '首页', 'home', 'homeUrl', '网址', '站点']));
    if (h) {
        var m = /^https?:\/\/[^\/]+/i.exec(h);
        if (m) return m[0];
    }
    return '';
}

function _abs(u) {
    var s = _s(u).trim();
    if (!s) return '';
    if (/^https?:\/\//i.test(s)) return s;
    if (s.indexOf('//') === 0) return 'https:' + s;
    var h = _host();
    if (!h) return s;
    if (s.charAt(0) === '/') return h + s;
    return h + '/' + s;
}

function _headers() {
    var r = _rules();
    var h = _pick(r, ['headers', '请求头', 'header']);
    if (h && typeof h === 'object') {
        var out = {};
        for (var k in h) {
            if (Object.prototype.hasOwnProperty.call(h, k)) out[k] = _s(h[k]);
        }
        return out;
    }
    return {};
}

function _get(url) {
    if (!url) return '';
    var h = _headers();
    // 规则没写 Referer 时补站点主页：不少源站只校验 Referer
    var hasRef = false;
    for (var k in h) {
        if (/^referer$/i.test(k) && h[k]) { hasRef = true; break; }
    }
    if (!hasRef) {
        var host = _host();
        if (host) h['Referer'] = host + '/';
    }
    try {
        var body = request(url, { headers: h });
        return body ? String(body) : '';
    } catch (e) {
        return '';
    }
}

/* ---------------- 首页分类 ---------------- */

function _parseCateString(str) {
    var out = [];
    var segs = String(str).split('#');
    for (var i = 0; i < segs.length; i++) {
        var seg = segs[i].replace(/^\s+|\s+$/g, '');
        if (!seg) continue;
        if (/^https?:\/\//i.test(seg)) {
            out.push({ type_name: seg, type_id: seg });
            continue;
        }
        var parts = seg.split(/[&$|,]/);
        if (parts.length >= 2) {
            var name = parts[0].replace(/^\s+|\s+$/g, '');
            var id = parts[parts.length - 1].replace(/^\s+|\s+$/g, '');
            if (name && id) out.push({ type_name: name, type_id: id });
        }
    }
    return out;
}

/* 从导航链接里猜分类，规则没写分类时兜底 */
function _navLinks(html) {
    var els = [];
    try { els = pdfa(html, 'a') || []; } catch (e) { els = []; }
    var out = [];
    var seen = {};
    for (var i = 0; i < els.length && out.length < 24; i++) {
        var href = _attr(els[i], 'href');
        if (!href || href === '#' || href.indexOf('javascript') === 0) continue;
        var text = _plain(els[i]);
        if (!text || text.length > 8) continue;
        if (!/type|vodtype|list|vodshow|class|\/vod\//i.test(href)) continue;
        if (seen[href]) continue;
        seen[href] = 1;
        out.push({ type_name: text, type_id: _abs(href) });
    }
    return out;
}

/*
 * drpy 的 js 规则（ext 是 xxx.js）用的是英文字段：
 *   class_name: ['电影','剧集']      class_url: ['1','2'] 或 '/vodtype/fyclass.html'
 *   url: '/vodshow/fyclass--------fypage---.html'
 *   searchUrl: '/vodsearch/-------------.html?wd=**&page=fypage'
 * 这类规则在中文 JSON 规则里没有对应字段，必须单独认，否则首页分类永远是空的。
 */
function _classFromArrays(r) {
    var names = _pick(r, ['class_name', 'class_names', 'className']);
    if (!names || typeof names !== 'object' || !names.length) return null;

    var urls = _pick(r, ['class_url', 'class_urls', 'classUrl']);
    var exclude = _s(_pick(r, ['cate_exclude', 'cateExclude', 'exclude']));
    var skip = exclude ? exclude.split(/[|,]/) : [];

    var out = [];
    for (var i = 0; i < names.length; i++) {
        var n = _s(names[i]).replace(/^\s+|\s+$/g, '');
        if (!n) continue;
        var drop = false;
        for (var k = 0; k < skip.length; k++) {
            if (skip[k] && n.indexOf(skip[k]) >= 0) { drop = true; break; }
        }
        if (drop) continue;

        var u = '';
        if (urls && typeof urls === 'object' && urls.length) u = _s(urls[i]);
        else if (typeof urls === 'string' && urls) u = urls;
        if (!u) u = n;
        out.push({ type_name: n, type_id: u });
    }
    return out.length ? out : null;
}

function homeContent(filter) {
    var r = _rules();

    var byArrays = _classFromArrays(r);
    if (byArrays) return { class: byArrays };

    var cateRaw = _pick(r, ['分类', 'class', '分类数据', 'categories', 'class_parse']);

    if (cateRaw && typeof cateRaw === 'object' && cateRaw.length) {
        var arr = [];
        for (var i = 0; i < cateRaw.length; i++) {
            var it = cateRaw[i];
            if (!it) continue;
            var n = _s(it.type_name || it.name || it.title);
            var id = _s(it.type_id || it.id || it.url);
            if (n && id) arr.push({ type_name: n, type_id: id });
        }
        if (arr.length) return { class: arr };
    }

    if (typeof cateRaw === 'string' && cateRaw) {
        var parsed = _parseCateString(cateRaw);
        if (parsed.length > 1) return { class: parsed };
        // 单个"分类"字符串也可能是选择器，落到下面按选择器抓
    }

    var home = _abs(_s(_pick(r, ['首页', 'home', 'homeUrl', '网址', '分类url', 'url'])));
    var html = _get(home);

    // 分类写成选择器：".nav a&&Text&&href" 这种
    if (typeof cateRaw === 'string' && cateRaw.indexOf('&&') > 0 && html) {
        var names = _collect(html, cateRaw);
        var links = _collect(html, cateRaw.replace(/&&[^&]+$/, '&&href'));
        var res = [];
        for (var j = 0; j < names.length && j < links.length; j++) {
            if (names[j] && links[j]) res.push({ type_name: names[j], type_id: _abs(links[j]) });
        }
        if (res.length) return { class: res };
    }

    if (html) {
        var nav = _navLinks(html);
        if (nav.length) return { class: nav };
    }
    return { class: [] };
}

/* ---------------- 分类列表 ---------------- */

function _fillCate(tpl, tid, pg) {
    var s = String(tpl || '');
    s = s.replace(/fyclass|\{cateId\}|\*\*/g, tid);
    s = s.replace(/fypage|\{catePg\}/g, String(pg));
    return s;
}

function _rows(html, specStr) {
    var p = _split(specStr);
    if (!p.length) return [];
    var parent = (!p[0] || p[0] === '*') ? 'body' : _css(p[0]);
    var blocks = [];
    try { blocks = pdfa(html, parent) || []; } catch (e) { blocks = []; }
    var out = [];
    for (var i = 0; i < blocks.length; i++) {
        var b = blocks[i];
        var name = p[1] ? _txt(b, p[1]) : '';
        var link = p[2] ? _txt(b, p[2]) : '';
        var pic = p[3] ? _txt(b, p[3]) : '';
        var note = p[4] ? _txt(b, p[4]) : '';
        if (!link) link = _attr(b, 'href');
        if (!name && !link) continue;
        if (!link && !pic) continue;
        out.push({ name: name, link: _abs(link), pic: _abs(pic), note: note });
    }
    return out;
}

function categoryContent(tid, pg, quick, filter) {
    var r = _rules();
    var tpl = _s(_pick(r, ['分类url', 'url', '分类链接', 'cateUrl', 'cate_url', '列表url']));
    var url = '';
    if (/^https?:\/\//i.test(tid)) url = tid;
    // 规则的 url 模板几乎都是相对路径（/vodshow/fyclass...），必须补 host
    else if (tpl) url = _abs(_fillCate(tpl, tid, pg));
    else url = _abs(_fillCate(tid, tid, pg));

    var html = _get(url);
    if (!html) return { list: [], pagecount: pg };

    var spec = _pick(r, ['一级', '列表', 'list', '一级规则', 'cate_rule', '列表规则']);
    var rows = _rows(html, spec);
    var list = [];
    for (var i = 0; i < rows.length; i++) {
        if (!rows[i].name && !rows[i].link) continue;
        list.push({
            vod_id: rows[i].link || (url + '#' + i),
            vod_name: rows[i].name || ('未命名 ' + (i + 1)),
            vod_pic: rows[i].pic || '',
            vod_remarks: rows[i].note || ''
        });
    }

    // 模板里没有页码占位符时，翻页拿到的还是同一页，直接告诉上层只有一页
    var hasPg = /fypage|\{catePg\}/.test(tpl);
    var pagecount = hasPg ? (pg + 1) : 1;
    if (!list.length) pagecount = pg;
    return { list: list, pagecount: pagecount };
}

/* ---------------- 详情 ---------------- */

function _meta(html, prop) {
    var re1 = new RegExp('<meta[^>]+(?:property|name)\\s*=\\s*["\']' + prop + '["\'][^>]*content\\s*=\\s*["\']([^"\']*)["\']', 'i');
    var m = re1.exec(html);
    if (m) return _unesc(m[1]).trim();
    var re2 = new RegExp('<meta[^>]+content\\s*=\\s*["\']([^"\']*)["\'][^>]*(?:property|name)\\s*=\\s*["\']' + prop + '["\']', 'i');
    m = re2.exec(html);
    return m ? _unesc(m[1]).trim() : '';
}

/* 规则里写了线路就按规则取 */
function _ruleLines(html, sp) {
    if (sp.length < 5 || !sp[4]) return [];
    var containers = [];
    try { containers = pdfa(html, _css(sp[4])) || []; } catch (e) { containers = []; }
    var out = [];
    for (var i = 0; i < containers.length; i++) {
        var c = containers[i];
        var names = _collect(c, sp[5] || 'a&&Text');
        var links = _collect(c, sp[6] || 'a&&href');
        if (!links.length) continue;
        var eps = [];
        for (var j = 0; j < links.length; j++) {
            var u = _abs(links[j]);
            if (!u) continue;
            var n = names[j] || ('第' + (j + 1) + '集');
            eps.push(n + '$' + u);
        }
        if (eps.length) out.push({ name: '线路' + (out.length + 1), urls: eps.join('#') });
    }
    return out;
}

/* 规则没写线路：按常见播放列表容器猜 */
function _autoLines(html, titleHint) {
    var sels = [
        '.stui-content__playlist a',
        '[class*=playlist] a',
        '[class*=play-list] a',
        '.module-play-list a',
        '.play_list a',
        '.playlist a',
        '.video-play a',
        'ul.play a'
    ];
    for (var i = 0; i < sels.length; i++) {
        var els = [];
        try { els = pdfa(html, sels[i]) || []; } catch (e) { els = []; }
        if (!els.length) continue;
        var eps = [];
        for (var j = 0; j < els.length; j++) {
            var href = _attr(els[j], 'href');
            if (!href) continue;
            var u = _abs(href);
            if (!u) continue;
            var n = _plain(els[j]) || ('第' + (j + 1) + '集');
            eps.push(n + '$' + u);
        }
        if (eps.length >= 2) return [{ name: titleHint || '正片', urls: eps.join('#') }];
    }

    // 最后一招：整页所有像播放地址的链接
    var all = [];
    try { all = pdfa(html, 'a') || []; } catch (e) { all = []; }
    var picked = [];
    var seen = {};
    for (var k = 0; k < all.length; k++) {
        var h = _attr(all[k], 'href');
        if (!h || !/play|vodplay|\.m3u8|player/i.test(h)) continue;
        if (seen[h]) continue;
        seen[h] = 1;
        var t = _plain(all[k]) || ('第' + (picked.length + 1) + '集');
        picked.push(t + '$' + _abs(h));
    }
    if (picked.length >= 2) return [{ name: titleHint || '正片', urls: picked.join('#') }];
    return [];
}

function detailContent(ids) {
    var id = '';
    if (ids && ids.length) id = _s(ids[0]);
    if (!id) return { list: [] };
    // 有些 spider 传 "url$$$名称"
    if (id.indexOf('$$$') > 0) id = id.split('$$$')[0];

    var r = _rules();
    var tpl = _s(_pick(r, ['二级url', 'detailUrl', '详情url', 'detail_url']));
    var url = /^https?:\/\//i.test(id) ? id : _abs(tpl ? _fillCate(tpl, id, 1) : id);
    var html = _get(url);
    if (!html) return { list: [] };

    var sp = _split(_pick(r, ['二级', '详情', 'detail', '二级规则', 'detail_rule']));
    var name = sp[1] ? _txt(html, sp[1]) : '';
    if (!name) name = _meta(html, 'og:title') || _meta(html, 'title');
    if (!name && sp[2]) name = _txt(html, 'h1');
    var pic = sp[2] ? _txt(html, sp[2]) : '';
    if (!pic) pic = _meta(html, 'og:image');
    var desc = sp[3] ? _txt(html, sp[3]) : '';
    if (!desc) desc = _meta(html, 'description');

    var lines = _ruleLines(html, sp);
    if (!lines.length) lines = _autoLines(html, '正片');

    var from = [];
    var urls = [];
    for (var i = 0; i < lines.length; i++) {
        from.push(lines[i].name);
        urls.push(lines[i].urls);
    }

    return {
        list: [{
            vod_id: id,
            vod_name: name || id,
            vod_pic: _abs(pic),
            vod_content: desc,
            vod_play_from: from.join('$$$'),
            vod_play_url: urls.join('$$$')
        }]
    };
}

/* ---------------- 搜索 ---------------- */

function searchContent(wd, quick, pg) {
    var r = _rules();
    var tpl = _s(_pick(r, ['搜索url', 'searchUrl', '搜索链接', 'search_url', '搜索URL']));
    if (!tpl) return { list: [] };
    var page = pg || 1;
    var url = String(tpl)
        .replace(/\*\*|fyword|\{wd\}|搜索词/g, encodeURIComponent(wd))
        .replace(/fypage|\{catePg\}/g, String(page));
    var html = _get(_abs(url));
    if (!html) return { list: [] };

    var spec = _pick(r, ['搜索', '搜索规则', 'search', 'search_rule']);
    if (!spec) spec = _pick(r, ['一级', '列表', 'list']);
    var rows = _rows(html, spec);
    var list = [];
    for (var i = 0; i < rows.length; i++) {
        if (!rows[i].name && !rows[i].link) continue;
        list.push({
            vod_id: rows[i].link || ('search-' + i),
            vod_name: rows[i].name || ('结果 ' + (i + 1)),
            vod_pic: rows[i].pic || '',
            vod_remarks: rows[i].note || ''
        });
    }
    return { list: list };
}

/* ---------------- 老接口 ---------------- */

function home(filter) { return homeContent(filter); }

function category(tid, pg) {
    var res = categoryContent(tid, pg, false, {});
    return res;
}

function detail(id) {
    return detailContent([id]);
}

function search(wd, quick, pg) {
    return searchContent(wd, quick, pg);
}

/* ---------------- 导出 ---------------- */
/* 原版 drpy.min.js 若已提供同名函数，以它为准；这里只补缺口 */

function _export(name, fn) {
    if (typeof __G[name] !== 'function') __G[name] = fn;
}

_export('homeContent', homeContent);
_export('categoryContent', categoryContent);
_export('detailContent', detailContent);
_export('searchContent', searchContent);
if (typeof __G.init !== 'function') { __G.init = init; }
if (typeof __G.getHtml !== 'function') { __G.getHtml = _get; }
if (typeof __G.rule === 'undefined') { __G.rule = _rules(); }

/*
 * js 规则文件里常直接引用 MOBILE_UA / PC_UA 这些常量（原版由 drpy 库里定义）。
 * 函数体是在调用时才解析标识符的，所以库没下到时在这里补默认值仍然生效。
 */
if (typeof __G.MOBILE_UA === 'undefined') {
    __G.MOBILE_UA = 'Mozilla/5.0 (Linux; Android 12; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
}
if (typeof __G.PC_UA === 'undefined') {
    __G.PC_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
}
if (typeof __G.UA === 'undefined') { __G.UA = __G.MOBILE_UA; }

})(this);
