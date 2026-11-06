# TVBox iOS 交接文档

版本：build 23（`CURRENT_PROJECT_VERSION: "23"`）  
最后更新：2026-11-07  
项目根：`tvbox-ios/`

---

## 0. 这是什么

Android TVBox（fongmi 内核）的 iOS 原生重写。输入是 TVBox 的 JSON 配置 URL，输出是一个能导入配置、列站点、进分类、看详情、播放的 iOS App。

不是转码产物。APK 里的 `classes.dex` 需要 ART，`.so` 是 bionic + JNI，两者在 iOS 上都没有对应物，所以整个 App 是用 SwiftUI 重写的，靠三套解释器去执行配置里下发的站点逻辑。

当前状态：**CMS 站点可用；drpy / pyramid 规则站点可用；js spider 可用；纯 dex jar、pyc 脚本、加固包不可用**（见第 9 节，附实测数据）。

---

## 1. 运行环境

| 项 | 值 |
|---|---|
| 最低系统 | iOS 15.0（`project.yml:5`） |
| 语言 | Swift 5.0 |
| 依赖 | SwiftSoup 2.7.0、ZIPFoundation 0.9.19（SPM） |
| Bundle ID | `osc.tvbox.jun` |
| 工程生成 | XcodeGen（`project.yml` → `TVBox.xcodeproj`，不入库） |
| 构建机 | GitHub Actions `macos-15` + 最新正式版 Xcode（实测 Xcode 26.3，build 约 4.5 分钟） |
| 包体 | 未签名 ipa，需自签后安装 |

关键编译开关（`project.yml:20-27`）：

```yaml
SWIFT_STRICT_CONCURRENCY: minimal   # Swift 6 严格并发会把 AVPlayer/JSContext 判成错误
SWIFT_TREAT_WARNINGS_AS_ERRORS: NO
ENABLE_BITCODE: NO
OTHER_LDFLAGS: "-ObjC"              # JSContext 的 category 需要
```

---

## 2. 目录结构

```
tvbox-ios/
├── project.yml                    XcodeGen 工程描述，版本号在这里
├── Info.plist                     ATS 放开（配置和流地址大量是 http）
├── Sources/                       22 个文件，6124 行
│   ├── App.swift                  入口、底部 Tab、配置页（导入/诊断/错误详情）
│   ├── Store.swift                AppState：配置、站点、历史、收藏、死站点集合
│   ├── Models.swift               BoxConfig / Site / Live / Parse / VItem / VDetail / PlayLine
│   ├── Api.swift                  ConfigLoader（配置加载 + 多仓解码）、CMSApi（maccms 客户端）
│   ├── CMSXml.swift               maccms 的 XML 输出解析（api/xml.php 这类源）
│   ├── Net.swift                  HTTP 层：重试、镜像兜底、错误分类
│   ├── URLKit.swift               相对路径解析（见 4.1）
│   ├── JarScript.swift            ScriptResolver：决定一个站点该走哪套引擎
│   ├── Drpy.swift                 drpy / pyramid 规则加载器
│   ├── JSSpider.swift             JavaScriptCore 宿主：pdfh/pdfa/request 桥 + 规则引擎
│   ├── Mirrors.swift              脚本镜像候选（jsdelivr / gitmirror / ghproxy）
│   ├── DexInfo.swift              只读 dex 扫描，用于生成"为什么跑不了"的诊断
│   ├── GuardSites.swift           加固壳识别与结论生成
│   ├── SpiderStore.swift          顶层 spider 字段加载（jar/zip/js）
│   ├── PlayResolver.swift         播放地址解析（?url= 抽真链、parses 分发：json / webview）
│   ├── ParseWebView.swift         播放页嗅探：无界面 WKWebView 拦 m3u8（见 4.9）
│   ├── HLSLocalProxy.swift        skd:// 本地代理，给 HLS 请求注入 Referer/UA
│   ├── HomeView.swift             首页信息流、分类、海报卡、不可用提示
│   ├── DetailView.swift           详情页、剧集列表
│   ├── PlayerView.swift           AVPlayer 封装、音轨/字幕、看门狗
│   ├── Extras.swift               搜索、收藏/历史
│   └── SpiderView.swift           站点诊断面板（每个站点走哪条路、失败原因）
├── Resources/                     打进 app bundle
│   ├── drpy_lite.js               drpy 规则解释器（自写，语义对齐 cat.js）
│   ├── cat.js                     drpy 官方库（规则脚本依赖它）
│   ├── cheerio.min.js             dom 模拟层
│   ├── crypto-js.js               drpy 规则里的加密工具
│   ├── parse_sniff.js             注入播放页的 hook（XHR / fetch / video.src）
│   └── sniff_rules.json           嗅探过滤与排序规则（改这里不用重编）
├── tools/
│   ├── check.py                   静态校验（CI 第一道关）
│   ├── pyc38.py                   Python 3.8 pyc 只读解析器（分析用）
│   ├── check_config.py            配置体检：站点分型 + spider 包识别 + 探活
│   ├── check_tls.py               域名 TLS 体检：ok / sni-blocked / tls-broken / dead
│   ├── dex_scan.py                从 spider jar 里抽每个类的接口字符串（改写 js 的第一步）
│   ├── frida_dump_wex.js          wexguard 加固壳的 dex 提取
│   ├── frida_hook_http.js         抓 jar 站点真实请求（okhttp / URLConnection）
│   ├── frida_dump_wex.js          加固壳 dump（hook DexClassLoader / 内存扫 dex）
│   └── make_icon.py               图标生成
├── tests/                         6 个 node 单测，共 125 项
└── Assets.xcassets/
```

