// Pyramid（python 版 TVBox）规则字段验证。
// HTML 和 drpy 那套一样，区别只在字段名：first / second / url / searchUrl / class_name / class_url。
const fs = require('fs');
const path = require('path');
const cheerio = require(path.join(__dirname, '../Resources/cheerio.min.js'));

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

const listHTML = `
<html><body>
<div class="module-item"><a class="title" href="/detail/101.html">Py 电影A</a><img data-src="/pic/101.jpg"><span class="note">HD中字</span></div>
<div class="module-item"><a class="title" href="/detail/102.html">Py 电影B</a><img data-src="/pic/102.jpg"><span class="note">更新至08集</span></div>
</body></html>`;

const detailHTML = `
<html><body>
<div class="video-info"><h1 class="video-title">Py 电影A</h1><img class="video-cover" src="/pic/101.jpg"><div class="video-desc">简介文字</div></div>
<div class="play-list"><a href="/play/101-1-1.html">第01集</a><a href="/play/101-1-2.html">第02集</a></div>
</body></html>`;

const hits = [];
const pages = {
  'https://demo.com': listHTML,
  'https://demo.com/vodshow/1/page/1.html': listHTML,
  'https://demo.com/vodshow/2/page/3.html': listHTML,
  'https://demo.com/detail/101.html': detailHTML,
  'https://demo.com/search?wd=%E7%94%B5%E5%BD%B1&page=1': listHTML
};

function request(url) {
  hits.push(url);
  return pages[url] || '<html><body>404</body></html>';
}

global.pdfh = pdfh;
global.pdfa = pdfa;
global.request = request;
global.joinUrl = (b, h) => h;

// Pyramid 规则的典型写法：全英文键，url 是列表模板，first 是列表规则，second 是详情规则
global.__drpy_rule__ = {
  title: 'demo-pyramid',
  host: 'https://demo.com',
  url: '/vodshow/fyclass/page/fypage.html',
  searchUrl: '/search?wd=**&page=fypage',
  searchable: 1,
  quickSearch: 1,
  class_name: '电影&剧集',
  class_url: '1#2',
  first: '.module-item;a.title&&Text;a.title&&href;img&&data-src;.note&&Text',
  second: '.video-info;h1&&Text;img&&src;.video-desc&&Text;.play-list|a&&Text|a&&href'
};
global.__drpy_host__ = 'https://demo.com';

const code = fs.readFileSync(path.join(__dirname, '../Resources/drpy_lite.js'), 'utf8');
new Function(code).call(global);

let pass = 0, fail = 0;
function check(name, cond, extra) {
  if (cond) { pass++; console.log('  ok   ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra ? ' → ' + JSON.stringify(extra).slice(0, 300) : '')); }
}

console.log('homeContent（class_name / class_url）');
const home = global.homeContent({});
check('解析出 2 个分类', home.class.length === 2, home);
check('type_name 正确', home.class[0].type_name === '电影', home.class[0]);
check('type_id 取自 class_url', home.class[0].type_id === '1' && home.class[1].type_id === '2', home.class);

console.log('categoryContent（url + first）');
const cat = global.categoryContent('1', 1, false, {});
check('2 条内容', cat.list.length === 2, cat);
check('标题', cat.list[0].vod_name === 'Py 电影A', cat.list[0]);
check('链接绝对', cat.list[0].vod_id === 'https://demo.com/detail/101.html', cat.list[0].vod_id);
check('图片绝对', cat.list[0].vod_pic === 'https://demo.com/pic/101.jpg', cat.list[0].vod_pic);
check('副标题', cat.list[0].vod_remarks === 'HD中字', cat.list[0].vod_remarks);
check('pagecount', cat.pagecount === 2, cat.pagecount);
check('按 fypage 拼地址', hits.indexOf('https://demo.com/vodshow/1/page/1.html') >= 0, hits);

console.log('categoryContent 第二页');
hits.length = 0;
global.categoryContent('2', 3, false, {});
check('fypage 代入第 3 页', hits.indexOf('https://demo.com/vodshow/2/page/3.html') >= 0, hits);

console.log('detailContent（second）');
const det = global.detailContent(['https://demo.com/detail/101.html']);
const d0 = det.list[0] || {};
check('有详情', det.list.length === 1, det);
check('片名', d0.vod_name === 'Py 电影A', d0.vod_name);
check('封面绝对', d0.vod_pic === 'https://demo.com/pic/101.jpg', d0.vod_pic);
check('简介', d0.vod_content === '简介文字', d0.vod_content);
check('2 集', (d0.vod_play_url || '').split('#').length === 2, d0.vod_play_url);

console.log('searchContent（searchUrl + first）');
const s = global.searchContent('电影', true, 1);
check('2 条搜索结果', s.list.length === 2, s);
check('搜索词已编码', hits.some(u => u.indexOf('https://demo.com/search?wd=%E7%94%B5%E5%BD%B1') === 0), hits);

console.log(`\n${fail === 0 ? '全部通过' : '失败 ' + fail + ' 项'}（${pass}）`);
process.exit(fail === 0 ? 0 : 1);
