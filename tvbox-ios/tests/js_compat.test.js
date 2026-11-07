// Resources/compat.js 的本地验证。
//
// 这个文件是给「新版 js spider」用的：脚本里 `import cheerio …`、`await req(url).content`、
// `export default {…}`，JSCore 一样都没有。原生侧负责剥 ESM、提供 __reqSync / __sel /
// __text / __innerHtml / __attr / __log，这个测试用同一套桩把兼容层跑起来。
//
// 注意：选择器语义在原生侧是 SwiftSoup，这里用最小桩替身，所以只验证「管道通不通」，
// 不验证 CSS 正确性（那部分由 check.py 和真机保证）。
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const src = fs.readFileSync(path.join(__dirname, '../Resources/compat.js'), 'utf8');

let pass = 0, fail = 0;
function check(name, ok, extra) {
  if (ok) { pass++; } else { fail++; console.log('FAIL ' + name + (extra !== undefined ? '  →  ' + JSON.stringify(extra) : '')); }
}

const HTML_A = '<a href="/v/1" class="title">标题一</a>';
const HTML_ITEM = '<div class="item">' + HTML_A + '</div>';
const PAGE = '<html><body><div class="list">' + HTML_ITEM + '</div></body></html>';

const logs = [];
const sandbox = {
  __reqSync: function (url, hjson, method, body, b64) {
    if (String(url).indexOf('bin') >= 0) return 'QUJD';       // base64 分支
    if (String(url).indexOf('json') >= 0) return '{"ok":1}';
    return PAGE;
  },
  __sel: function (html, sel) {
    // 桩：只认这几种，够验证 shim 的串接逻辑
    if (/^\.item\b|\.list\s+\.item|\.item$/.test(sel.trim())) return JSON.stringify([HTML_ITEM]);
    if (/^a\b|^\.title$/.test(sel.trim())) return JSON.stringify([HTML_A]);
    return '[]';
  },
  __text: function (html) {
    return String(html).replace(/<[^>]*>/g, '');
  },
  __innerHtml: function (html) {
    const m = String(html).match(/^<[^>]*>([\s\S]*)<\/[^>]*>$/);
    return m ? m[1] : '';
  },
  __attr: function (html, name) {
    const m = String(html).match(new RegExp(name + '="([^"]*)"'));
    return m ? m[1] : '';
  },
  __log: function (line) { logs.push(line); return 0; },
};
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
vm.runInContext(src, sandbox, { filename: 'compat.js' });

/* ---------------- console ---------------- */
console.log('console');
const g = sandbox;
g.console.log('hello', 1);
check('console.log 进日志', logs.length === 1 && logs[0].indexOf('hello 1') >= 0, logs);
g.console.warn('w');
check('warn 带标记', logs[1].indexOf('[warn]') === 0, logs[1]);

/* ---------------- req ---------------- */
console.log('req');
check('req 是函数', typeof g.req === 'function');
const r = g.req('http://x/');
check('content 能当字符串用', String(r.content) === PAGE, String(r.content).slice(0, 40));
check('content.length 正确', r.content.length === PAGE.length, r.content.length);
check('content.substring 可用', r.content.substring(0, 5) === '<html', r.content.substring(0, 5));
check('buffer:2 走 base64', g.req('http://x/bin', { buffer: 2 }).content + '' === 'QUJD');
check('json() 返回 Promise', typeof g.req('http://x/json').json().then === 'function');

/* ---------------- cheerio ---------------- */
console.log('cheerio');
check('cheerio.load 存在', typeof g.cheerio === 'object' && typeof g.cheerio.load === 'function');
const $ = g.cheerio.load(PAGE);
check('$(sel) 命中一条', $('.item').length === 1, $('.item').length);
check('链式 find + text', $('.item').find('a').text() === '标题一', $('.item').find('a').text());
check('attr 取到 href', $('.item').find('a').attr('href') === '/v/1');
check('缺失属性返回 undefined', $('.item').find('a').attr('nope') === undefined);
check('html() 取内层', $('.item').html() === HTML_A, $('.item').html());

let seen = 0;
$('.item').each(function (i, el) { seen++; check('each 回调拿到节点', $(el).find('a').text() === '标题一'); });
check('each 次数', seen === 1, seen);

check('toArray 是数组', Array.isArray($('.item').toArray()) && $('.item').toArray().length === 1);
check('first() 只留一个', $('.item').first().length === 1);
check('eq 越界为空', $('.item').eq(5).length === 0);

/* ---------------- Promise 抽头 ---------------- */
console.log('__tb_watch');
g.__tb_watch(42);
check('非 Promise 直接落 state', g.__tb_state === 1 && g.__tb_value === 42, g.__tb_state);

/* ---------------- 老引擎补丁 ---------------- */
console.log('polyfill');
check('Object.hasOwn', vm.runInContext('Object.hasOwn({x:1},"x")', sandbox) === true);
check('replaceAll', vm.runInContext('"a-b-c".replaceAll("-","_")', sandbox) === 'a_b_c');
check('[].at(-1)', vm.runInContext('[1,2,3].at(-1)', sandbox) === 3);
check('findLast', vm.runInContext('[1,2,3].findLast(function(v){return v<3})', sandbox) === 2);
check('structuredClone', vm.runInContext('structuredClone({a:[1]}).a[0]', sandbox) === 1);

/* ---------------- 真脚本形态：ESM 剥完后的手写最小样例 ---------------- */
(async () => {
  // Promise 分支要靠微任务，抽头逻辑在原生侧是轮询 __tb_state 实现的
  g.__tb_watch(Promise.resolve({ a: 1 }));
  await Promise.resolve();
  check('Promise 抽头', g.__tb_state === 1 && g.__tb_value && g.__tb_value.a === 1, g.__tb_state);

  console.log('模拟一条 async 入口');
  const site = `
    async function home(fl) {
      var html = (await req('http://x/')).content;
      var $ = cheerio.load(html);
      var out = [];
      $('.item').each(function (i, el) {
        out.push({ type_id: $(el).find('a').attr('href'), type_name: $(el).find('a').text() });
      });
      return { class: out };
    }
    var __default_export__ = { home: home };
  `;
  vm.runInContext(site, sandbox, { filename: 'site.js' });
  check('站点脚本拿到 cheerio', typeof g.cheerio.load === 'function');

  const res = await g.home({});
  check('home 返回 class', res && Array.isArray(res.class) && res.class.length === 1, res);
  check('class 字段正确', res.class[0].type_id === '/v/1' && res.class[0].type_name === '标题一', res.class[0]);

  console.log('');
  console.log(fail === 0 ? `全部通过（${pass}）` : `失败 ${fail} / 共 ${pass + fail}`);
  process.exit(fail === 0 ? 0 : 1);
})();