`.github/workflows/ios.yml` 在仓库根，构建入口。

---

## 3. 数据流

```
配置 URL
  │  ConfigLoader.load                     Api.swift:6
  │  └─ 支持 {urls:[...]} 多仓合并
  ▼
BoxConfig { spider, sites[], lives[], parses[], doh, rules }
  │  Store.refreshConfig                   Store.swift:51
  │  └─ 记录 configBase（配置所在目录），滤掉重复 key 和 doa 站点
  ▼
Site.effectiveType                        Models.swift:210
  ├─ type 0/1 → CMS  ────────────────► CMSApi
  ├─ type 3/4 → 脚本 ───────────────► ScriptResolver
  └─ type 3 但 api 是 http 直链 → 当 CMS（配置里标错的很多）
  ▼
ScriptResolver.resolve                    JarScript.swift:29
  ├─ 1. Pyramid 规则（py_xxx + ext 是 json/js 规则）
  ├─ 2. drpy 规则（api 含 drpy / ext 是规则文件）
  ├─ 3. 站点级 js / jar
  ├─ 4. 顶层 spider 包
  ├─ 5. 内置解释器兜底
  └─ 失败 → 结构化诊断字符串（不是一句"脚本不可用"）
  ▼
JSSpider（一条串行队列）                   JSSpider.swift:625
  ▼
HomeView / DetailView
  ▼
PlayResolver.resolve                      PlayResolver.swift:56
  ├─ 直接探通 ────────────────────────► 用原地址
  └─ 探不通 → parses[] 按配置顺序逐条试   PlayResolver.viaParses
       ├─ type 1      → jsonParse      拼 ?url= 取 JSON 里的真链
       └─ type 0/2    → ParseWebView   无界面 WKWebView 拦请求（见 4.9）
  ▼
HLSProxy(skd://) → AVPlayer
```

---

## 4. 关键实现，改之前必须知道

### 4.1 相对路径一律走 URLKit

TVBox 配置里的 `spider: "./jar/x.jar"`、`api: "./api.php/provide/vod"` 都是相对**配置文件所在目录**，不是相对请求 URL，也不是相对根。

```swift
URLKit.base("https://a.com/cfg/box.json")   // → "https://a.com/cfg/"
URLKit.resolve("./jar/x.jar", base: ...)    // → "https://a.com/cfg/jar/x.jar"
```

`URLKit.resolve` 返回**非可选 String**，无解时返回空串哨兵。这条规则直接导致过一个编译错误：`PlayResolver.swift:74` 曾写 `if let u = URLKit.origin(x)`，非可选类型不能条件绑定。`tools/check.py` 现在有专门的 `check_bindings()` 拦这类写法。

### 4.2 Site.effectiveType 是路由的唯一入口

不要在各 View 里自己判断 `type`。`Models.swift:210` 处理了三种脏数据：
- `type` 是字符串 `"1"` → `Site.int()` 转
- 标成 spider 但 api 是 `http` 直链（不含 `.js` / `.jar`）→ 降级成 CMS
- `api` 为空但有 `ext` → 仍然 usable（脚本站点常把入口放 ext）

### 4.3 顶层 spider 的三种形态

`SpiderStore` 负责下载和解包，地址常带校验后缀：

```
http://x.com/spider.jar;md5;abcdef...
http://x.com/spider.zip;pk;...
```

后缀必须先剥掉再请求，否则 404。解包后：
- 有 `.js` → 取出全部 js 作为 `scripts`，站点 api 的 `csp_xxx` 用于在其中查找同名规则
- 纯 `.dex` → **不可执行**，转 `DexInfo.scan()` 生成诊断

### 4.4 drpy 的 class_parse 是四段选择器链

格式：`父选择器;名称选择器;链接选择器;正则`

```
#primary-menu li.menu-item;a&&Text;a&&href;.pro/(.*)
```

