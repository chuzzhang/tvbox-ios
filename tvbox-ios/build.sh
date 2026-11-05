#!/usr/bin/env bash
# 在 macOS 上把工程编译成 .ipa
# 用法：
#   ./build.sh                    # 无签名 ipa（自签 / AltStore / Sideloadly 用）
#   TEAM=ABCDE12345 ./build.sh    # 带开发者团队签名
#   VLC=1 ./build.sh              # 额外 pod install 接入 MobileVLCKit
set -euo pipefail

cd "$(dirname "$0")"

SCHEME="TVBox"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/TVBox.xcarchive"
IPA="$BUILD_DIR/TVBox.ipa"
PROJ="TVBox.xcodeproj"

step() { echo; echo "==> $*"; }

step "1/6 检查工具链"
command -v xcodebuild >/dev/null || { echo "缺少 xcodebuild，需安装 Xcode 15+"; exit 1; }
command -v xcodegen  >/dev/null || { echo "缺少 xcodegen：brew install xcodegen"; exit 1; }
command -v plutil    >/dev/null || { echo "缺少 plutil（Xcode 命令行工具）"; exit 1; }

step "2/6 校验源码结构"
command -v python3 >/dev/null || { echo "缺少 python3"; exit 1; }
python3 tools/check.py

step "3/6 生成 Xcode 工程"
xcodegen generate --spec project.yml

step "4/6 解析依赖"
if [ "${VLC:-0}" = "1" ] && [ -f Podfile ]; then
  command -v pod >/dev/null || { echo "缺少 CocoaPods：sudo gem install cocoapods"; exit 1; }
  pod install --repo-update
  BUILD_TARGET="-workspace TVBox.xcworkspace"
else
  BUILD_TARGET="-project $PROJ"
fi
xcodebuild -resolvePackageDependencies $BUILD_TARGET -scheme "$SCHEME"

step "5/6 Archive"
rm -rf "$ARCHIVE" "$IPA" "$BUILD_DIR/Payload"
if [ -n "${TEAM:-}" ]; then
  xcodebuild archive $BUILD_TARGET \
    -scheme "$SCHEME" \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    DEVELOPMENT_TEAM="$TEAM" \
    CODE_SIGN_STYLE=Automatic \
    -allowProvisioningUpdates
else
  xcodebuild archive $BUILD_TARGET \
    -scheme "$SCHEME" \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY=""
fi

step "6/6 打包 ipa"
APP="$ARCHIVE/Products/Applications/$SCHEME.app"
[ -d "$APP" ] || { echo "没找到 $APP"; exit 1; }

mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP" "$BUILD_DIR/Payload/"
rm -rf "$BUILD_DIR/Payload/$SCHEME.app/_CodeSignature"

(cd "$BUILD_DIR" && /usr/bin/zip -qry "$(basename "$IPA")" Payload)

echo
echo "完成：$(pwd)/$IPA"
ls -lh "$IPA"
echo
plutil -p "$APP/Info.plist" | grep -E "CFBundleIdentifier|MinimumOSVersion" || true
echo
echo "安装："
echo "  自签    Sideloadly / AltStore 拖入 ipa（免费账号 7 天，付费账号 1 年）"
echo "  签名版  带 TEAM 时产物已含描述文件，Xcode > Devices 可直接装"
