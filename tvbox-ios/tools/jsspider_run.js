#!/usr/bin/env node
// 在 node 里跑一个 js spider，用来看它到底在哪一行出错、返回什么。
//
// iOS 上跑的是 JSCore + SwiftSoup，本地没有那两个，这里用 node + cheerio 顶替：
//   __reqSync  → spawnSync 调 curl（同步阻塞，跟原生信号量等待语义一致）
//   __sel/__text/__innerHtml/__attr → cheerio 实现（原生是 SwiftSoup）
//   compat.js  → 原样加载，保证测的是包里那份兼容层
//
// 用法：
//   node tools/jsspider_run.js <本地脚本.js 或 URL> [--home] [--category TID] [--detail ID] [--search 关键词]
//   不带参数时依次跑 home → 第一个分类的 category
//
// 它能回答两个问题：脚本文本剥完 ESM 还报不报语法错；某个入口的实际返回值长什么样。
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

// compat.js 会把 globalThis.console 换掉（转发到 __log），
// 之后必须用这个函数打日志，否则工具的输出去进了 logs 数组。
function say() {
  process.stdout.write(Array.prototype.slice.call(arguments).join(' ') + '\n');
}

let cheerio;
try {
  cheerio = require(path.join(__dirname, '../Resources/cheerio.min.js'));
} catch (e) {
  say('cheerio 加载失败：' + e.message);
  process.exit(2);
}

/* ---------- 与 JSSpider.stripESM 完全一致的规则 ---------- */
function stripESM(src) {
  if (src.indexOf('import ') < 0 && src.indexOf('export ') < 0) return src;
  return src
    .replace(/^[ \t]*import[ \t]+[^;\n]*;?[ \t]*$/gm, '')
    .replace(/^[ \t]*export[ \t]+default[ \t]+/gm, 'var __default_export__ = ')
    .replace(/^[ \t]*export[ \t]+(?=(const|let|var|function|class|async))/gm, '')
    .replace(/^[ \t]*export[ \t]*\{[^}]*\}[ \t]*;?[ \t]*$/gm, '');
}

/* ---------- 原生桩 ---------- */
const logs = [];
globalThis.__log = (line) => { logs.push(line); };
globalThis.__reqSync = function (url, headersJSON, method, body, b64) {
  const headers = {};
  try { Object.assign(headers, JSON.parse(headersJSON || '{}')); } catch (e) { /* 忽略 */ }
  const args = ['-sL', '-m', '25', '-A', 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)'];
  for (const k of Object.keys(headers)) args.push('-H', k + ': ' + headers[k]);
  if ((method || 'GET').toUpperCase() !== 'GET') args.push('-X', method);
  if (body) args.push('--data-binary', body);
  if (b64) args.push('--output', '-');
  args.push(url);
  try {
    const out = execFileSync('curl', args, { maxBuffer: 32 * 1024 * 1024 });
    if (process.env.SEL_DEBUG) say('  [req] ' + String(url).slice(0, 60) + ' → ' + out.length + ' 字节');
    return b64 ? out.toString('base64') : out.toString('utf8');
  } catch (e) {
    return '';
  }
};
globalThis.__sel = function (html, sel) {
  try {
    const $ = cheerio.load(html);
    const out = [];
    $(sel).each((i, el) => { out.push($.html(el)); });
    if (process.env.SEL_DEBUG) say('  [sel] ' + sel + ' → ' + out.length + '  (html ' + String(html).length + ')');
    return JSON.stringify(out);
  } catch (e) { return '[]'; }
};
// 原生侧是 parseBodyFragment(...).body().children().first()，这里必须等价：
// cheerio.load('<a href="/x">t</a>') 的 root 第一个子节点是 <html>，
// 直接取 root.children().first() 会拿到 html 而不是那个 <a>，attr 永远是空。
function fragmentRoot(html) {
  const $ = cheerio.load(html);
  const body = $.root().find('body');
  const first = body.children().first();
  return { $, el: first.length ? first : $.root().children().first() };
}
globalThis.__text = function (html) {
  try { const f = fragmentRoot(html); return f.el.length ? f.el.text() : ''; } catch (e) { return ''; }
};
globalThis.__innerHtml = function (html) {
  try { const f = fragmentRoot(html); return f.el.length ? f.el.html() : ''; } catch (e) { return ''; }
};
globalThis.__attr = function (html, name) {
  try { const f = fragmentRoot(html); return f.el.length ? (f.el.attr(name) || '') : ''; } catch (e) { return ''; }
};