正则的**捕获组**作为 `fyclass`（分类 id），不是整段匹配。`drpy_lite.js` 里 `_parseClassSelector` 处理这段；`Resources/drpy_lite.js` 还负责：
- 剥离 `body&&` 前缀（cat.js 的方言）
- 补 `MOBILE_UA` / `PC_UA` / `UA` 全局
- 兼容英文键 `first/second/firstUrl/secondUrl/searchRule`（drpy 有中英两套写法）
- `_get()` 带页缓存，`__drpy_log__` 收集日志给诊断面板

### 4.5 JS 桥必须串行

`JSContext` 不可并发访问。所有 JS 执行走 `JSSpider.jsQueue`（`JSSpider.swift:52`），`JSSpider.run(_:)` 是唯一入口（`:625`），内部 `jsQueue.async` + `CheckedContinuation`。**新增任何 JS 调用点都必须经过 `run`**，直接 `ctx.evaluateScript` 会造成随机崩溃。

暴露给 JS 的原生对象（`JSSpider.swift:452-477`）：

| JS 名 | 作用 |
|---|---|
| `request(url, opt)` | 同步 HTTP，返回字符串 |
| `pdfh(html, selector)` | 单元素取值，支持 `a&&Text` / `a&&href` |
| `pdfa(html, selector)` | 多元素取值，返回数组 |
| `joinUrl(base, rel)` | 拼 URL |
| `log(...)` | 写日志 |
| `__httpNote(url)` | 取该 URL 的 HTTP 诊断（状态码、失败原因） |

`syncGet` 记录 `HTTPNote`，非 2xx 的正文**不交给 JS 解析**——这点很重要，否则一堆站点会把错误页当列表页解析出空结果，表现为"跑了但没数据"。

### 4.6 脚本 401/404 的镜像兜底

`Mirrors.swift` 对 `/dr_py/` 这类路径按尾部拼镜像：

```
jsdelivr → raw.gitmirror → ghproxy
```

最多 8 个候选，每个 8 秒。命中后 `fetchScriptTracked` 返回 `{data, mirror}`，诊断里写明走的是哪个镜像。

不是所有 401 都能救：如果整站鉴权（例如某些 dr_py 源），镜像也拿不到，此时诊断应该直说"服务端鉴权，客户端无解"，不要伪装成网络错误。

### 4.7 播放：skd:// 本地代理是必需的

`AVURLAssetHTTPHeaderFieldsKey` 在 iOS 上**不生效**。要带 Referer/UA 只有一条路：把 URL 换成 `skd://`，用 `AVAssetResourceLoaderDelegate` 自己发请求。

```
http URL
  → HLSProxy.proxyURL()        HLSLocalProxy.swift:34   skd://proxy/<base64>
  → AVURLAsset(url: skd://...)
  → resourceLoader(_:shouldWaitForLoadingOfRequestedResource:)
  → 自己发 HTTP，重写 m3u8 里的 URI
```

`HLSProxy.rewrite`（`:108`）必须处理 m3u8 里四类引用：
- 普通分片行
- 子列表（`#EXT-X-STREAM-INF` 下一行）
- `URI="..."` 的 `#EXT-X-KEY` / `#EXT-X-MAP` / `#EXT-X-MEDIA`

漏一个就黑屏。历史上 98 影院的黑屏就是这个原因，加上 `PlayResolver` 丢掉相对路径，双重问题。

`PlayerView` 有 15 秒看门狗：`AVPlayerItem` 一直没进入 `readyToPlay` 就判定失败并给出具体原因，不要让它停在无限转圈。

控制条在 `PlayerView.bottomControls`：播放/暂停、±10 秒、进度条、时间。几个约束：

- 进度由 `PlayerModel.startTicker()` 每 0.5 秒采样（`timeControlStatus` / `currentTime` / `duration`），跟着 model 生命周期走，`teardown` 一起取消。
- 直播流（m3u8 没有 `ENDLIST`）`duration` 是 `indefinite`，此时 `seekable = false`，进度条禁用、时间处显示「直播」，别硬拖。
- 拖动期间用 `dragging` 标志挡住采样回写，否则手指按住时滑块会被采样抢回去。
- 点画面的手势层压在视频上、控制条下（`Color.clear.contentShape(Rectangle())`），所以点按钮、拖滑块不会触发显隐。
- 手势：**左半屏竖拖 = 亮度，右半屏竖拖 = 音量，横拖 = 进度**，`DragGesture(minimumDistance: 10)` 首帧按位移大的方向定轴，之后不再改轴，避免调音量中途变成拖进度。
- 亮度直接写 `UIScreen.main.brightness`，进页面先 `captureBrightness()`、走的时候 `restoreBrightness()`，否则退出播放后整机一直是暗的。
- 音量只能动 `AVPlayer.volume`（0…1，应用内系数，叠在系统音量上）。iOS 没有公开 API 让 App 改系统音量，要动系统音量得挂一个隐藏的 `MPVolumeView` 去找它的 `UISlider`，那是私有视图结构，系统一改版就断，不划算。
- **`AVAudioSession` 必须设成 `.playback`**：默认的 `soloAmbient` 会被侧边静音键掐掉，表现就是"音量拖到 100% 也没声"。`startAV` / `startVLC` 里激活，`teardown` 里 `setActive(false, options: .notifyOthersOnDeactivation)`。

