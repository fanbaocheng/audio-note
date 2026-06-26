#!/usr/bin/env bash
# 下载 vendor/ffmpeg（首次构建需要）
# 用法：bash scripts/fetch_vendor.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT/vendor"
mkdir -p "$VENDOR_DIR"

echo "==> 拉取 ffmpeg 静态二进制（arm64 macOS）"

if [[ -f "$VENDOR_DIR/ffmpeg" ]]; then
    echo "    已存在 $VENDOR_DIR/ffmpeg，跳过"
else
    TMP=$(mktemp -d)
    echo "    源：evermeet.cx"
    curl -L --fail -o "$TMP/ffmpeg.zip" "https://evermeet.cx/ffmpeg/get/zip"
    unzip -q "$TMP/ffmpeg.zip" -d "$TMP"
    mv "$TMP/ffmpeg" "$VENDOR_DIR/ffmpeg"
    chmod +x "$VENDOR_DIR/ffmpeg"
    rm -rf "$TMP"
    echo "    ✓ ffmpeg 已下载到 $VENDOR_DIR/ffmpeg"
fi

# 验证
"$VENDOR_DIR/ffmpeg" -version | head -1
echo "==> Done"
