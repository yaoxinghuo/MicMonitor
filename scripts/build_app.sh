#!/bin/bash
# 不使用 Xcode 组装 MicMonitor.app:
#   SwiftPM 构建通用二进制 → 手动搭 .app 结构 → ad-hoc 签名 → ditto 打包 zip
set -euo pipefail
cd "$(dirname "$0")/.."

APP="MicMonitor"

# 版本号:git 标签 v1.2.3 → 1.2.3;否则 1.0.0。构建号默认取 CI run number。
VERSION="${VERSION:-}"
if [[ -z "$VERSION" ]]; then
    TAG="${GITHUB_REF_NAME:-}"
    if [[ "$TAG" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        VERSION="${TAG#v}"
    else
        VERSION="1.0.0"
    fi
fi
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"

# 分架构各编一次再 lipo 合成,而不是 `swift build --arch a --arch b`:
# 后者需要 xcbuild(只在装了 Xcode 的机器上有),前者纯 SwiftPM 即可
echo "==> swift build -c release --arch arm64"
swift build -c release --arch arm64
echo "==> swift build -c release --arch x86_64"
swift build -c release --arch x86_64

BIN_ARM=".build/arm64-apple-macosx/release/$APP"
BIN_X86=".build/x86_64-apple-macosx/release/$APP"
# 兜底:不同 SwiftPM 版本的产物目录名可能有差异
[[ -f "$BIN_ARM" ]] || BIN_ARM="$(find .build -path '*arm64*release*/'"$APP" -type f | head -n1)"
[[ -f "$BIN_X86" ]] || BIN_X86="$(find .build -path '*x86_64*release*/'"$APP" -type f | head -n1)"
[[ -n "$BIN_ARM" && -f "$BIN_ARM" ]] || { echo "错误:找不到 arm64 产物"; exit 1; }
[[ -n "$BIN_X86" && -f "$BIN_X86" ]] || { echo "错误:找不到 x86_64 产物"; exit 1; }

BIN=".build/$APP-universal"
lipo -create "$BIN_ARM" "$BIN_X86" -output "$BIN"
echo "==> 通用二进制:$BIN"
lipo -info "$BIN"
lipo -info "$BIN" | grep -q arm64   || { echo "错误:缺少 arm64"; exit 1; }
lipo -info "$BIN" | grep -q x86_64 || { echo "错误:缺少 x86_64"; exit 1; }

echo "==> 组装 $APP.app(version $VERSION build $BUILD_NUMBER)"
rm -rf "$APP.app" "$APP.zip"
mkdir -p "$APP.app/Contents/MacOS" "$APP.app/Contents/Resources"
cp "$BIN" "$APP.app/Contents/MacOS/$APP"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" \
    Resources/Info.plist > "$APP.app/Contents/Info.plist"
printf 'APPL????' > "$APP.app/Contents/PkgInfo"

# 从单张 1024x1024 PNG 生成 iconset 并编译成 icns(sips/iconutil 均为系统自带,无需 Xcode)
if [[ -f Resources/AppIcon.png ]]; then
    echo "==> 生成 AppIcon.icns"
    ICONSET=".build/AppIcon.iconset"
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"
    for spec in 16 32 128 256 512; do
        sips -z "$spec" "$spec" Resources/AppIcon.png \
            --out "$ICONSET/icon_${spec}x${spec}.png" >/dev/null
        dbl=$((spec * 2))
        sips -z "$dbl" "$dbl" Resources/AppIcon.png \
            --out "$ICONSET/icon_${spec}x${spec}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP.app/Contents/Resources/AppIcon.icns"
fi

echo "==> 校验 Info.plist"
plutil -lint "$APP.app/Contents/Info.plist"

echo "==> ad-hoc 签名(无沙盒、无 Hardened Runtime)"
codesign --force --deep --sign - "$APP.app"
codesign --verify --deep --strict --verbose=2 "$APP.app"
spctl --assess --type execute "$APP.app" 2>/dev/null || true  # ad-hoc 必然不过 Gatekeeper,仅记录

echo "==> 打包 $APP.zip"
ditto -c -k --keepParent "$APP.app" "$APP.zip"
ls -lh "$APP.zip"
echo "==> 完成:$APP.zip"