// 原生侧是 CommonCrypto，这里用 node crypto 等价实现（NoPadding 解 + 手动去 PKCS7）
const crypto = require('crypto');
globalThis.__aesDec = function (b64, key, iv, mode) {
  try {
    const data = Buffer.from(String(b64 || ''), 'base64');
    if (!data.length) return '';
    const k = Buffer.from(String(key || ''), 'utf8');
    let ivb = Buffer.from(String(iv || ''), 'utf8');
    if (!ivb.length) ivb = Buffer.alloc(16);
    if (![16, 24, 32].includes(k.length) || ivb.length !== 16) return '';
    if (data.length % 16 !== 0) return '';
    const dc = crypto.createDecipheriv('aes-' + (k.length * 8) + '-cbc', k, ivb);
    dc.setAutoPadding(false);
    let out = Buffer.concat([dc.update(data), dc.final()]);
    const n = out[out.length - 1];
    if (n > 0 && n <= 16 && out.length >= n && out.slice(-n).every(b => b === n)) out = out.slice(0, -n);
    return out.toString('base64');
  } catch (e) { return ''; }
};

/* ---------- 兼容层 ---------- */
const compat = fs.readFileSync(path.join(__dirname, '../Resources/compat.js'), 'utf8');
eval(compat);

/* ---------- 脚本 ---------- */
const args = process.argv.slice(2);
const target = args[0];
if (!target) {
  say('用法：node tools/jsspider_run.js <脚本.js|URL> [--home] [--category TID] [--detail ID] [--search 词]');
  process.exit(2);
}

let src;
if (/^https?:\/\//.test(target)) {
  src = globalThis.__reqSync(target, '{}', 'GET', '', 0);
  if (!src) { say('脚本下载失败：' + target); process.exit(2); }
} else {
  src = fs.readFileSync(target, 'utf8');
}

const code = stripESM(src);
say('脚本 ' + src.length + ' 字节，剥 ESM 后 ' + code.length + ' 字节');
try {
  (0, eval)(code);
} catch (e) {
  say('语法/执行错误：' + (e && e.stack ? e.stack.split('\n').slice(0, 4).join('\n') : e));
  say('日志：\n  ' + logs.join('\n  '));
  process.exit(1);
}

const g = globalThis;
const entries = ['init', 'home', 'homeContent', 'category', 'categoryContent',
  'detail', 'detailContent', 'search', 'searchContent', 'play'].filter(k => typeof g[k] === 'function');
say('入口：' + entries.join(', ') + (typeof g.__default_export__ !== 'undefined' ? '  (有 default 导出)' : ''));

function opt(name, def) {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : def;
}

// 这类脚本常 `return JSON.stringify({...})`，直接把字符串当对象用会全是 0
function asObj(v) {
  if (typeof v !== 'string') return v;
  try { return JSON.parse(v); } catch (e) { return v; }
}

