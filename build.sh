#!/bin/bash
# Build Lumi.app without Xcode: SwiftPM -> .app bundle -> codesign.
set -euo pipefail

CONFIG="${1:-debug}"
APP_NAME="Lumi"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP="$ROOT/build/$APP_NAME.app"
# 签名身份不进仓库。优先 LUMI_IDENTITY，其次本地未跟踪的 .lumi-identity（一行）。
# 身份必须稳定：换了身份 TCC 会当成另一个 App，辅助功能 / 屏幕录制要重新授权。
# （把个人身份写进源码正是 scripts/security-scan.py 要拦的事。）
IDENTITY="${LUMI_IDENTITY:-}"
IDENTITY_FILE="$ROOT/.lumi-identity"
if [ -z "$IDENTITY" ] && [ -f "$IDENTITY_FILE" ]; then
    IDENTITY="$(head -n1 "$IDENTITY_FILE" | sed 's/[[:space:]]*$//')"
fi
if [ -z "$IDENTITY" ]; then
    cat >&2 <<'MSG'
▸ 没有签名身份，二选一：
    echo "Apple Development: 你的名字 (TEAMID)" > .lumi-identity   # 已被 .gitignore 忽略
    LUMI_IDENTITY="Apple Development: 你的名字 (TEAMID)" ./build.sh
  （LUMI_IDENTITY="-" 可做 ad-hoc 签名，仅够验证能编译，TCC 授权会失效。）
  查身份：security find-identity -v -p codesigning
MSG
    exit 1
fi

echo "▸ compiling ($CONFIG)"
swift build -c "$CONFIG" 2>&1 | grep -v "ld: warning: search path" || true

echo "▸ assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME"        "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist"  "$APP/Contents/Info.plist"
for res in "$ROOT/Resources/"*; do
    base="$(basename "$res")"
    [ "$base" = "Info.plist" ] && continue
    cp -R "$res" "$APP/Contents/Resources/"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

# SwiftPM emits a .bundle for resources; fold it in if present.
for b in "$BUILD_DIR"/*.bundle; do
    [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

# Safari only finds a web extension inside an app, as an appex. No Xcode here,
# so it is assembled by hand: swiftc for the tiny native relay, the web
# extension files copied in as its resources.
echo "▸ building Safari extension"
EXT_SRC="$ROOT/Extensions/Safari"
APPEX="$APP/Contents/PlugIns/LumiSafari.appex"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
SWIFT_OPT="-Onone"; [ "$CONFIG" = "release" ] && SWIFT_OPT="-O"
swiftc -parse-as-library -application-extension -swift-version 6 "$SWIFT_OPT" \
       -module-name LumiSafari -target "$(uname -m)-apple-macos26.0" \
       -framework SafariServices -Xlinker -e -Xlinker _NSExtensionMain \
       "$EXT_SRC/SafariWebExtensionHandler.swift" -o "$APPEX/Contents/MacOS/LumiSafari"
cp "$EXT_SRC/Info.plist" "$APPEX/Contents/Info.plist"
cp -R "$EXT_SRC/WebExtension/" "$APPEX/Contents/Resources/"

echo "▸ signing"
# Inside out, and never --deep: --deep would stamp the app's entitlements
# (no sandbox) onto the appex, and Safari refuses an unsandboxed extension.
codesign --force --options runtime \
         --entitlements "$EXT_SRC/Extension.entitlements" \
         --sign "$IDENTITY" "$APPEX" 2>&1 | sed 's/^/  /'
codesign --force --options runtime \
         --entitlements "$ROOT/$APP_NAME.entitlements" \
         --sign "$IDENTITY" "$APP" 2>&1 | sed 's/^/  /'

codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/  /'

# Tell LaunchServices about the new appex now, so Safari lists it without
# waiting for the app to be opened from Finder first.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "▸ built: $APP"
