# tvbox-ios

把 `tvbox-java32.apk.1` 的能力在 iOS 上重实现，产出 `.ipa`。

## 一、为什么不是"转换"

对包体做了拆解：

| 项目 | 实测结果 |
|---|---|
| 包名 / 版本 | `com.github.tvbox.osc.jun` / `20260914-1520` |
| 体积 | 19 MB |
| 字节码 | `classes.dex` 9.5 MB + `classes2.dex` 2.9 MB（Dalvik） |
| 语言 | Java + Kotlin（含 `kotlin/` 标准库） |
| 原生库 | 仅 `armeabi-v7a`，11 个 `.so`：`libijkffmpeg` `libijksdl` `libplayer` `libcronet` `libquickjs-android-wrapper` `libxl_thunder_sdk` `libp2p` `librtmp-jni` `libconceal` `libffmpegJNI` `libxl_stat` |
| 跨平台框架 | 无 Flutter / RN / Unity / Cordova（DEX 符号逐个查过） |
| JS 层 | `assets/js/lib/cat.js`（486 KB，含 cheerio）+ `res/*.js`，走 QuickJS |

两条硬阻断：dex 是 Dalvik 指令集，要 ART 运行时；iOS 只有 arm64 Mach-O。那 11 个 `.so` 是 NDK 产物（Bionic + JNI + armv7），iOS 要 libSystem + arm64 且禁 JIT。跟签名、加固都无关，是执行模型不同。

**但内容与壳是分离的**——包内没硬编码任何接口域名（只有 `epg.51zmt.top` 和一个 crosswalk 的 maven 源），片源全在用户自己填的配置地址里。所以 iOS 端只要实现同一套协议，播的是同一批源。

## 二、工程结构

```
tvbox-ios/
├── project.yml                 XcodeGen 描述（SwiftSoup + ZIPFoundation）
├── Podfile                     MobileVLCKit（可选，装了解码 mkv）
├── Info.plist                  ATS 放开 / 本地网络 / 后台音频
├── build.sh                    一键 archive → ipa
├── tools/
│   ├── check.py                静态校验（词法配对 / plist / 路径 / 占位符）
│   └── make_icon.py            生成 1024 图标（纯标准库）
├── Assets.xcassets/            图标
├── Resources/
│   ├── cat.js                  从 APK 抽出的 JS 库，原样复用
│   ├── cheerio.min.js
│   └── crypto-js.js
└── Sources/  (12 个文件，约 2100 行)
    ├── App.swift               @main + 首启配置页
    ├── Models.swift            配置/内容模型，$$$ 与 # 播放链解析
    ├── Net.swift               UA 伪装 / 重试 / GB18030 / 证书直通
    ├── Api.swift               CMS 接口 ac=list|videolist|detail|wd
    ├── JSSpider.swift          JavaScriptCore + pdfh/pdfa 原生桥
    ├── JarScript.swift         jar 内抽 js（spider 替代方案）
    ├── Store.swift             配置持久化 / 收藏 / 历史
    ├── HomeView.swift          站点切换 + 分类 + 瀑布流 + 分页
    ├── DetailView.swift        详情 + 线路 + 选集
    ├── PlayerView.swift        AVPlayer ↔ VLCKit 双内核 + AirPlay
    ├── SpiderView.swift        spider 站点宿主
    └── Extras.swift            搜索 / 收藏 / 历史
```

## 三、替代方案对照

原版依赖的四个东西在 iOS 上都没有直接对应，逐个给了替代：

| 原版能力 | 原实现 | iOS 替代 |
|---|---|---|
| 全格式播放 | ijkplayer（ffmpeg） | AVPlayer 打头，`.failed` 自动切 MobileVLCKit 重开；未装 pod 时给出明确提示并提供"用 VLC 重试"按钮 |
| DLNA 投屏 | `DLNACastService` | `AVRoutePickerView`（AirPlay / 隔空播放），播放页右上角 |
| JAR spider | DexClassLoader 动态加载 | 下载 jar → ZIPFoundation 解包 → 按 TVBox 契约打分（`homeContent`/`categoryContent`/`var rule`…）挑出内置 js → 丢进 JavaScriptCore 跑。jar 里没有 js 时报明原因 |
| P2P / 迅雷 | `libxl_thunder_sdk` | 无对应 SDK，直接走源站 http(s) 直链；P2P 链接不支持 |

## 四、编译

需要 macOS + Xcode 15 及以上。

```bash
brew install xcodegen
cd tvbox-ios && chmod +x build.sh

./build.sh                   # 无签名 ipa
TEAM=你的TeamID ./build.sh    # 带开发者签名
VLC=1 ./build.sh             # 额外 pod install 接入 MobileVLCKit（能播 mkv/avi/rmvb）
```

产物：`build/TVBox.ipa`

纯 Xcode 流程：

```bash
xcodegen generate && open TVBox.xcodeproj
# Product > Archive > Distribute App
```

Windows / Linux 上只能跑静态校验，出不了 ipa（没有 Mach-O 工具链）：

```bash
python tools/check.py      # 词法配对、plist、依赖路径、占位符
python tools/make_icon.py  # 重新生成图标
```

### 没有 Mac

本地仓库已初始化，`main` 分支 2 个 commit。只差一个远端：

```bash
git remote add origin https://github.com/你的用户名/tvbox-ios.git
git push -u origin main
```

push 完 Actions 自动跑 `build-ipa`（`macos-14`），6～9 分钟出结果，Artifacts 下载 `TVBox-unsigned-ipa.zip`，解压即 `TVBox.ipa`。

连不上 GitHub 的情况、认证、失败日志对照、Codemagic 备用方案，全在 **[CI.md](CI.md)**。

