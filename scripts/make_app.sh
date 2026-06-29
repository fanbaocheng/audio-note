#!/usr/bin/env bash
#
# make_app.sh - 把 swift build 产物打包成 AudioNote.app
#
# 用法：
#   ./scripts/make_app.sh                # 默认 release，输出到 build/AudioNote.app
#   ./scripts/make_app.sh debug          # debug 配置（更快但更大）
#   APP_OUT_DIR=~/Desktop ./scripts/make_app.sh   # 自定义输出目录
#
# 产物结构：
#   AudioNote.app/
#   ├── Contents/
#   │   ├── Info.plist              (from Resources/Info.plist)
#   │   ├── MacOS/AudioNote         (swift build 产物)
#   │   └── Resources/
#   │       ├── AppIcon.icns        (from Resources/AppIcon.icns)
#   │       ├── scripts/
#   │       │   └── transcribe.py   (从仓库 scripts/ 拷贝)
#   │       └── vendor/
#   │           └── ffmpeg          (从仓库 vendor/ 拷贝，需先 ./scripts/fetch_vendor.sh)
#
# 退出码：
#   0 - 成功
#   1 - 缺依赖（vendor/ffmpeg 不存在等）
#   2 - swift build 失败
#

set -euo pipefail

# ---- 路径 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="${1:-release}"
OUT_DIR="${APP_OUT_DIR:-$REPO_ROOT/build}"
APP_NAME="AudioNote"
APP_BUNDLE="$OUT_DIR/$APP_NAME.app"

cd "$REPO_ROOT"

# ---- 前置检查 ----
if [ ! -f "Resources/AppIcon.icns" ]; then
    echo "❌ Resources/AppIcon.icns 不存在" >&2
    exit 1
fi

if [ ! -f "Resources/Info.plist" ]; then
    echo "❌ Resources/Info.plist 不存在" >&2
    exit 1
fi

if [ ! -f "vendor/ffmpeg" ]; then
    echo "❌ vendor/ffmpeg 不存在，请先运行：./scripts/fetch_vendor.sh" >&2
    exit 1
fi

if [ ! -f "scripts/transcribe.py" ]; then
    echo "❌ scripts/transcribe.py 不存在" >&2
    exit 1
fi

# ---- 1. swift build ----
# --disable-sandbox：避免某些环境下 SwiftPM 的 manifest sandbox-exec 拿不到权限
echo "🔨 swift build -c $CONFIG ..."
if ! swift build -c "$CONFIG" --disable-sandbox; then
    echo "❌ swift build 失败" >&2
    exit 2
fi

BIN_PATH="$(swift build -c "$CONFIG" --disable-sandbox --show-bin-path)/$APP_NAME"
if [ ! -x "$BIN_PATH" ]; then
    echo "❌ 找不到产物: $BIN_PATH" >&2
    exit 2
fi

# ---- 2. 清理旧 bundle ----
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/scripts"
mkdir -p "$APP_BUNDLE/Contents/Resources/vendor"

# ---- 3. 拷贝二进制 ----
echo "📦 拷贝 MacOS/AudioNote ..."
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# ---- 4. 拷贝资源 ----
echo "📦 拷贝 Info.plist / AppIcon.icns ..."
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "📦 拷贝 scripts/transcribe.py ..."
cp "scripts/transcribe.py" "$APP_BUNDLE/Contents/Resources/scripts/transcribe.py"

echo "📦 拷贝 vendor/ffmpeg ..."
cp "vendor/ffmpeg" "$APP_BUNDLE/Contents/Resources/vendor/ffmpeg"
chmod +x "$APP_BUNDLE/Contents/Resources/vendor/ffmpeg"

# ---- 5. 代码签名（ad-hoc） ----
echo "🔏 代码签名（ad-hoc）..."
codesign --force --deep --sign - "$APP_BUNDLE" 2>&1 | grep -v "replacing existing signature" || true

# ---- 6. 完成 ----
SIZE=$(du -sh "$APP_BUNDLE" | awk '{print $1}')
echo ""
echo "✅ 打包完成"
echo "   路径: $APP_BUNDLE"
echo "   大小: $SIZE"
echo ""
echo "   用法："
echo "     open '$APP_BUNDLE'"
echo "     或拖到 /Applications"