### 4.8 诊断是功能的一部分

这个项目约三分之一代码在做"解释为什么不能用"。原因很直接：TVBox 配置里能用的站点比例本来就不高，用户看到"打不开"和看到"这个站的 api 是纯 dex jar，iOS 无 ART"是完全不同的体验。

三处诊断入口：
- `SpiderView`：站点级，每个站显示 `routeLabel` + 失败原因
- `GuardSites.verdict`：加固包结论（`:56`）
- `App.swift` 配置页：`lastErrorDetail` 原文可长按复制

新增引擎时，**失败的返回必须是一条能行动的信息**（缺什么、去哪补、下一步命令），不是 error enum。

---

### 4.9 parses 的两种 type，别混在一起写

`parses` 里两种接口语义完全不同，混着放，顺序是站点作者排的可靠度顺序，**不要按类型重排**：

| type | 形态 | 处理 |
|---|---|---|
| `1` | json 接口，`.../?url=<播放页>` 回 `{"url":"真链"}` | `PlayResolver.jsonParse` |
| `0` / `2` / 缺省 | `url` 本身就是播放页，页面里的播放器自己发包 | `ParseWebView.sniff` |

嗅探之所以要真开 webview：这类页面的地址只存在于运行时的请求里，HTTP 拉页面拿到的是空壳 HTML。

`ParseWebView` 的几条硬约束：

- **三层拦截**：`parse_sniff.js` hook XHR / fetch（主路径）、hook `video.src` 与 `setAttribute`（少数站点直接赋值）、原生 `decidePolicyFor`（整页跳转到 m3u8）。漏一层就有一类站点拿不到。
- **`alpha = 0.01` 不能写 0**。完全透明会让 WebKit 判定不可见并降频，定时器和后续请求被节流，页面不发包，表现为"嗅探总是超时"。
- **`decisionHandler` 必须同步调用**，跨线程 hop 会让 WebKit 状态机超时。所以判定逻辑用纯函数，命中后再落记录。
- **同一条地址允许"未确认 → 确认"升级**：首包只能按扩展名判，XHR 读回 `#EXTM3U` 后要重算分数，否则排位按首包算，会把没扩展名的主线路排在后面。
- **嗅探带回来的 Referer 要覆盖**（`ParseAttempt.headers`）：这类流认的是播放页的 Referer，不是站点根，拿站点根去探就是 403。
- 预算卡在 `sniff_rules.json`：json 4 条、webview 2 条、单次 14 秒、命中后等的 settle 1.2 秒。不卡的话一次播放能等几分钟。
- 失败必须给出可行动的原因（要求登录 / MSE 取流 / 页面接口不被 WKWebView 支持），不是一句"嗅探失败"。

改过滤规则只动 `Resources/sniff_rules.json`，不重编；改 hook 要同步 `tests/parse_webview.test.js`（它把 `parse_sniff.js` 丢进 vm 的假 DOM 里跑，真机上 JS 语法错的表现是"所有 parses 站点静默失败"）。

### 4.10 CMS 分类可能是两级的，父分类经常是空的

maccms 的 `class` 里有 `type_pid`。很多源（例如 `api.example.com`）顶层分类只做分组，
本身一条片子都不挂：`?ac=videolist&t=20`（父分类）返回 `total=0`，
只有子分类 `t=24`（父分类下的具体栏目）才有数据。

`FeedView` 因此拆成两行分类条：

- 顶层：`type_pid` 为空、为 `"0"`、或指向一个不存在的 id
- 子分类：`type_pid == 选中的顶层 id`，有子分类时显示第二行，尺寸小一号
- **默认落到第一个顶层下的第一个子分类**，不是第一个顶层本身 —— 否则一进站点就是「该分类没有返回内容」

`VCategory.type_pid` 走 `Loose.text` 取（maccms 里是数字），加字段时别忘了同步
`extension VCategory` 的 `init(from:)` / `encode(to:)` 两处，只改 struct 声明不会生效。

### 4.11 CMS 除了 JSON 还有一种 XML 输出

有些源只给 XML（`api/xml.php`，或 `?at=xml`），返回：

```xml
<rss version="5.1"><list page="1" pagecount="1284" recordcount="25673">
  <video><id>258422</id><tid>29</tid><name><![CDATA[stars-805ch new]]></name>
         <pic/><note/><dt>ckplayer</dt>
         <dl><dd flag="ckplayer"><![CDATA[第1集$http://…]]></dd></dl>
  </video>
</list><class><ty id="26">国产剧</ty></class></rss>
```

JSON 解它必然报 `Unexpected character 'C' around line 1, column 2` —— 那个 C 是 `<![CDATA[` 的 C。

