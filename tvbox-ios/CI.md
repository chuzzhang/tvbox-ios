# 走 CI 出 ipa

本机是 Windows，没有 Xcode。CI 的作用是借一台 macOS 编译，产物直接从网页下载。

仓库已经在本地建好（`main` 分支，2 个 commit），只差一个远端。

---

## 一、先在 GitHub 建仓库

浏览器打开 https://github.com/new

| 字段 | 填什么 |
|---|---|
| Repository name | `tvbox-ios` |
| Visibility | **Public**（见下方计费说明） |
| Initialize with README | **不要勾**（勾了会和本地历史冲突） |
| .gitignore / license | 都选 None |

建完页面会给你一个地址，形如：

```
https://github.com/你的用户名/tvbox-ios.git
```

---

## 二、推上去

### 情况 A：这台机器能连 GitHub

```bash
cd "C:/Users/Administrator/WorkBuddy/2026-11-05-08-41-24"

git remote add origin https://github.com/你的用户名/tvbox-ios.git
git push -u origin main
```

首次 push 会弹登录。密码位置填 **Personal Access Token**，不是账号密码。
生成地址：https://github.com/settings/tokens → Generate new token (classic) → 勾 `repo` → 复制 `ghp_...` 那串。

用了 token 还是 403，多半是本机代理没放行 github.com，先验一下：

```bash
curl -s -m 10 -o /dev/null -w "%{http_code}\n" https://github.com
# 200 才算通，000 是没连上
```

### 情况 B：这台机器连不上（当前就是这情况）

DNS 解析超时，github.com 直连和走代理都是 `000`。那就换一台设备，或者用网页上传。

**B-1 换设备推**（最省事）

把 `dist/tvbox.bundle` 拷到任何一台有 git、能上网的机器：

```bash
git clone tvbox.bundle tvbox-ios
cd tvbox-ios
git remote set-url origin https://github.com/你的用户名/tvbox-ios.git
git push -u origin main
```

bundle 里带着完整提交历史，clone 出来就是原样的仓库。

**B-2 纯网页操作**

1. 本地解压 `dist/tvbox-ios-src.zip`
2. GitHub 仓库页 → **Add file** → **Upload files**
3. 把解压出来的 `tvbox-ios` 文件夹和 `.github` 文件夹一起拖进上传框

注意：`.github` 是隐藏目录，Windows 资源管理器默认不显示。先开「查看 → 隐藏的项目」，或者用命令行把 `.github` 单独拖进去。少了它就没有 workflow，等于白传。

**B-3 GitHub Desktop**

装 https://desktop.github.com ，File → Add local repository 指向
`C:/Users/Administrator/WorkBuddy/2026-11-05-08-41-24`，然后 Publish repository。
它会自己处理认证和上传。

---

## 三、看构建

推送成功后：

1. 仓库页顶部 **Actions** 标签
2. 左侧 `build-ipa`
3. 最新一条 run，点进去

不推送也想跑：Actions → build-ipa → 右侧 **Run workflow** → 选 `main` → Run。

一次跑 6～9 分钟，主要时间在 `brew install xcodegen` 和 SPM 拉依赖。

成功的话底部 **Artifacts** 里有个 `TVBox-unsigned-ipa.zip`，下载解压就是 `TVBox.ipa`。

---

## 四、workflow 干了什么

`.github/workflows/ios.yml`，跑在 GitHub 提供的 `macos-15`（Apple Silicon）上：

| 步骤 | 命令 | 作用 |
|---|---|---|
| 选 Xcode | `xcodebuild -version` | 打印版本，便于对日志 |
| 装 XcodeGen | `brew install xcodegen` | `project.yml` → `TVBox.xcodeproj` |
| 静态校验 | `python3 tools/check.py` | 括号配对、路径、占位符，错了提前停 |
| 生成工程 | `xcodegen generate` | 出 `.xcodeproj` |
| 解析依赖 | `xcodebuild -resolvePackageDependencies` | 拉 SwiftSoup / ZIPFoundation |
| Archive | `xcodebuild archive` | `CODE_SIGNING_ALLOWED=NO`，不打签名 |
| 打包 | `zip -qry TVBox.ipa Payload` | 手工组 `Payload/` 再压缩 |
| 上传 | `actions/upload-artifact@v4` | 产物随 run 保存 90 天 |

无签名 ipa 不能直接双击装，要 Sideloadly / AltStore 自签。免费 Apple ID 签出来的有效期 7 天，到期重签，App 和数据都在。

---

## 五、计费

| 仓库类型 | macOS 额度 |
|---|---|
| Public | 不限量，免费 |
| Private | 月 2000 分钟额度，macOS **按 10 倍扣**，实际 200 分钟 ≈ 25 次构建 |

代码里没有密钥，设 Public 更划算。介意公开就设 Private，一个月也能跑二十来次。

---

## 六、构建失败了怎么改

点进失败的 run，展开红色那一步看日志最后 30 行。常见的几种：

**`xcodegen: command not found`**
`brew install xcodegen` 这步挂了，多半是 Homebrew 源抽风。重跑一次即可。

