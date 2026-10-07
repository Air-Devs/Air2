#!/usr/bin/env bash
# ============================================================
# Air2 — IPA 打包脚本
# 前置：Xcode 26.x、iOS 26 SDK、Air2.xcodeproj 已就绪
# 产物：artifacts/Air2.ipa
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCHEME="${SCHEME:-Air2}"
CONFIG="${CONFIG:-Release}"
OUTDIR="$ROOT/artifacts"
BUILDDIR="$ROOT/build/xcode"
METHOD="${METHOD:-development}"   # development | ad-hoc | app-store | enterprise

echo "==> Air2 打包"
echo "    方案: $SCHEME  配置: $CONFIG  方式: $METHOD"

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "  [跳过] 未检测到 xcodebuild（需在 macOS 上执行）" >&2
    exit 0
fi

if [ ! -d "$ROOT/Air2.xcodeproj" ]; then
    echo "  [跳过] Air2.xcodeproj 尚未创建" >&2
    exit 0
fi

mkdir -p "$OUTDIR" "$BUILDDIR"

cat > "$BUILDDIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>${METHOD}</string>
    <key>compileBitcode</key>
    <false/>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

echo "==> 归档"
xcodebuild archive \
    -project "$ROOT/Air2.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -archivePath "$BUILDDIR/Air2.xcarchive" \
    -allowProvisioningUpdates \
    "$@"

echo "==> 导出 IPA"
xcodebuild -exportArchive \
    -archivePath "$BUILDDIR/Air2.xcarchive" \
    -exportOptionsPlist "$BUILDDIR/ExportOptions.plist" \
    -exportPath "$OUTDIR" \
    -allowProvisioningUpdates

echo "==> 完成：$OUTDIR"
ls -lh "$OUTDIR" 2>/dev/null || true