(async () => {
  const pick = (name, alt) => (typeof g[name] === 'function' ? g[name] : (typeof g[alt] === 'function' ? g[alt] : null));
  const homeFn = pick('homeContent', 'home');
  const catFn = pick('categoryContent', 'category');
  const detFn = pick('detailContent', 'detail');
  const seaFn = pick('searchContent', 'search');

  let firstTid = null;
  try {
    if (homeFn) {
      const r = asObj(await homeFn(homeFn === g.homeContent ? {} : {}));
      const cls = (r && r.class) || [];
      // 原生侧会把 filters 的默认值当 extend 传给 category；
      // 不传的话这类脚本拼出 `/theme/64//1/`（空 sort），站点直接 404。
      globalThis.__homeFilters = (r && r.filters) || {};
      firstTid = cls[0] && cls[0].type_id;
      say('\n== home ==');
      say('分类 ' + cls.length + ' 个：' + cls.slice(0, 6).map(c => c.type_id + '=' + c.type_name).join(' | '));
      say('首页条目 ' + ((r && r.list) || []).length + ' 条');
    }
  } catch (e) {
    say('\n== home 抛错 ==\n' + (e && e.stack ? e.stack.split('\n').slice(0, 6).join('\n') : e));
  }

  const wantCat = opt('--category', null) || firstTid;
  if (catFn && wantCat && (args.indexOf('--home') < 0)) {
    try {
      const groups = (globalThis.__homeFilters || {})[wantCat] || [];
      const extend = {};
      for (const gp of (Array.isArray(groups) ? groups : [])) {
        if (gp && gp.key && Array.isArray(gp.value) && gp.value[0]) extend[gp.key] = gp.value[0].v;
      }
      if (Object.keys(extend).length) say('extend 默认值：' + JSON.stringify(extend));
      // 两种签名：categoryContent(tid, page, filter, extend) / category(tid, pg, filter, extend)
      // 第 4 个才是 extend，别把 filter 和 extend 传反
      const r = asObj(catFn === g.categoryContent
        ? await catFn(wantCat, 1, false, extend)
        : await catFn(wantCat, 1, {}, extend));
      const list = (r && r.list) || [];
      say('\n== category(' + wantCat + ') ==');
      say('条目 ' + list.length + '，页数 ' + (r && r.pagecount));
      if (list[0]) {
        const it = list[0];
        const pic = String(it.vod_pic || '');
        say('首条：' + JSON.stringify({ vod_id: it.vod_id, vod_name: it.vod_name }).slice(0, 160));
        say('封面：' + (pic ? (pic.slice(0, 40) + '…  共 ' + pic.length + ' 字符') : '（空）'));
      }
      globalThis.__firstVid = list[0] && list[0].vod_id;
    } catch (e) {
      say('\n== category 抛错 ==\n' + (e && e.stack ? e.stack.split('\n').slice(0, 6).join('\n') : e));
    }
  }

  const wantDet = opt('--detail', null) || globalThis.__firstVid;
  if (detFn && wantDet) {
    try {
      const r = asObj(detFn === g.detailContent ? await detFn([wantDet]) : await detFn(wantDet));
      const list = (r && r.list) || [];
      say('\n== detail(' + wantDet + ') ==');
      if (list[0]) {
        const d = list[0];
        say('name: ' + d.vod_name);
        say('from: ' + d.vod_play_from);
        say('play_url: ' + String(d.vod_play_url || '').slice(0, 200));
      } else {
        say('空结果');
      }
    } catch (e) {
      say('\n== detail 抛错 ==\n' + (e && e.stack ? e.stack.split('\n').slice(0, 6).join('\n') : e));
    }
  }

  const kw = opt('--search', null);
  if (seaFn && kw) {
    try {
      const r = asObj(seaFn === g.searchContent ? await seaFn(kw, true, 1) : await seaFn(kw, true, 1));
      say('\n== search(' + kw + ') ==  条目 ' + ((r && r.list) || []).length);
    } catch (e) {
      say('\n== search 抛错 ==\n' + (e && e.stack ? e.stack.split('\n').slice(0, 6).join('\n') : e));
    }
  }

  if (logs.length) {
    say('\n== 脚本日志（' + logs.length + ' 条，末 10）==');
    say('  ' + logs.slice(-10).join('\n  '));
  }
})();