- `CMSXml.looksLikeXML` 看首字节是不是 `<`；`CMSApi.loadList` 先判 XML 再退回 JSON，
  Content-Type 写着 json、内容其实是 xml 的源也覆盖到了。
- CDATA 必须走 `parser(_:foundCDATA:)`，`foundCharacters` 收不到，漏了所有中文名和播放地址都是空。
- `<list>` 的 `pagecount` 是**属性**不是子节点。
- `ac=list` 时 `<class>` 常常是空壳（只给 `tid` 不给名字），此时兜底成一个「全部」分类，请求不带 `t`。
- `ac=list` 的 `<video>` 里没有 `<pic>`，封面只有 `ac=videolist` 才有 —— 列表页走 videolist，别图省事用 list。
- 线路名优先取 `<dd flag="…">`，没有就沿用它前面最近的 `<dt>`。

### 4.12 python 站点：api 是 `.py` 还是 ext 是 `.py`，判定路径不同

配置里两种写法都常见：

| 写法 | 例子 | 判定 |
|---|---|---|
| `api` 是脚本路径 | `py_xxx` → `api: ./js/ss/xxx.py` | `apiIsPyFile`，走 `describePyScript` |
| `api` 是 `py_xxx`，脚本在 `ext` | `py_xxx` + 长段 python 源码 | `site.isPyramid` + `pyScriptLike` |

以前只判第二种，第一种（api 直接是 `.py`）会一路掉到最后，被标成「jar 内置」——
可它根本没有 jar 参与。现在 `ScriptResolver` 第 0 步就把它拦下，并且**真去拉一次脚本**，
把三种情况分开写：

- 200 + Python 源码 → 「脚本本身在：40 KB，需要 CPython 3.x」，附依赖说明
- 200 + HTML → 「上游返回的是网页不是脚本，多半开了防盗链」
- 404/401 → 上游已删

`Site.routeLabel` 也要跟着认 `api` 的 `.py` 后缀，否则列表里显示的还是「jar 内置」。

### 4.13 仓库里不放真实站点/配置地址

文档、注释、测试夹具、工具示例里一律用虚构域名：

```
example.com / example.org       通用示例
demo-vod.example                drpy 测试里的假站
api.example.com                 采集接口示例
```

排查问题时把真实域名临时贴进对话或本地文件，不要提交。测试夹具换域名时要留意
`class_parse` 那种带正则的规则（`.pro/(.*)` 会随 host 变化裁出不同的 type_id），
改完把对应断言一起改，`node tests/*.test.js` 必须全绿。

运行时也不带任何站点特判：`drpy_lite.js` 里曾经有过"某个站返回空就提示它的备用域名"
的分支，已经删掉 —— 这类信息会随站点一起过期，而且等于把站名写进了 App。

## 5. 持久化

全部 `UserDefaults`，没有 CoreData。

| key | 类型 | 内容 |
|---|---|---|
| `cfg.url` | String | 配置 URL 或内联 JSON |
| `cfg.base` | String | 配置目录，相对路径基准 |
| `site.dead` | [String] | 加载失败的站点 key，初始选中时跳过 |
| `list.history` | Data(JSON) | 观看历史 |
| `list.fav` | Data(JSON) | 收藏 |

`Store.swift:141/146` 有通用的列表存取。加新列表照抄即可。

---

## 6. 构建与发版

### CI（推荐）

push 到 `main`，且改动命中 `tvbox-ios/**` 或 workflow 本身，自动跑。

```
选择最新正式版 Xcode（≥16，xcodegen 产出 objectVersion 77）
  → brew install xcodegen
  → python3 tools/check.py          静态校验
  → node tests/*.test.js            逐文件点名跑 6 个
  → xcodegen generate
  → 校验 objectVersion 与 Xcode 主版本匹配
  → resolvePackageDependencies
  → archive（CODE_SIGNING_ALLOWED=NO），日志落 build.log
  → 打包 Payload → TVBox.ipa
  → 上传 artifact: TVBox-unsigned-ipa
  → 发 Release：tag = build{版本号}，附 TVBox-{版本}.ipa + sha256
```

失败时上传 `TVBox-build-log`（含 `build.log` 和 `.xcresult`，保留 7 天）。

CI 里两个坑已经踩过，改 workflow 时别退回去：

1. **不要用 glob 跑测试**。`node tests/*.test.js` 在目录缺失时会把字面量丢给 node，报 `MODULE_NOT_FOUND` 直接失败。现在是 6 个文件名逐个点名，缺文件只提示。
2. **archive 输出必须落文件再 grep**。Actions 折叠日志后只剩 `exit code 65`，什么都看不到。现在 `grep -n "error:" build.log | head -80`。

### 本地

