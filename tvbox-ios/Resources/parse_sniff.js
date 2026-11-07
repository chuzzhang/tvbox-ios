/* parse_sniff.js —— 播放页嗅探的页面内 hook（注入到每个 frame，documentStart）
 *
 * 为什么单独放资源文件而不是塞进 Swift 字符串：JS 里全是正则和反斜杠，
 * 走 Swift 多行字符串要逐个转义，改一行崩一次，改错一次静默失效。
 *
 * 只做一件事：页面里任何一次「可能是媒体地址」的取数，都往原生抛一条消息。
 * 判定哪条算数交给 Swift（Resources/sniff_rules.json 决定过滤规则），
 * 这里只保证不丢信号。
 *
 * 上报格式：{ url: String, src: String, ok: Bool }
 *   src: xhr | fetch | media | source | attr | node | open
 *   ok : 响应体确认是 m3u8（#EXTM3U 开头）
 */
(function () {
  if (window.__tbSniffInstalled) { return; }
  window.__tbSniffInstalled = true;

  var MAX = 48;          // 单页最多记 48 条，防止长跑页面把内存吃光
  var list = [];
  window.__tbSniff = list;

  // 和 Swift 侧 ParseWebView.looksMedia 同语义：有扩展名就按扩展名判（避免 a.m3u8.jpg 这种挂羊头的），
  // 没扩展名才看路径和 query
  function media(u) {
    var path = String(u).split('#')[0].split('?')[0];
    var dot = path.lastIndexOf('.');
    var ext = dot >= 0 ? path.slice(dot + 1).toLowerCase() : '';
    if (ext.indexOf('/') >= 0) { ext = ''; }   // 点属于域名
    if (ext) { return /^(m3u8|mpd|mp4|m4v|mov|flv|ts|mkv|webm|mp3|m4a|aac)$/.test(ext); }
    if (/\/hls\//i.test(u)) { return true; }
    if (/[?&][^#]*m3u8/i.test(u)) { return true; }
    return false;
  }

  function playlist(t) {
    return typeof t === 'string' && t.indexOf('#EXTM3U') === 0;
  }

  function abs(u) {
    if (!u) { return ''; }
    try { return new URL(String(u), location.href).href; } catch (e) { return String(u); }
  }

  function send(payload) {
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tbSniff) {
        window.webkit.messageHandlers.tbSniff.postMessage(payload);
      }
    } catch (e) { /* 消息通道断了不该影响页面 */ }
  }

  function post(url, src, ok) {
    try {
      if (!url || typeof url !== 'string') { return; }
      // 没扩展名又不是确认过的响应体，一律不抛：原生侧收到的每条都要走正则，
      // 页面一次加载几十个 js/css，全抛过去会挤掉真正的候选
      if (!ok && !media(url)) { return; }
      if (url.length > 2048) { url = url.slice(0, 2048); }

      for (var i = 0; i < list.length; i++) {
        if (list[i].url !== url) { continue; }
        // 同一条地址：只有「未确认 → 确认」这一种升级值得再抛一次
        if (!ok || list[i].ok) { return; }
        list[i].ok = true;
        list[i].src = src;
        send({ url: url, src: src, ok: true });
        return;
      }

      if (list.length >= MAX) { return; }
      list.push({ url: url, src: src, ok: !!ok });
      send({ url: url, src: src, ok: !!ok });
    } catch (e) {}
  }

  window.__tbSniffPost = post;
  // 原生侧超时后会主动来取一次：iframe 里的消息偶尔到不了主 frame 的 handler
  window.__tbSniffDump = function () {
    try { return JSON.stringify(list); } catch (e) { return '[]'; }
  };

  // ---- 1) XHR：主路径，多数播放器用这个取 m3u8
  try {
    var XO = XMLHttpRequest.prototype.open;
    var XS = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (m, u) {
      try { this.__tbUrl = abs(u); } catch (e) {}
      return XO.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {
      var self = this;
      if (self.__tbUrl) {
        post(self.__tbUrl, 'xhr', false);
        try {
          self.addEventListener('load', function () {
            var t = '';
            // responseType 是 arraybuffer/blob 时读 responseText 会抛，跳过即可
            try {
              if (!self.responseType || self.responseType === 'text') { t = self.responseText || ''; }
            } catch (e) {}
            if (playlist(t)) { post(self.__tbUrl, 'xhr', true); }
          });
        } catch (e) {}
      }
      return XS.apply(this, arguments);
    };
  } catch (e) {}

  // ---- 2) fetch
  try {
    if (window.fetch) {
      var F = window.fetch;
      window.fetch = function (input, init) {
        var u = '';
        try { u = abs(typeof input === 'string' ? input : (input && input.url) || ''); } catch (e) {}
        if (u) { post(u, 'fetch', false); }
        var p = F.apply(this, arguments);
        try {
          p.then(function (r) {
            try {
              if (!u || !r) { return; }
              // clone 之后再读，否则原响应体被消费掉，播放器自己拿不到数据
              r.clone().text().then(function (t) {
                if (playlist(t)) { post(u, 'fetch', true); }
              })['catch'](function () {});
            } catch (e) {}
          })['catch'](function () {});
        } catch (e) {}
        return p;
      };
    }
  } catch (e) {}

  // ---- 3) video / source 的 src 赋值
  function hookSrc(proto, tag) {
    try {
      var d = Object.getOwnPropertyDescriptor(proto, 'src');
      if (!d || !d.set) { return; }
      Object.defineProperty(proto, 'src', {
        configurable: true,
        enumerable: d.enumerable,
        get: function () { return d.get.call(this); },
        set: function (v) { post(abs(v), tag, false); return d.set.call(this, v); }
      });
    } catch (e) {}
  }
  try { hookSrc(HTMLMediaElement.prototype, 'media'); } catch (e) {}
  try { hookSrc(HTMLSourceElement.prototype, 'source'); } catch (e) {}

  // ---- 4) setAttribute('src', ...)：某些播放器绕过属性 setter
  try {
    var SA = Element.prototype.setAttribute;
    Element.prototype.setAttribute = function (n, v) {
      try {
        if (String(n).toLowerCase() === 'src' && this.tagName && /^(VIDEO|SOURCE|AUDIO)$/.test(this.tagName)) {
          post(abs(v), 'attr', false);
        }
      } catch (e) {}
      return SA.apply(this, arguments);
    };
  } catch (e) {}

  // ---- 5) 新插入的 video/source（播放器常在拿到地址后才建标签）
  try {
    var MO = new MutationObserver(function (ms) {
      for (var i = 0; i < ms.length; i++) {
        var added = ms[i].addedNodes || [];
        for (var j = 0; j < added.length; j++) {
          var n = added[j];
          if (!n || n.nodeType !== 1) { continue; }
          var tag = (n.tagName || '').toUpperCase();
          if (tag !== 'VIDEO' && tag !== 'SOURCE' && tag !== 'AUDIO') { continue; }
          var s = n.getAttribute && n.getAttribute('src');
          if (s) { post(abs(s), 'node', false); }
        }
      }
    });
    MO.observe(document.documentElement || document, { childList: true, subtree: true });
  } catch (e) {}

  // ---- 7) 有的播放器非要「点一下」才去取流：静音 play() + 点一下常见播放按钮。
  //         不点的话页面一直停在封面，嗅探只能超时。
  function nudge() {
    try {
      var vs = document.querySelectorAll('video');
      for (var i = 0; i < vs.length; i++) {
        try { vs[i].muted = true; } catch (e) {}
        try {
          var p = vs[i].play();
          if (p && typeof p.catch === 'function') { p.catch(function () {}); }
        } catch (e) {}
      }
      var sels = ['.vjs-big-play-button', '.dplayer-play-icon', '.play-btn',
                  '.player-play', '[class*="big-play"]', '[class*="play-button"]'];
      for (var k = 0; k < sels.length; k++) {
        var el = document.querySelector(sels[k]);
        if (el && typeof el.click === 'function') {
          try { el.click(); } catch (e) {}
          break;
        }
      }
    } catch (e) {}
  }

  // 播放器初始化时间不固定，分几次轻推；测试环境没有 setTimeout 就直接来一次
  if (typeof setTimeout === 'function') {
    var delays = [600, 1800, 4000];
    for (var d = 0; d < delays.length; d++) {
      try { setTimeout(nudge, delays[d]); } catch (e) {}
    }
  } else {
    nudge();
  }

  // ---- 6) window.open：解析页有时另开窗口加载播放页
  try {
    var WO = window.open;
    window.open = function (u) {
      if (u) { post(abs(String(u)), 'open', false); }
      return WO.apply(this, arguments);
    };
  } catch (e) {}
})();
