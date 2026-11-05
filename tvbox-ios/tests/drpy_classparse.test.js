// class_parse 型 drpy 站点（ddys 那类 WordPress）的验证。
// 语法：父选择器;名称选择器;链接选择器;从链接提 type_id 的正则
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const cheerio = require(path.join(__dirname, '../Resources/cheerio.min.js'));

const TAGS = new Set(['a','div','span','img','li','ul','p','h1','h2','h3','td','tr','body','em','i','b','nav']);

function isAttr(s) {
  if (!s || s.length >= 24 || TAGS.has(s.toLowerCase())) return false;
  if (/[\s.#>\[]/.test(s)) return false;
  return /^[A-Za-z][\w:-]*$/.test(s);
}

function walk($, el, rest) {
  let cur = $(el);
  const segs = rest.slice();
  let mode = 'Text';
  if (segs.length) {
    const last = segs[segs.length - 1];
    if (last === 'Text' || last === 'Html' || last === 'OuterHtml' || isAttr(last)) {
      mode = last;
      segs.pop();
    }
  }
  for (const s of segs) {
    cur = cur.find(s).first();
    if (!cur.length) return '';
  }
  if (mode === 'Text') return cur.text().trim();
  if (mode === 'Html') return cur.html() || '';
  if (mode === 'OuterHtml') return $.html(cur) || '';
  return cur.attr(mode) || '';
}

function pdfh(html, sel) {
  const parts = String(sel).split('&&').map(s => s.trim()).filter(Boolean);
  if (!parts.length) return '';
  const $ = cheerio.load(String(html));
  const el = $(parts[0]).first();
  if (!el.length) return '';
  return walk($, el, parts.slice(1));
}

function pdfa(html, sel) {
  const parts = String(sel).split('&&').map(s => s.trim()).filter(Boolean);
  if (!parts.length) return [];
  const $ = cheerio.load(String(html));
  const els = $(parts[0]).toArray();
  const rest = parts.slice(1);
  if (!rest.length) return els.map(e => $.html($(e)));
  return els.map(e => walk($, e, rest));
}

const homeHTML = `
<html><body>
<nav id="primary-menu"><ul>
  <li class="menu-item"><a href="https://ddys.pro/pro/movie">电影</a></li>
  <li class="menu-item"><a href="https://ddys.pro/pro/series">剧集</a></li>
  <li class="menu-item"><a href="https://ddys.pro/pro/anime">动漫</a></li>
</ul></nav>
<div id="post-list">
  <div class="post-item"><a href="/movie/1">影片A</a><img data-src="/img/a.jpg"><span class="cat">2024</span></div>
  <div class="post-item"><a href="/movie/2">影片B</a><img data-src="/img/b.jpg"><span class="cat">2023</span></div>
</div>
</body></html>`;

const listHTML = `
<html><body>
<div id="post-list">
  <div class="post-item"><a href="/movie/9">列表片1</a><img data-src="/img/9.jpg"><span class="cat">HD</span></div>
  <div class="post-item"><a href="/movie/10">列表片2</a><img data-src="/img/10.jpg"><span class="cat">BD</span></div>
</div>
</body></html>`;

function makeSandbox(ruleCode, pages) {
  const hits = [];
  function request(url) {
    hits.push(url);
    return pages[url] || '';
  }
  const sandbox = { pdfh, pdfa, request, joinUrl: (b, h) => h, console, encodeURIComponent, parseInt, RegExp, String };
  vm.createContext(sandbox);
  vm.runInContext(ruleCode, sandbox, { filename: 'rule.js' });
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../Resources/drpy_lite.js'), 'utf8'), sandbox,
    { filename: 'drpy_lite.js' });
  return { sandbox, hits };
}

let pass = 0, fail = 0;
function check(name, cond, extra) {
  if (cond) { pass++; console.log('  ok   ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra ? ' → ' + JSON.stringify(extra).slice(0, 300) : '')); }
}

/* ---------- 场景 1：class_parse 命中 ---------- */
const rule1 = `
var rule = {
    title: 'ddys',
    host: 'https://ddys.pro',
    url: '/fyclass/page/fypage/',
    searchUrl: '/?s=**&post_type=post',
    class_parse: '#primary-menu li.menu-item;a&&Text;a&&href;.pro/(.*)',
    一级: '#post-list .post-item;a&&Text;a&&href;img&&data-src;.cat&&Text'
};
`;
const s1 = makeSandbox(rule1, {
  'https://ddys.pro': homeHTML,
  'https://ddys.pro/pro/movie/page/1/': listHTML,
  'https://ddys.pro/?s=%E7%94%B5%E5%BD%B1&post_type=post': listHTML
});

console.log('class_parse · homeContent');
const home = s1.sandbox.homeContent({});
check('抓到 3 个分类', home.class.length === 3, home);
check('名称取 a&&Text', home.class[0] && home.class[0].type_name === '电影', home.class[0]);
check('正则把链接裁成 type_id', home.class[0] && home.class[0].type_id === 'pro/movie', home.class[0]);
check('第二项 id', home.class[1] && home.class[1].type_id === 'pro/series', home.class[1]);
check('首页只请求一次（有缓存）',
  s1.hits.filter(u => u === 'https://ddys.pro').length === 1, s1.hits);

console.log('class_parse · categoryContent');
const cat = s1.sandbox.categoryContent('pro/movie', 1, false, {});
check('拼出 /pro/movie/page/1/', s1.hits.indexOf('https://ddys.pro/pro/movie/page/1/') >= 0, s1.hits);
check('2 条列表', cat.list.length === 2, cat);
check('标题/封面/副标题',
  cat.list[0] && cat.list[0].vod_name === '列表片1'
  && cat.list[0].vod_pic === 'https://ddys.pro/img/9.jpg'
  && cat.list[0].vod_remarks === 'HD', cat.list[0]);

console.log('class_parse · 日志');
const log1 = (s1.sandbox.__drpy_log__ || []).join('\n');
check('日志记了分类来源', log1.indexOf('分类来源：class_parse') >= 0, log1);
check('日志记了请求结果', log1.indexOf('GET https://ddys.pro →') >= 0, log1);

/* ---------- 场景 2：class_parse 选择器不匹配，退回导航猜测 ---------- */
const rule2 = `
var rule = {
    title: 'demo',
    host: 'https://demo.com',
    url: '/vodshow/fyclass--------fypage---.html',
    class_parse: '#no-such-menu li;a&&Text;a&&href'
};
`;
const navHTML = `
<html><body>
<div class="nav"><a href="/vodtype/1.html">电影</a><a href="/vodtype/2.html">剧集</a></div>
</body></html>`;
const s2 = makeSandbox(rule2, { 'https://demo.com': navHTML });

console.log('class_parse 未命中 · 退回导航');
const home2 = s2.sandbox.homeContent({});
check('退回导航抓到 2 个', home2.class.length === 2, home2);
check('导航 id 转绝对', home2.class[0] && home2.class[0].type_id === 'https://demo.com/vodtype/1.html', home2.class[0]);
const log2 = (s2.sandbox.__drpy_log__ || []).join('\n');
check('日志写明没抓到', log2.indexOf('class_parse 没抓到') >= 0, log2);

console.log('');
console.log(fail === 0 ? `全部通过（${pass}）` : `失败 ${fail} / 共 ${pass + fail}`);
process.exit(fail === 0 ? 0 : 1);