```bash
cd tvbox-ios
xcodegen generate --spec project.yml
python3 tools/check.py

# 出未签名 ipa（和 CI 同参数）
xcodebuild archive \
  -project TVBox.xcodeproj -scheme TVBox -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -archivePath build/TVBox.xcarchive -derivedDataPath build/dd \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

mkdir -p build/Payload
cp -R build/TVBox.xcarchive/Products/Applications/TVBox.app build/Payload/
rm -rf build/Payload/TVBox.app/_CodeSignature
cd build && zip -qry TVBox.ipa Payload
```

自签工具随意（Sideloadly / AltStore / TrollStore）。Bundle ID 必须和描述文件一致。

### 发版号

改 `project.yml` 的 `CURRENT_PROJECT_VERSION`（现在是 23），commit 后 CI 出新包并**自动发 Release**：

```
tag        build23
标题       TVBox 1.0.23 (build 23)
资产       TVBox-1.0.23.ipa（未签名）+ TVBox-1.0.23.ipa.sha256
正文       自签说明 + 包信息 + 本次更新（上个 tag 以来的提交）+ 对比链接
安装后显示 版本 1.0.23（23）
```

正文里的更新列表是自己用 `git log $PREV..HEAD` 生成的，**不要换回 `--generate-notes`** ——
仓库全是直接 push、没有 PR，GitHub 的自动笔记只会给一行 compare 链接，等于没写。
checkout 必须 `fetch-depth: 0`，浅克隆里 `git describe --tags` 取不到上一个版本。

`1.0.23` = `MARKETING_VERSION` 去掉末位（1.0）+ `CURRENT_PROJECT_VERSION`（23），由 workflow 的
「读版本号」步骤算出来，再用 `xcodebuild MARKETING_VERSION=…` 覆盖进包 —— 所以设置里显示的
版本号跟着每次构建走，不会永远停在 `1.0.0`。改版号不用动 workflow。

**发版不自动删旧版本**：每个 build 一个 tag + 一个 release，历史全留，方便回滚到任意一版。
要清理手动来：

```bash
gh release delete build20 --yes --cleanup-tag
```

不要改 `MARKETING_VERSION`（保持 `1.0.0`）。Release 步骤是幂等的：同名 tag 会先删再建，
同一个版本号重跑不会撞，资产覆盖成最新构建。发版需要 `permissions: contents: write`，
已经写在 job 上 —— 仓库默认 workflow 权限是 read，去掉会 403。

---

## 7. 验证

### 静态校验

```bash
cd tvbox-ios && python3 tools/check.py
```

检查项：
- 括号配对（跳过字符串和注释）
- 类型重名
- `check_bindings()`：`if let` / `guard let` 绑定了非可选表达式 → 报错
- 编译指令（`#if` / `#endif` 配对）

**这个脚本拦住了两次会直接导致 CI 失败的错误**，每次改 Swift 都先跑。

### 单测

```bash
cd tvbox-ios
for f in tests/*.test.js; do node "$f"; done
```

125 项，覆盖：

| 文件 | 项数 | 覆盖点 |
|---|---|---|
| `drpy_lite.test.js` | 18 | 规则解释器主流程、线路名、`body&&` 剥离 |
| `drpy_jsrule.test.js` | 13 | js 规则文件、搜索词编码 |
| `drpy_classparse.test.js` | 13 | 四段 class_parse、正则捕获、失败日志 |
| `drpy_netfail.test.js` | 10 | 非 2xx 不解析、错误文案 |
| `drpy_pyramid.test.js` | 18 | pyramid 规则语义、搜索编码 |
| `parse_webview.test.js` | 53 | sniff_rules 规则、hook 脚本（vm 假 DOM 跑通 XHR/确认升级）、Swift 接线 |

测试用 cheerio 模拟 iOS 端的 `pdfh` / `pdfa` / `request`，语义和 `JSSpider.swift:562-621` 对齐。**改了桥的语义，同步改测试里的模拟层**，否则测试会骗人。

### 真机验收清单

装包后按顺序过：

1. 配置导入 → 站点列表非空
2. 列表里能看到 `CMS` / `js 脚本` / `py 规则` 等标注（`routeLabel`）
3. 点一个 CMS 站 → 出分类 → 进分类 → 出条目
4. 点一个 drpy 站 → 出分类 → 进分类 → 出条目
5. 进详情 → 出剧集
6. 播放 → 15 秒内出画面或给出具体失败原因
7. 搜索一个关键词 → 有结果
8. 收藏 → 重进 app 仍在

任何一步失败，去 `SpiderView` 看诊断，不要只看黑屏。

---

## 8. 能力边界（实测数据，不是估计）

### 可执行

