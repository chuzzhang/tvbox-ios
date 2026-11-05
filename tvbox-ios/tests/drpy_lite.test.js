// drpy_lite.js 的本地验证：用 cheerio 模拟 iOS 端的 pdfh / pdfa / request
const fs = require('fs');
const path = require('path');
const cheerio = require(path.join(__dirname, '../Resources/cheerio.min.js'));

/* ---- 模拟原生桥（语义与 JSSpider.queryH / queryA 对齐） ---- */
const TAGS = new Set(['a','div','span','img','li','ul','p','h1','h2','h3','td','tr','body','em','i','b']);

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

/* ---- 假站点 ---- */
const listHTML = `
<html><body>
<div class="nav"><a href="/vodtype/1.html">电影</a><a href="/vodtype/2.html">剧集</a></div>
<div class="v-item"><a href="/detail/1.html" title="电影A">电影A</a><img data-original="/img/1.jpg"><span class="note">HD</span></div>
<div class="v-item"><a href="/detail/2.html" title="电影B">电影B</a><img data-original="/img/2.jpg"><span class="note">更新至10集</span></div>
</body></html>`;

const detailHTML = `
<html><body>
<div class="detail"><h1>电影A</h1><div class="pic"><img src="/img/1.jpg"></div><div class="desc">这是一部测试影片</div></div>
<ul class="stui-content__playlist">
  <li><a href="/play/1-1-1.html">第1集</a></li>
  <li><a href="/play/1-1-2.html">第2集</a></li>
</ul>
</body></html>`;

const pages = {
  'https://demo.com/vodshow/1/page/1.html': listHTML,
  'https://demo.com/search?wd=%E7%94%B5%E5%BD%B1&page=1': listHTML,
  'https://demo.com/detail/1.html': detailHTML
};

function request(url) {
  if (pages[url]) return pages[url];
  return '<html><body>404</body></html>';
}

/* ---- 装进全局，跑 lite ---- */
global.pdfh = pdfh;
global.pdfa = pdfa;
global.request = request;
global.joinUrl = (b, h) => h;
global.__drpy_rule__ = {
  '首页': 'https://demo.com',
  '分类': '电影&1#剧集&2',
  '分类url': 'https://demo.com/vodshow/fyclass/page/fypage.html',
  '一级': '.v-item;a&&Text;a&&href;img&&data-original;.note&&Text',
  '二级': '.detail;h1&&Text;.pic&&img&&src;.desc&&Text',
  '搜索url': 'https://demo.com/search?wd=**&page=fypage',
  '搜索': '.v-item;a&&Text;a&&href;img&&data-original'
};
global.__drpy_host__ = 'https://demo.com';

const code = fs.readFileSync(path.join(__dirname, '../Resources/drpy_lite.js'), 'utf8');
new Function(code).call(global);

/* ---- 断言 ---- */
let pass = 0, fail = 0;
function check(name, cond, extra) {
  if (cond) { pass++; console.log('  ok   ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra ? ' → ' + JSON.stringify(extra).slice(0, 300) : '')); }
}

console.log('homeContent');
const home = global.homeContent({});
check('2 个分类', home.class.length === 2, home);
check('分类名对', home.class[0].type_name === '电影' && home.class[0].type_id === '1', home.class[0]);

console.log('categoryContent');
const cat = global.categoryContent('1', 1, false, {});
check('2 条内容', cat.list.length === 2, cat);
check('标题正确', cat.list[0].vod_name === '电影A', cat.list[0]);
check('链接转绝对', cat.list[0].vod_id === 'https://demo.com/detail/1.html', cat.list[0].vod_id);
check('图片转绝对', cat.list[0].vod_pic === 'https://demo.com/img/1.jpg', cat.list[0].vod_pic);
check('副标题', cat.list[0].vod_remarks === 'HD', cat.list[0].vod_remarks);
check('pagecount 递增', cat.pagecount === 2, cat.pagecount);

console.log('detailContent');
const det = global.detailContent(['https://demo.com/detail/1.html']);
const d0 = det.list[0] || {};
check('有详情', det.list.length === 1, det);
check('片名', d0.vod_name === '电影A', d0.vod_name);
check('封面', d0.vod_pic === 'https://demo.com/img/1.jpg', d0.vod_pic);
check('简介', d0.vod_content === '这是一部测试影片', d0.vod_content);
check('线路名', d0.vod_play_from === '正片', d0.vod_play_from);
check('2 集', (d0.vod_play_url || '').split('#').length === 2, d0.vod_play_url);
check('集地址绝对', (d0.vod_play_url || '').indexOf('https://demo.com/play/1-1-1.html') > 0, d0.vod_play_url);

console.log('searchContent');
const s = global.searchContent('电影', true, 1);
check('2 条搜索结果', s.list.length === 2, s);

/* 规则里显式写了线路 spec 的情况 */
console.log('detailContent（规则线路）');
global.__drpy_rule__['二级'] = '.detail;h1&&Text;.pic&&img&&src;.desc&&Text;.playlist;li&&Text;a&&href';
pages['https://demo.com/detail/2.html'] = `
<html><body>
<div class="detail"><h1>电影B</h1><div class="pic"><img src="/img/2.jpg"></div><div class="desc">第二部</div></div>
<div class="playlist"><li><a href="/p/2-1">第1集</a></li><li><a href="/p/2-2">第2集</a></li><li><a href="/p/2-3">第3集</a></li></div>
</body></html>`;
const det2 = global.detailContent(['https://demo.com/detail/2.html']).list[0] || {};
check('规则线路 3 集', (det2.vod_play_url || '').split('#').length === 3, det2.vod_play_url);
check('规则线路名取自 li', (det2.vod_play_url || '').indexOf('第2集$') === 0 || (det2.vod_play_url || '').indexOf('第2集$') > 0, det2.vod_play_url);

console.log('');
console.log(fail === 0 ? `全部通过（${pass}）` : `失败 ${fail} / 共 ${pass + fail}`);
process.exit(fail === 0 ? 0 : 1);