**`xcodebuild: error: The project does not contain a scheme named "TVBox"`**
`project.yml` 里 `schemes:` 段丢了。它必须和 `targets:` 同级，缩进两个空格：

```yaml
schemes:
  TVBox:
    build:
      targets:
        TVBox: all
```

**`The project 'TVBox' cannot be opened because it is in a future Xcode project file format (77)`**

XcodeGen 新版按 Xcode 16 的格式写 `project.pbxproj`（`objectVersion 77`），而镜像默认的 `xcode-select` 不一定指向装着的那个最新版本，读不了 77 就报这个。`macos-15` 镜像里现在最新正式版是 Xcode 26.3。

workflow 的「选择 Xcode」步骤会自动取镜像里最新的正式版，关键在于**先切再生成**：

```bash
LATEST=$(ls -d /Applications/Xcode_*.app 2>/dev/null \
  | grep -vi 'beta' | grep -vi 'GM' | grep -vi 'Release Candidate' \
  | sort -V | tail -1)
sudo xcode-select -s "$LATEST"
xcodebuild -version
```

`sort -V` 按版本号排，`tail -1` 拿最大的。排除 beta/GM 是因为那些版本可能在镜像里但默认不可用。

如果镜像里最高只有 15.x，那就反过来降 XcodeGen 的版本（旧版写 `objectVersion 46`，15.x 就能读）：

```bash
curl -sL -o /tmp/xcodegen.zip \
  https://github.com/yonaskolb/XcodeGen/releases/download/2.38.0/xcodegen.zip
unzip -q /tmp/xcodegen.zip -d /tmp/xg
sudo cp /tmp/xg/xcodegen/bin/xcodegen /usr/local/bin/
xcodegen --version
```

**`Failed to clone repository ... SwiftSoup`**
SPM 拉 GitHub 超时。重跑；连续失败就在 `project.yml` 里换镜像源，或者把依赖下成本地包。

**`error: An empty identity is not valid when signing a binary`**
archive 少了 `CODE_SIGNING_ALLOWED=NO`。检查这一步的三个签名参数是不是都还在。

**`No such file or directory: build/TVBox.xcarchive/Products/Applications/TVBox.app`**
archive 其实失败了，日志往上翻找真正的报错，别只盯着打包这步。

**`Archive Error: Process completed with exit code 65`**

65 是 `xcodebuild` 的通用失败码：编译错误、链接错误、签名错误都会落到它，本身不带信息。

现在 workflow 的 archive 步骤把全部输出重定向到 `tvbox-ios/build.log`，失败时在日志里单独打印三段：

```
xcodebuild 退出码：65
================ 编译错误 ================
TVBox/xxx.swift:42:12: error: value of optional type 'JSValue?' must be unwrapped ...
================ 失败原因 ================
================ 日志尾部 50 行 ================
** ARCHIVE FAILED **
```

只看带 `error:` 的那几行就够。同一份日志也作为 `TVBox-build-log` 附件上传，`xcresult` 一起在里面。

定位对照：

| 日志特征 | 含义 |
|---|---|
| `TVBox/xxx.swift:N:M: error:` | Swift 类型/语法错误，改那一行 |
| `Undefined symbols for architecture arm64` | 链接缺库，检查 `OTHER_LDFLAGS` 或依赖是否编译进来 |
| `error: No such module 'SwiftSoup'` | SPM 没解析成功，重跑「解析依赖」 |
| `error: An empty identity is not valid` | 签名参数丢了 |
| `** ARCHIVE FAILED **` 但没有任何 `error:` | 看尾部 50 行的 `xcodebuild: error:` 或 `note:` 行 |

**`initializer for conditional binding must have Optional type, not 'String'`**

`try?` 从 Swift 5 起会做扁平化：`try? expr` 里 `expr` 本来是 `String?`，结果仍是 `String?`，`if let d = try? ...` 绑出来的 `d` 就是 **`String`**。再写一次 `let v = d` 就是对非可选值条件绑定。

```swift
// 错
if let d = try? c.decodeIfPresent(String.self, forKey: k), let v = d, !v.isEmpty { }
// 对
if let v = try? c.decodeIfPresent(String.self, forKey: k), !v.isEmpty { }
```

注意区分：`try?` 作用在**返回非可选**的 throwing 函数上时（如 `c.decode(T.self)`），结果才是真正的 `T?`；只有原返回类型本身是 Optional，才会出现这个坑。

**Swift 编译报错** — 这类是真问题，本机没有 Swift 工具链验证不了类型。修过的几处（`JSValue(undefinedIn:)` 是可失败构造、`UIView.layerClass` 要用 `class` 不能用 `static`、`ForEach` 元素是元组时不能拆成两个闭包参数、`try?` 扁平化后不能再二次绑定）都属于这一层，说明确实只有 CI 能兜住类型检查。

---

## 七、不想用 GitHub

`codemagic.yaml` 已经写好在仓库根。https://codemagic.io 注册，连仓库或直接上传源码 zip，选 `ios-unsigned` 这个 workflow 就能跑，免费额度 500 分钟/月 macOS。

区别：Codemagic 不用管分支名和仓库可见性，但注册要绑邮箱，界面全英文。