| 类型 | 条件 | 实现 |
|---|---|---|
| CMS（type 0/1） | api 是 maccms 兼容接口 | `CMSApi.swift:113` |
| drpy 规则 | ext 是 JSON 规则或 js 规则 | `Drpy.swift:67` + `drpy_lite.js` |
| pyramid 规则 | `py_xxx` + ext 是规则 | 同上（语义同 drpy） |
| js spider | 顶层 spider 包内含 `.js` | `JSSpider.swift` |
| 内联规则 | `api` 里直接是规则 JSON | `ScriptResolver` 第 5 路 |
| `parses` webview | 播放页能在 WKWebView 里跑通并自己发包 | `ParseWebView.swift` |
| `parses` json | 接口回 JSON 且字段里有媒体地址 | `PlayResolver.jsonParse` |

### 不可执行

| 类型 | 原因 | 实测证据 |
|---|---|---|
| 纯 dex jar | 需 ART 解释执行 | `top98.jar` 612 类 / 4403 方法引用 / 142 个 `java.*` 外部类型 / 依赖 okhttp3 + rxhttp + javax.net.ssl |
| pyc 脚本 | 需 CPython 3.8 运行时 | Chaquopy 打包，`app.imy` 内是 `base/spider.pyc` 等，magic 锁死 3.8；依赖 lxml / pyquery / pycryptodome |
| 加固包（`csp_*Guard`） | 三层：OLLVM 混淆 so → 日期密钥解密 → InMemoryDexClassLoader | `wexshinidie.guard` 946 KB 熵 7.993；143 个空壳类；真代码由 `wexguard_v8.so` 运行期解开 |

如果将来要做 Python：等价代价是 CPython 静态链约 3 MB + stdlib 4.5 MB + lxml 1.8 MB + Crypto 0.4 MB，ipa 增量 9–11 MB，工期 3–5 周。jar 通用支持要 3–6 人月且不收敛（每个 jar 都要重做），投入产出最差。

---

## 9. 常见改动怎么做

### 加一个站点引擎

1. `JarScript.ScriptResolver.resolve`（`JarScript.swift:29`）里插一路，位置在"内置解释器兜底"之前
2. 新引擎写成独立 `enum`，入口签名统一：`static func load(site:apiURL:base:) async -> (Result?, [String])`，第二个返回值是诊断 notes
3. `Models.Site.routeLabel`（`Models.swift:231`）加分支，让诊断面板能显示
4. 加 `tests/xxx.test.js`，在 `.github/workflows/ios.yml` 的 for 循环里点名
5. `python3 tools/check.py` + 全部单测

### 加一个脚本镜像

`Mirrors.swift:35` 的 `candidates(for:)` 里追加一段。注意最多个数限制（现在是 8）和单次超时（8s），加太多会拖慢首次加载。

### 改 JS 桥的语义

三处必须同步改，改漏一处就是"测试全过、真机全挂"：

1. `JSSpider.swift:562-621`（`queryH` / `queryA` / `isAttrLike`）
2. `tests/drpy_lite.test.js` 顶部的模拟实现（`walk` / `isAttr`）
3. `Resources/drpy_lite.js` 里调用方的期望

### 改播放链路

`PlayResolver.resolve`（`PlayResolver.swift:56`）返回 `Plan`，里面带 `url` 和 `headers`。任何新增的取流方式（parses、嗅探、直链）都在这里收口，不要往 `PlayerView` 里塞。`PlayerView` 只负责"拿到 URL + headers 之后播放"。

---

## 10. 排障对照

| 症状 | 先看什么 | 常见原因 |
|---|---|---|
| 配置导入后站点全空 | 配置页 `lastErrorDetail` | 顶层是 `{urls:[...]}` 多仓；或所有站点 api/ext 都为空 |
| 站点列表有，但全标"jar 内置" | `SpiderView` 的诊断 | 顶层 spider 没加载成功，站点全都落到兜底 |
| `spider 不是 http 地址` | `URLKit.resolve` | 相对路径没按 `configBase` 解析 |
| 站点报 401 | 诊断里的镜像信息 | 整站鉴权，换镜像也拿不到 |
| 脚本跑了但没分类 | `class_parse` 的四段 | 正则捕获组没取到，或父选择器是 `body&&` 前缀 |
| 分类有了但条目空 | `__httpNote(url)` | 非 2xx 正文被当页面解析 |
| 播放黑屏 | 15 秒后看门狗的文案 | m3u8 里 `URI="..."` 没重写；或 Referer 没注入 |
| 直接闪退 | 是否绕过了 `JSSpider.run` | JSContext 并发访问 |
| `parses` 站点等到 15 秒然后报"嗅探失败" | 播放器 notes 里的嗅探段 | 播放页要登录/点播放；站点走 MSE；`alpha` 被改成 0 导致 WebKit 降频 |
| 所有 `parses` webview 站点都失败 | bundle 里有没有 `parse_sniff.js` | 资源没打进包，notes 会直说 |
| 嗅探到了地址但播放 403 | `ParseAttempt.headers` | 流认播放页 Referer，不是站点根 |
| CI 报 `MODULE_NOT_FOUND` | workflow 的测试步骤 | 有人把逐文件点名改回 glob |
| CI 报 `exit code 65` | artifact 里的 `build.log` | 下载 `TVBox-build-log`，`error:` 行已经在日志里打出来了 |
| CI 报 `future Xcode project file format (77)` | workflow 选 Xcode 那步 | 镜像默认 Xcode < 16，被 `xcode-select` 切到旧版 |
| CI 1 秒内 `cancelled`、job 的 `steps` 是 0、`runner_name` 为空 | `runs-on` 的镜像标签 | 该镜像已下线（`macos-14` 就是这样），换 `macos-15`。用一条 `ubuntu-latest` job 对照可排除额度问题 |

