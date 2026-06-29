#!/usr/bin/env bash
# 下载 vendor/ffmpeg（首次构建需要）
# 用法：bash scripts/fetch_vendor.sh
#
# 平台支持：macOS arm64（Apple Silicon）原生静态构建
# 主源：osxexperts.net   备用源：ffmpeg.martin-riedl.de
# 注：evermeet.cx 只发 Intel x86_64，不提供原生 arm64，本脚本不再使用它。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT/vendor"
mkdir -p "$VENDOR_DIR"

ARCH="$(uname -m)"
OS="$(uname -s)"
if [[ "$OS" != "Darwin" || "$ARCH" != "arm64" ]]; then
    echo "⚠️  当前平台 $OS/$ARCH 非 macOS arm64，本脚本仅打包 Apple Silicon 二进制" >&2
    echo "    如果只是开发，可以手动放一个 ffmpeg 到 $VENDOR_DIR/ffmpeg 跳过此步" >&2
    exit 1
fi

if [[ -f "$VENDOR_DIR/ffmpeg" ]]; then
    echo "✓ 已存在 $VENDOR_DIR/ffmpeg，跳过下载"
    "$VENDOR_DIR/ffmpeg" -version 2>/dev/null | head -1 || true
    exit 0
fi

# 候选源（按优先级）
SOURCES=(
    "https://www.osxexperts.net/ffmpeg81arm.zip"
    "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/snapshot/ffmpeg.zip"
)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

DOWNLOADED=""
for URL in "${SOURCES[@]}"; do
    echo "==> 尝试下载: $URL"
    if curl -L --fail --connect-timeout 15 --max-time 300 \
            -o "$TMP/ffmpeg.zip" "$URL"; then
        DOWNLOADED="$URL"
        break
    else
        echo "    × 失败，尝试下一个源"
    fi
done

if [[ -z "$DOWNLOADED" ]]; then
    echo "❌ 所有候选源均失败，请检查网络或手动放一个 arm64 ffmpeg 到 $VENDOR_DIR/ffmpeg" >&2
    exit 2
fi

echo "==> 解压"
unzip -q -o "$TMP/ffmpeg.zip" -d "$TMP"

# zip 里可能直接是 ffmpeg，也可能是 ffmpeg/ffmpeg
if [[ -f "$TMP/ffmpeg" ]]; then
    mv "$TMP/ffmpeg" "$VENDOR_DIR/ffmpeg"
elif [[ -f "$TMP/ffmpeg/ffmpeg" ]]; then
    mv "$TMP/ffmpeg/ffmpeg" "$VENDOR_DIR/ffmpeg"
else
    FOUND="$(find "$TMP" -maxdepth 3 -type f -name ffmpeg | head -1 || true)"
    if [[ -n "$FOUND" ]]; then
        mv "$FOUND" "$VENDOR_DIR/ffmpeg"
    else
        echo "❌ 解压后未找到 ffmpeg 可执行文件" >&2
        exit 3
    fi
fi

chmod +x "$VENDOR_DIR/ffmpeg"

# macOS quarantine + ad-hoc 签名（osxexperts 文档要求）
echo "==> 清理 quarantine 属性 + ad-hoc 签名"
xattr -cr "$VENDOR_DIR/ffmpeg" 2>/dev/null || true
codesign --force --sign - "$VENDOR_DIR/ffmpeg" 2>/dev/null || true

# 验证
echo "==> 验证"
"$VENDOR_DIR/ffmpeg" -version | head -1
ARCH_INFO="$(file "$VENDOR_DIR/ffmpeg" | head -1)"
echo "    $ARCH_INFO"

echo ""
echo "Done: $VENDOR_DIR/ffmpeg"
echo "Source: $DOWNLOADED"
