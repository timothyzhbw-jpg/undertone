#!/bin/bash
# 构建 Undertone.app：release 编译 → 组装 .app → 签名。产物在 build/Undertone.app。
# 默认只编本机架构；UNIVERSAL=1 时同时编 Apple 芯片和 Intel（发布用，见 make_dmg.sh）。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.1.0"
BUILD="1"
APP="build/Undertone.app"

if [ "${UNIVERSAL:-0}" = 1 ]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN=".build/apple/Products/Release"
else
    swift build -c release
    BIN=".build/release"
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Undertone" "$APP/Contents/MacOS/Undertone"
cp -R presets "$APP/Contents/Resources/presets"
cp scripts/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # 图标由 scripts/icon/make_icon.swift 生成

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.undertone.Undertone</string>
    <key>CFBundleName</key><string>Undertone</string>
    <key>CFBundleDisplayName</key><string>Undertone</string>
    <key>CFBundleExecutable</key><string>Undertone</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 签名：有稳定证书时用它（屏幕录制权限在重新构建后仍然有效）；没有就退回 ad-hoc。
# 创建证书：钥匙串访问 → 证书助理 → 创建证书…，名称 "Undertone Local"，类型「代码签名」。
IDENTITY="${UNDERTONE_SIGN_IDENTITY:-Undertone Local}"
# 以前给 EmoLens 建过「EmoLens Local」证书的机器上直接沿用它
if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1 && security find-certificate -c "EmoLens Local" >/dev/null 2>&1; then
    IDENTITY="EmoLens Local"
fi
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
    echo "✅ 已生成 $APP（签名：$IDENTITY）"
else
    codesign --force --deep --sign - "$APP"
    echo "✅ 已生成 $APP（ad-hoc 签名）"
    echo "⚠️  ad-hoc 签名每次构建都会变，macOS 会要求重新授予屏幕录制权限。"
    echo "   创建一次「$IDENTITY」代码签名证书即可避免，见 README。"
fi