---

## 11. 未完成 / 下一步

按优先级：

1. **加固包（`csp_*Guard`）** — 静态路径走不通。脚本已进仓库：`tools/frida_dump_wex.js`（hook `DexClassLoader.$init` / `InMemoryDexClassLoader.$init` + 可读区扫 `dex\n035` + `FileOutputStream.write` 兜底）。需要一台 Android 8+ arm64（壳里有 `wexguard_v8.so`，只编了 arm64/arm32），跑起来后拿真 dex → `jadx` 反编译 → 接口改写成 drpy 规则。**一次 dump 覆盖同一壳下全部站点**，但只对那个壳有效。步骤见 `tools/frida_dump_wex.js` 头部注释。
2. **纯 dex jar** — 只有两条路：反编译重写成 Swift（每个 jar 线性成本），或远程执行（Android 盒子 + HTTP 转发，离线不可用）。

   改写的第一个动作是搞清楚"这个 csp_ 类请求了哪些地址"，`tools/dex_scan.py` 就是干这个的：

   ```bash
   python tools/dex_scan.py spider.jar --site Spider       # 只看某个站点类
   python tools/dex_scan.py spider.jar --all --site GM     # 不过滤，原样吐字符串
   ```

   实测一个 4.6 MB / 4467 类的 spider.jar：站点实现类都只有几十条字符串的薄壳，
   真正逻辑在 `com.github.catvod.parser.merge.*` 那一堆单字母混淆类里，
   域名在运行期拼装（包内 `ShA1sUm.dat` 也有嫌疑）。**对这种包扫字符串出不来接口**，
   得 jadx 跟调用链，或者真机 frida hook 网络层抓真实请求：

   ```bash
   adb push tools/frida_hook_http.js /data/local/tmp/
   frida -U -f com.fongmi.android.tv -l /data/local/tmp/frida_hook_http.js --no-pause
   # 在 App 里点开目标站点，进分类、进详情、点播放，各触发一次
   adb pull /data/local/tmp/httpdump.log
   ```

   hook 的是 `okhttp3.Request$Builder.build`（URL/header/body）和 `Response.body()`
   （JSON/XML 前 800 字）。jar 站点天天改版，抓包比静态逆向快一个数量级。
3. **Python 站点** — 需要 CPython 3.8 静态交叉编译到 arm64-apple-ios，工作量 3–5 周。TVBox 的 python 站点能热更新，做一次之后成本归零，是长期最优但短期最贵。
4. **直播** — 配置里 `lives` 是明文的，播放器已能播 m3u；EPG 还没接。
5. **`parses` 解析器** — 已做（build 10）：type 0 走 webview 嗅探，type 1 走 json 接口，见 4.9。还没覆盖的：
   - 需要登录或点"播放"按钮才开始发包的播放页（现在直接加载就等，没模拟交互）
   - `blob:` / MSE 取流站点（拦到了也是 blob 地址，没有直链可给 AVPlayer）
   - 解析页在 iframe 里且与主 frame 跨域时，只靠本地兜底 `__tbSniffDump` 取数，命中率不如主 frame

---

## 12. 相关分析材料（在仓库外 `_work/`）

| 文件 | 内容 |
|---|---|
| `wex-guard-analysis.md` | 加固包静态还原全过程：ELF 段表、`init_array`、密钥派生、native 注册表 |
| `guard-report.md` | 第一轮加固壳分析（dex 结构、熵值、符号） |
| `dump_guard.js` | frida 脚本：hook InMemoryDexClassLoader，匿名内存扫 `dex\n035` |
| `dump_wex_dex.js` | frida 脚本：hook FileOutputStream / DexClassLoader，落盘 dex |
| `emu_wex.py` | unicorn 加载 ELF + 重定位 + 跑 `init_array[0]`，还原 `.data` |
| `jni_wex.py` | 伪造 JavaVM 表跑 `JNI_OnLoad`，抓 RegisterNatives |
| `decrypt_wex.py` | mini-JVM：虚拟化 FileInputStream/OutputStream、DexClassLoader |
| `pyc38.py`（在 `tools/`） | Python 3.8 pyc 解析器，文件头记着三个格式坑 |

这些不进 app，也不进 CI 包。要继续解加固包就从 `dump_wex_dex.js` 开始。