## 五、使用

1. 首启填配置地址（原来在 Android 盒子上用的那个）。
2. 也支持粘贴 JSON 文本、Base64、`{"urls":[...]}` 多仓。
3. 左上切站点，右上 搜索 / 收藏 / 设置。
4. 载入失败时，配置页底部会留下一块「上次失败原因」，逐条列出每种 UA 的返回码和响应开头。长按可复制。

### 配置兼容性

接受的形态，按顺序尝试：

| 形态 | 说明 |
|---|---|
| 标准 TVBox JSON | `sites` / `lives` / `parses` / `flags` / `spider` |
| JSON5 | 带 `//`、`/* */` 注释和尾部多余逗号的也能过 |
| 顶层是站点数组 | `[{...},{...}]` 直接当 sites |
| `urls` 多仓 | 依次试每个子仓，取第一个有站点的，全失败则列出每个子仓的结果 |
| 整体 Base64 | 响应本身是 base64 的配置文件 |
| 本地粘贴 | 直接把 JSON 文本贴进输入框，不联网 |

解析侧全部容错，不会因为某一条坏数据整份报废：

- 站点缺 `key` / `name` 时按可用字段兜底，都不给就生成唯一 key
- `type` 写成字符串 `"1"` 也能读；缺失时按 `api` 特征推断（含 `csp_` → spider）
- `api` 为空但 `ext` 有内容的站点保留，按 spider 处理
- 单个站点解码失败只跳过它，其余照常加载
- 重复 `key` 自动去重，避免列表 id 冲突

请求侧：

- 依次用 4 种 UA 尝试（iPhone Safari / okhttp / Dalvik / 桌面 Chrome），谁能拿到 JSON 就用谁，很多源站只放行其中一种
- ATS 全放开，`http://` 源站也能直连
- 返回 HTML 时会明确提示「源站拦了请求」，而不是笼统报解析失败

## 六、格式与站点支持

| 容器 | 无 VLCKit | 装 VLCKit |
|---|---|---|
| HLS (m3u8) | ✅ | ✅ |
| MP4 / MOV | ✅ | ✅ |
| MKV / AVI / RMVB / TS | ❌ 提示并给重试按钮 | ✅ 自动切换 |

| 站点类型 | 支持 |
|---|---|
| `0/1` CMS 接口 | ✅ 分类 / 列表 / 详情 / 搜索 / 播放 |
| `3/4` js spider | ✅ JavaScriptCore |
| `3/4` jar spider | ⚠️ jar 内含 js 则可用，纯 dex 不行 |

### 站点加载链路

配置顶层的 `spider` 字段现在会真正被使用。TVBox 的真实结构是：

```json
{
  "spider": "https://x/spider.jar;md5;abc123",
  "sites": [
    {"key":"csp_abc","name":"某站","type":3,"api":"csp_abc"},
    {"key":"cms1","name":"某 CMS","type":1,"api":"https://x/api.php/provide/vod/"}
  ]
}
```

`type 3` 站点的 `api` 是 `csp_abc` 这种标识符，不是地址 —— 脚本来自顶层 `spider`，
不加载它就一个都跑不起来。现在的顺序是：

1. 站点 api 本身是 `.js` / `.jar` → 用它
2. 否则用顶层 `spider`（`.js` 直接跑；`.jar` 先解包抽 js，优先文件名匹配站点 key 的）
3. 再否则用内置 `Resources/spider.js`（把脚本放进去就生效）

地址后面的 `;md5;` `;pk;` 等校验后缀会先剥掉再请求。
`key`、`ext`、`host`、`__key__`、`__ext__` 会注入 JS 全局，供 `eval(key)` 这类分派方式使用。

### 页面左上角的下拉里，站点名后面带类型

| 标注 | 含义 |
|---|---|
| `CMS` | 直接走接口，基本都能用 |
| `js 脚本` | api 指向 js 文件 |
| `jar 脚本` | api 指向 jar，内含 js 才可用 |
| `jar 内置` | api 是 `csp_xxx`，脚本在顶层 jar 里；纯 dex 的 jar 不可用 |

CMS 站会自动排在前面并被默认选中。

### 跑不起来时

页面会给出可复制的诊断，包含：spider 的下载结果、jar 内文件清单、
站点 api / key / ext、脚本定义了哪些函数（`homeContent` / `rule` / `class_parse`…）。

看到「没有 js；含 N 个 dex 字节码」就是遇到了硬限制：
dex 需要 Android ART，iOS 没有对应运行时，换 CMS 站或 js spider 站才能用。

## 七、安装到 iPhone

| 方式 | 有效期 | 条件 |
|---|---|---|
| Xcode 直连真机 | 7 天 | 免费 Apple ID |
| Sideloadly / AltStore | 7 天（免费）/ 1 年（付费） | Windows 也可操作 |
| Ad Hoc | 设备绑定 1 年 | 付费开发者账号 |
| TestFlight | 90 天 | 付费开发者 + 审核 |

无签名 ipa 需重新签名，Sideloadly 会自动做。

## 八、验收

```bash
python tools/check.py
# 期望：OK 结构检查通过

unzip -l build/TVBox.ipa | head
# 期望：Payload/TVBox.app/TVBox、Info.plist、cat.js、icon-1024.png

plutil -p build/TVBox.xcarchive/Products/Applications/TVBox.app/Info.plist \
  | grep -E "CFBundleIdentifier|MinimumOSVersion"
# 期望：osc.tvbox.jun / 15.0
```

运行后三关：出分类列表 = `Api.swift` 通；有选集 = `Models.swift:playLines` 通；起画面 = `PlayerView.swift` 通。
