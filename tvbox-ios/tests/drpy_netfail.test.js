// 首页请求失败时的诊断：日志里必须写清「为什么没拿到页面」，
// 而不是只写一句「0 字符」让人对着猜。
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const pdfh = () => '';
const pdfa = () => [];

function makeSandbox(ruleCode, pages, note) {
  const hits = [];
  const request = (url) => { hits.push(url); return pages[url] || ''; };
  const sandbox = {
    pdfh, pdfa, request,
    joinUrl: (b, h) => h,
    console,
    encodeURIComponent,
    parseInt,
    RegExp,
    String,
  };
  // 模拟原生桥：__httpNote(url) 给出请求失败原因
  if (note !== undefined) sandbox.__httpNote = () => note;
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

const rule = `
var rule = {
    title: 'ddys',
    host: 'https://ddys.pro',
    url: '/fyclass/page/fypage/',
    searchUrl: '/?s=**&post_type=post',
    class_parse: '#primary-menu li.menu-item;a&&Text;a&&href;.pro/(.*)',
    一级: '#post-list .post-item;a&&Text;a&&href;img&&data-src;.cat&&Text'
};
`;

/* ---------- 场景 1：源站 502 ---------- */
console.log('首页 502 · 诊断');
const s1 = makeSandbox(rule, {}, 'HTTP 502（源站上游不可用，服务器自己出问题了）');
const home1 = s1.sandbox.homeContent({});
const log1 = (s1.sandbox.__drpy_log__ || []).join('\n');

check('分类为空', Array.isArray(home1.class) && home1.class.length === 0, home1);
check('日志带上 HTTP 状态', log1.indexOf('HTTP 502') >= 0, log1);
check('日志区分「请求失败」而不是「选择器没抓到」',
  log1.indexOf('首页请求失败') >= 0 && log1.indexOf('class_parse 没抓到') < 0, log1);
check('告知 ddys 备用域名', log1.indexOf('ddys.io') >= 0, log1);
check('只请求一次首页（失败也不重试）',
  s1.hits.filter(u => u === 'https://ddys.pro').length === 1, s1.hits);

/* ---------- 场景 2：原生桥没给原因（老版本 / 异常） ---------- */
console.log('首页空响应 · 兜底文案');
const s2 = makeSandbox(rule, {});
const home2 = s2.sandbox.homeContent({});
const log2 = (s2.sandbox.__drpy_log__ || []).join('\n');
check('仍给出「空响应」', log2.indexOf('空响应') >= 0, log2);
check('分类为空', home2.class.length === 0, home2);

/* ---------- 场景 3：非 ddys 站点不出现 ddys 提示 ---------- */
console.log('其他站点 · 不误报备用域名');
const rule3 = rule.replace('https://ddys.pro', 'https://example.org');
const s3 = makeSandbox(rule3, {}, '连接超时（12 秒）');
s3.sandbox.homeContent({});
const log3 = (s3.sandbox.__drpy_log__ || []).join('\n');
check('带超时原因', log3.indexOf('连接超时') >= 0, log3);
check('没有 ddys 提示', log3.indexOf('ddys.io') < 0, log3);

/* ---------- 场景 4：页面正常但选择器不命中 ---------- */
console.log('页面正常 · 选择器不命中');
const s4 = makeSandbox(rule, {
  'https://ddys.pro': '<html><body><div class="other">无导航</div></body></html>'
}, '');
s4.sandbox.homeContent({});
const log4 = (s4.sandbox.__drpy_log__ || []).join('\n');
check('日志写明页面长度', log4.indexOf('页面 51 字符') >= 0 || /class_parse 没抓到（父选择器 .*页面 \d+ 字符）/.test(log4), log4);
check('不说请求失败', log4.indexOf('首页请求失败') < 0, log4);

console.log('');
console.log(fail === 0 ? `全部通过（${pass}）` : `失败 ${fail} / 共 ${pass + fail}`);
process.exit(fail === 0 ? 0 : 1);
