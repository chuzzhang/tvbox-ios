// parse_sniff.js + sniff_rules.json 的本地验证
//
// Swift 侧的 looksMedia / isBlocked / noteOnly / rank 是下面同名函数的镜像，
// 语义改了要两边一起改；规则改动只有这一个来源（sniff_rules.json）。
//
// hook 脚本用 vm 跑在假 DOM 里：真机上 JS 一旦语法错或 hook 装不上，
// 表现是「所有 parses 站点静默失败」，比崩溃难查得多。
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.join(__dirname, '..');
const rules = JSON.parse(fs.readFileSync(path.join(ROOT, 'Resources/sniff_rules.json'), 'utf8'));
const hookSrc = fs.readFileSync(path.join(ROOT, 'Resources/parse_sniff.js'), 'utf8');

let pass = 0;
let fail = 0;
function check(name, ok, extra) {
  if (ok) {
    pass++;
    console.log('  ok   ' + name);
  } else {
    fail++;
    console.log('  FAIL ' + name + (extra === undefined ? '' : '  → ' + JSON.stringify(extra)));
  }
}

/* ---- 镜像实现（对照 Sources/ParseWebView.swift） ---- */
const MEDIA = rules.mediaExtensions.map(s => s.toLowerCase());

function extensionOf(url) {
  let p = String(url).toLowerCase();
  const cut = p.search(/[?#]/);
  if (cut >= 0) p = p.slice(0, cut);
  const dot = p.lastIndexOf('.');
  if (dot < 0) return '';
  const tail = p.slice(dot + 1);
  if (tail.indexOf('/') >= 0) return '';
  return tail;
}

function noteOnly(url) {
  return (rules.noteURLPatterns || []).some(p => new RegExp(p, 'i').test(url));
}

function looksMedia(url) {
  const low = String(url).toLowerCase();
  if (noteOnly(low)) return false;
  const ext = extensionOf(low);
  // 有扩展名就按扩展名判（对照 Swift：不能靠 contains('m3u8') 放行 a.m3u8.jpg）
  if (ext) return MEDIA.indexOf(ext) >= 0;
  if (low.indexOf('/hls/') >= 0) return true;
  const q = low.split('?')[0] === low ? '' : low.slice(low.indexOf('?') + 1);
  if (q.indexOf('m3u8') >= 0) return true;
  return false;
}

function isBlocked(url) {
  const low = String(url).toLowerCase();
  if ((rules.blockHostKeywords || []).some(k => k && low.indexOf(k) >= 0)) return true;
  return (rules.blockURLPatterns || []).some(p => new RegExp(p, 'i').test(low));
}

function rank(url) {
  const b = rules.rankBoost || {};
  return b[extensionOf(url)] !== undefined ? b[extensionOf(url)] : 5;
}

/* ---- 规则文件 ---- */
console.log('sniff_rules.json');
check('媒体扩展名非空且全小写', MEDIA.length > 0 && MEDIA.every(e => e === e.toLowerCase()), MEDIA);
check('拦广告关键词非空', (rules.blockHostKeywords || []).length > 0);
check('所有 blockURLPatterns 能编译', (rules.blockURLPatterns || []).every(p => { try { new RegExp(p); return true; } catch (e) { return false; } }));
check('所有 noteURLPatterns 能编译', (rules.noteURLPatterns || []).every(p => { try { new RegExp(p); return true; } catch (e) { return false; } }));
check('webview 预算 ≥ 1', rules.maxWebViewAttempts >= 1, rules.maxWebViewAttempts);
check('超时在 3~30 秒之间', rules.timeout >= 3 && rules.timeout <= 30, rules.timeout);

/* ---- 扩展名 ---- */
console.log('extensionOf');
check('域名里的点不算扩展名', extensionOf('https://a.com/x') === '', extensionOf('https://a.com/x'));
check('带 query 也能取到', extensionOf('https://a.com/v/1.M3U8?token=1') === 'm3u8', extensionOf('https://a.com/v/1.M3U8?token=1'));
check('带 fragment 也能取到', extensionOf('https://a.com/v/1.mp4#t=10') === 'mp4');
check('路径分段里的点不算扩展名', extensionOf('https://a.com/v1.2/index') === '', extensionOf('https://a.com/v1.2/index'));

/* ---- 媒体判定 ---- */
console.log('looksMedia');
check('m3u8', looksMedia('https://c.com/v/1.m3u8'));
check('m3u8 带鉴权参数', looksMedia('https://c.com/v/1.m3u8?auth=1&t=2'));
check('mp4', looksMedia('https://c.com/v/1.mp4'));
check('无扩展名 HLS 路径', looksMedia('https://c.com/hls/index'));
check('query 里写格式', looksMedia('https://c.com/live/play?format=m3u8'));
check('css 不算', !looksMedia('https://c.com/style.css'));
check('首页不算', !looksMedia('https://c.com/'));
check('blob 只记录不返回', !looksMedia('blob:https://c.com/9f8e'));
check('挂羊头的假视频不算', !looksMedia('https://c.com/a.m3u8.jpg'));

/* ---- 拦截 ---- */
console.log('isBlocked');
check('统计域名', isBlocked('https://hm.baidu.com/hm.js?x=1'));
check('广告路径', isBlocked('https://c.com/ads/pre.m3u8'));
check('图片', isBlocked('https://c.com/img/1.jpg'));
check('正常 m3u8 不拦', !isBlocked('https://c.com/v/1.m3u8'));
check('正常 mp4 带参数不拦', !isBlocked('https://c.com/v/1.mp4?sign=abc'));

/* ---- 排序 ---- */
console.log('rank');
check('m3u8 高于 mp4', rank('https://c.com/1.m3u8') > rank('https://c.com/1.mp4'));
check('mp4 高于 ts', rank('https://c.com/1.mp4') > rank('https://c.com/1.ts'));
check('未知扩展名给底分 5', rank('https://c.com/x') === 5, rank('https://c.com/x'));

/* ---- hook 脚本：语法 + 功能 ---- */
console.log('parse_sniff.js');
let syntaxOk = true;
try {
  new vm.Script(hookSrc, { filename: 'parse_sniff.js' });
} catch (e) {
  syntaxOk = false;
  console.log('    语法错误：' + e.message);
}
check('语法可通过', syntaxOk);

['__tbSniffPost', '__tbSniffDump', 'XMLHttpRequest.prototype.open', 'window.fetch',
 'HTMLMediaElement', 'HTMLSourceElement', 'MutationObserver', 'messageHandlers.tbSniff']
  .forEach(k => check('包含 hook 点：' + k, hookSrc.indexOf(k) >= 0));

// 假 DOM：只实现 hook 会碰到的部分
function FakeXHR() { this._h = {}; }
FakeXHR.prototype.open = function () {};
FakeXHR.prototype.send = function () {};
FakeXHR.prototype.addEventListener = function (k, f) { this._h[k] = f; };
FakeXHR.prototype.fire = function (k) { if (this._h[k]) this._h[k].call(this, {}); };
FakeXHR.prototype.responseType = '';
FakeXHR.prototype.responseText = '';

const posted = [];
const ctx = {
  window: { webkit: { messageHandlers: { tbSniff: { postMessage: m => posted.push(m) } } } },
  location: { href: 'https://play.example.com/p/1.html' },
  document: {},
  URL: URL,
  JSON: JSON,
  String: String,
  Object: Object,
  RegExp: RegExp,
  Array: Array,
  XMLHttpRequest: FakeXHR,
  HTMLMediaElement: function () {},
  HTMLSourceElement: function () {},
  Element: function () {},
  MutationObserver: function () { this.observe = function () {}; },
};
ctx.window.location = ctx.location;
ctx.window.document = ctx.document;
ctx.window.XMLHttpRequest = FakeXHR;
ctx.window.HTMLMediaElement = ctx.HTMLMediaElement;
ctx.window.HTMLSourceElement = ctx.HTMLSourceElement;
ctx.window.Element = ctx.Element;
ctx.window.MutationObserver = ctx.MutationObserver;
ctx.window.Object = Object;
ctx.window.JSON = JSON;
ctx.window.String = String;
ctx.window.URL = URL;
ctx.window.RegExp = RegExp;
ctx.window.Array = Array;
vm.createContext(ctx);
let ran = true;
try {
  vm.runInContext(hookSrc, ctx);
} catch (e) {
  ran = false;
  console.log('    运行失败：' + e.message);
}
check('IIFE 能装到假 DOM 上', ran);

// 场景 A：地址里没有任何线索，只有响应体能确认
posted.length = 0;
const xa = new FakeXHR();
xa.responseText = '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n';
xa.open('GET', '/live/play', true);
xa.send();
check('无线索时首包不乱报', posted.length === 0, posted);
xa.fire('load');
check('响应体是 m3u8 后上报', posted.length === 1 && posted[0].ok === true, posted);
check('相对地址补成绝对', posted.length === 1 && posted[0].url === 'https://play.example.com/live/play', posted);

// 场景 B：HLS 路径首包就报，响应体确认后再升级一次
posted.length = 0;
const xb = new FakeXHR();
xb.responseText = '#EXTM3U\n';
xb.open('GET', '/hls/index', true);
xb.send();
check('HLS 路径首包即上报（未确认）', posted.length === 1 && posted[0].ok === false, posted);
xb.fire('load');
check('确认后升级为 ok', posted.length === 2 && posted[1].ok === true, posted);
check('升级不重复推送同一状态', posted.length === 2);

// 场景 C：静态资源不该上报
posted.length = 0;
const xc = new FakeXHR();
xc.open('GET', '/static/app.css', true);
xc.send();
xc.fire('load');
check('css 不上报', posted.length === 0, posted);

// 场景 D：有扩展名的媒体首包就报
posted.length = 0;
const xd = new FakeXHR();
xd.open('GET', 'https://cdn.example.com/v/9.mp4', true);
xd.send();
check('mp4 首包即上报', posted.length === 1 && posted[0].url === 'https://cdn.example.com/v/9.mp4', posted);

// dump 接口给原生兜底取数（三个场景各留一条）
const dump = vm.runInContext('window.__tbSniffDump()', ctx);
let dumped = [];
try { dumped = JSON.parse(dump); } catch (e) {}
check('dump 返回合法 JSON', Array.isArray(dumped) && dumped.length === 3, dump);
check('dump 每条都带 url/src/ok', dumped.every(o => typeof o.url === 'string' && typeof o.src === 'string' && typeof o.ok === 'boolean'), dumped);

/* ---- Swift 接线（防止有人只改测试不改代码，或反着来） ---- */
console.log('Swift 接线');
const resolver = fs.readFileSync(path.join(ROOT, 'Sources/PlayResolver.swift'), 'utf8');
const webview = fs.readFileSync(path.join(ROOT, 'Sources/ParseWebView.swift'), 'utf8');
check('PlayResolver 走 viaParses', resolver.indexOf('viaParses(') >= 0);
check('PlayResolver 调 ParseWebView.sniff', resolver.indexOf('ParseWebView.sniff(') >= 0);
check('type 1 走 jsonParse', resolver.indexOf('p.type == 1') >= 0 && resolver.indexOf('jsonParse(') >= 0);
check('ParseWebView 读 sniff_rules', webview.indexOf('"sniff_rules"') >= 0);
check('ParseWebView 读 parse_sniff', webview.indexOf('"parse_sniff"') >= 0);
check('缺资源时给出可行动的诊断', webview.indexOf('bundle 里缺 parse_sniff.js') >= 0);

console.log('');
console.log(fail === 0 ? `全部通过（${pass}）` : `失败 ${fail} / 共 ${pass + fail}`);
process.exit(fail === 0 ? 0 : 1);
