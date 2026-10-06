#!/usr/bin/env bash
#
# 把 SwiftPM 产物组装成 .app bundle 并签名。
#
# 为什么需要这一步：本机只有 Command Line Tools、没有完整 Xcode，
# 所以不能用 .xcodeproj/xcodebuild。而辅助功能权限（TCC）认的是
# **进程身份**（bundle id + 签名），裸二进制没有稳定身份，
# 授权会莫名其妙失效——所以必须包成一个签名的 .app。
#
# 用法：
#   scripts/build-app.sh [debug|release]      # 默认 release
#
# 签名身份：优先用环境变量 CODESIGN_IDENTITY；否则用钥匙串里第一个
# 可用的 codesigning 身份；都没有则退化为 ad-hoc（-）。
# ad-hoc 的 cdhash 每次重构都会变，TCC 授权可能失效，需要重新授权
# 或用 tccutil 清掉旧记录。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP_NAME="Chord"
BUNDLE_ID="com.hiauhong.chord"
VERSION="0.1.0"
BUILD_NUMBER="1"

echo "==> 构建 ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT"

BIN_DIR="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
[ -x "$BIN" ] || { echo "找不到产物：$BIN" >&2; exit 1; }

APP="$ROOT/build/$APP_NAME.app"
echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>          <string>zh_CN</string>
    <key>CFBundleExecutable</key>                 <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>                 <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>      <string>6.0</string>
    <key>CFBundleName</key>                       <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>                <string>APPL</string>
    <key>CFBundleShortVersionString</key>         <string>$VERSION</string>
    <key>CFBundleVersion</key>                    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>             <string>13.0</string>
    <!-- 状态栏常驻 app，不在 Dock 里出现 -->
    <key>LSUIElement</key>                        <true/>
    <key>NSHighResolutionCapable</key>            <true/>
    <key>NSHumanReadableCopyright</key>           <string>MIT</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY="${CODESIGN_IDENTITY:-}"
IDENTITY_LABEL=""
if [ -z "$IDENTITY" ]; then
  # 用 SHA-1 哈希而不是证书名指定身份，因为：
  #   1) security 会把已吊销的身份一并列出（带 CSSMERR_TP_CERT_REVOKED）
  #   2) 同名证书可能同时存在多张，按名字指定会因为歧义被 codesign 拒绝
  # 只认「身份行」（形如 `  1) <40位SHA-1> "名字"`）。不能只靠 grep -v CSSMERR 后就 head -1：
  # 那会捞到尾部汇总行「N valid identities found」，awk $2 = valid → codesign 报 no identity found，
  # 且下面的 ad-hoc 回退永远不触发。
  IDENTITY_ROW="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-Fa-f]{40}[[:space:]]' \
    | grep -v CSSMERR \
    | head -1 || true)"
  IDENTITY="$(printf '%s' "$IDENTITY_ROW" | awk '{print $2}')"
  IDENTITY_LABEL="$(printf '%s' "$IDENTITY_ROW" | sed -n 's/.*"\(.*\)".*/\1/p')"
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY="-"
  echo "==> 签名：ad-hoc（钥匙串里没有 codesigning 身份）"
  echo "    注意：ad-hoc 的 cdhash 每次重构都会变，辅助功能授权可能失效。"
  echo "    要稳定授权，请在「钥匙串访问 → 证书助理 → 创建证书」造一张"
  echo "    「代码签名」证书，然后 CODESIGN_IDENTITY=\"它的名字\" 重新构建。"
else
  echo "==> 签名：${IDENTITY_LABEL:-$IDENTITY}"
  echo "    身份哈希：$IDENTITY"
fi

codesign --force --options runtime --timestamp=none \
         --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP" 2>&1 | sed 's/^/    /'

echo "==> 完成"
echo "    app        : $APP"
echo "    二进制自检 : \"$APP/Contents/MacOS/$APP_NAME\" --self-test"
echo "    图形自检   : open \"$APP\""
codesign -dv "$APP" 2>&1 | sed -n 's/^/    /p' | head -6
