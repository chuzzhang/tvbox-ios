// js 规则型 drpy 站点（ext 是 xxx.js）的验证：
// 规则文件只有 `var rule = {...}`，四个入口函数全由解释器按英文字段生成。
// 用 vm 造一个干净全局，模拟 JSSpider 里「rule.js → lite.js」的执行顺序。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
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
<div class="v-item"><a href="/detail/1.html">电影A</a><img data-original="/img/1.jpg"><span class="note">HD</span></div>
<div class="v-item"><a href="/detail/2.html">剧集B</a><img data-original="/img/2.jpg"><span class="note">全12集</span></div>
</body></html>`;

const detailHTML = `
<html><body>
<div class="detail"><h1>电影A</h1><div class="pic"><img src="/img/1.jpg"></div><div class="desc">简介文本</div></div>
<ul class="stui-content__playlist">
  <li><a href="/play/1-1-1.html">第1集</a></li>
  <li><a href="/play/1-1-2.html">第2集</a></li>
</ul>
</body></html>`;

const hits = [];
function request(url) {
  hits.push(url);
  if (url === 'https://demo.com/vodshow/1--------1---.html') return listHTML;
  if (url === 'https://demo.com/search?wd=%E7%94%B5%E5%BD%B1&page=1') return listHTML;
  if (url === 'https://demo.com/detail/1.html') return detailHTML;
  return '';
}

/* js 规则：英文字段 + body&& 前缀 + 搜索模板 */
const ruleCode = `
var rule = {
    title: '低端影视',
    host: 'https://demo.com',
    url: '/vodshow/fyclass--------fypage---.html',
    searchUrl: '/search?wd=**&page=fypage',
    class_name: ['电影', '剧集'],
    class_url: ['1', '2'],
    一级: 'body&&.v-item;a&&Text;a&&href;img&&data-original;.note&&Text',
    二级: '.detail;h1&&Text;.pic&&img&&src;.desc&&Text'
};
`;

const sandbox = { pdfh, pdfa, request, joinUrl: (b, h) => h, console, encodeURIComponent, parseInt };
vm.createContext(sandbox);
vm.runInContext(ruleCode, sandbox, { filename: 'rule.js' });
vm.runInContext(fs.readFileSync(path.join(__dirname, '../Resources/drpy_lite.js'), 'utf8'), sandbox,
  { filename: 'drpy_lite.js' });

let pass = 0, fail = 0;
function check(name, cond, extra) {
  if (cond) { pass++; console.log('  ok   ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra ? ' → ' + JSON.stringify(extra).slice(0, 300) : '')); }
}

console.log('js 规则 · homeContent');
const home = sandbox.homeContent({});
check('读出 2 个分类', home.class.length === 2, home);
check('class_name 作名称', home.class[0] && home.class[0].type_name === '电影', home.class[0]);
check('class_url 作 id', home.class[0] && home.class[0].type_id === '1', home.class[0]);

console.log('js 规则 · categoryContent');
const cat = sandbox.categoryContent('1', 1, false, {});
check('2 条内容', cat.list.length === 2, cat);
check('标题', cat.list[0] && cat.list[0].vod_name === '电影A', cat.list[0]);
check('链接绝对', cat.list[0] && cat.list[0].vod_id === 'https://demo.com/detail/1.html', cat.list[0]);
check('body&& 前缀被剥离', hits.indexOf('https://demo.com/vodshow/1--------1---.html') >= 0, hits);
check('pagecount 可翻页', cat.pagecount === 2, cat.pagecount);

console.log('js 规则 · detailContent');
const det = sandbox.detailContent(['https://demo.com/detail/1.html']).list[0] || {};
check('片名', det.vod_name === '电影A', det.vod_name);
check('封面绝对', det.vod_pic === 'https://demo.com/img/1.jpg', det.vod_pic);
check('2 集', (det.vod_play_url || '').split('#').length === 2, det.vod_play_url);

console.log('js 规则 · searchContent');
const s = sandbox.searchContent('电影', true, 1);
check('搜索命中 2 条', s.list.length === 2, s);
check('搜索词已编码', hits.some(u => u.indexOf('/search?wd=%E7%94%B5%E5%BD%B1') >= 0), hits);

console.log('');
console.log(fail === 0 ? `全部通过（${pass}）` : `失败 ${fail} / 共 ${pass + fail}`);
process.exit(fail === 0 ? 0 : 1);
