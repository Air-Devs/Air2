#!/usr/bin/env bash
#
# Air2 — IPA 打包
#
# 与之前版本的关键差异：
#   之前只跑 xcodebuild，产出 711KB —— 因为 Frameworks/、java_runtimes/
#   和原生层源码根本没进包。
#
# 现在做完整流程：
#   1. 前置检查（依赖、JRE、工程）
#   2. 编译原生层（CMake）→ .dylib
#   3. xcodebuild archive（含 Natives 源码）
#   4. **把 Frameworks/ 与 java_runtimes/ 装进 .app**
#   5. 重新签名 + 打包 IPA
#   6. 体积校验（小于阈值直接失败，避免又产出"空壳"）
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCHEME="${SCHEME:-Air2}"
CONFIG="${CONFIG:-Release}"
OUTDIR="$ROOT/artifacts"
BUILDDIR="$ROOT/build/xcode"
METHOD="${METHOD:-development}"

# 最小可接受体积 —— Air1 约 200MB+，ZL2/FCL 300MB+。
# 低于 50MB 说明 Frameworks/JRE 没进去，直接失败比产出一个假包好。
MIN_IPA_MB="${MIN_IPA_MB:-50}"

die() { echo "  ✗ $*" >&2; exit 1; }

echo "==> Air2 打包"
echo "    方案: $SCHEME  配置: $CONFIG  方式: $METHOD"

# ------------------------------------------------------------
# 1. 前置检查
# ------------------------------------------------------------
echo ""
echo "==> 前置检查"

command -v xcodebuild >/dev/null 2>&1 || die "未检测到 xcodebuild（需在 macOS 上执行）"
[ -d "$ROOT/Air2.xcodeproj" ] || die "Air2.xcodeproj 不存在，先跑 scripts/gen_xcodeproj.py"

FRAMEWORKS_DIR="$ROOT/Libraries/Frameworks"
JRE_DIR="$ROOT/java_runtimes"

[ -d "$FRAMEWORKS_DIR" ] || die "Libraries/Frameworks 不存在，先跑 make deps"
[ -d "$JRE_DIR" ] || die "java_runtimes 不存在，先跑 make jre"

FW_COUNT=$(find "$FRAMEWORKS_DIR" -name '*.dylib' | wc -l | tr -d ' ')
JRE_COUNT=$(find "$JRE_DIR" -name 'libjvm.dylib' | wc -l | tr -d ' ')

echo "    Frameworks: $FW_COUNT 个 dylib"
echo "    JRE:        $JRE_COUNT 个版本"

[ "$FW_COUNT" -gt 0 ] || die "Frameworks 里没有 dylib"
[ "$JRE_COUNT" -gt 0 ] || die "java_runtimes 里没有 libjvm.dylib"

mkdir -p "$OUTDIR" "$BUILDDIR"

# ------------------------------------------------------------
# 2. 编译原生层（如果有 CMakeLists）
# ------------------------------------------------------------
NATIVES_BUILD="$ROOT/build/natives"
NATIVES_LIBS="$ROOT/build/natives-libs"
mkdir -p "$NATIVES_LIBS"

if [ -f "$ROOT/Natives/CMakeLists.txt" ] && command -v cmake >/dev/null 2>&1; then
    echo ""
    echo "==> 编译原生层（CMake）"

    SDK=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || echo "")
    if [ -n "$SDK" ]; then
        cmake -S "$ROOT/Natives" -B "$NATIVES_BUILD" \
            -DCMAKE_SYSTEM_NAME=iOS \
            -DCMAKE_OSX_SYSROOT="$SDK" \
            -DCMAKE_OSX_ARCHITECTURES=arm64 \
            -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
            -DCMAKE_BUILD_TYPE="$CONFIG" \
            -DCMAKE_INSTALL_PREFIX="$NATIVES_LIBS" 2>&1 | tail -5
        cmake --build "$NATIVES_BUILD" --parallel 2>&1 | tail -10 || \
            echo "    [警告] 原生层编译有错误，继续（产物可能不全）"
    else
        echo "    [跳过] 找不到 iphoneos SDK"
    fi
else
    echo ""
    echo "==> 跳过原生层编译（Natives/CMakeLists.txt 或 cmake 不存在）"
fi

# ------------------------------------------------------------
# 3. 归档
# ------------------------------------------------------------
echo ""
echo "==> 归档"

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

rm -rf "$BUILDDIR/Air2.xcarchive"

if ! xcodebuild archive \
    -project "$ROOT/Air2.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -archivePath "$BUILDDIR/Air2.xcarchive" \
    -allowProvisioningUpdates \
    "$@" 2>&1 | tail -30; then
    die "xcodebuild archive 失败"
fi

APP="$BUILDDIR/Air2.xcarchive/Products/Applications/Air2.app"
[ -d "$APP" ] || die "归档里找不到 Air2.app"

# ------------------------------------------------------------
# 4. 注入 Frameworks 与 JRE
# ------------------------------------------------------------
echo ""
echo "==> 注入二进制"

mkdir -p "$APP/Frameworks"

# ---- 4.1 动态库 ----
for fw in "$FRAMEWORKS_DIR"/*.dylib; do
    [ -f "$fw" ] || continue
    cp "$fw" "$APP/Frameworks/"
done

# ---- 4.2 .framework（libEGL / libGLESv2）----
for fwdir in "$FRAMEWORKS_DIR"/*.framework; do
    [ -d "$fwdir" ] || continue
    cp -R "$fwdir" "$APP/Frameworks/"
done

# ---- 4.3 原生层编译产物 ----
if [ -d "$NATIVES_LIBS" ]; then
    find "$NATIVES_LIBS" -name '*.dylib' -exec cp {} "$APP/Frameworks/" \; 2>/dev/null || true
fi

# ---- 4.4 JRE ----
if [ -d "$JRE_DIR" ]; then
    cp -R "$JRE_DIR" "$APP/java_runtimes"
fi

# ---- 4.5 启动器资源 ----
if [ -d "$ROOT/Natives/resources" ]; then
    for f in "$ROOT/Natives/resources"/*; do
        [ -e "$f" ] || continue
        base=$(basename "$f")
        case "$base" in
            Frameworks|*.lproj) continue ;;
        esac
        cp -R "$f" "$APP/" 2>/dev/null || true
    done
fi

# ---- 4.6 统计 ----
FW_SIZE=$(du -sh "$APP/Frameworks" 2>/dev/null | cut -f1)
JRE_SIZE=$(du -sh "$APP/java_runtimes" 2>/dev/null | cut -f1)
echo "    Frameworks: ${FW_SIZE:-0}"
echo "    JRE:        ${JRE_SIZE:-0}"

# ------------------------------------------------------------
# 5. 签名 + 打包
# ------------------------------------------------------------
echo ""
echo "==> 签名"

# Info.plist 里声明 dylib 库路径，否则 dyld 找不到
PLIST="$APP/Info.plist"
if [ -f "$PLIST" ] && /usr/libexec/PlistBuddy -c "Print :LSEnvironment" "$PLIST" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :LSEnvironment:DYLD_LIBRARY_PATH @executable_path/Frameworks" "$PLIST" 2>/dev/null || true
fi

# 重新签名（注入文件后原签名失效）
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    echo "    使用证书: $EXPANDED_CODE_SIGN_IDENTITY"
    find "$APP/Frameworks" -name '*.dylib' -exec codesign -f -s "$EXPANDED_CODE_SIGN_IDENTITY" {} \; 2>/dev/null || true
    codesign -f -s "$EXPANDED_CODE_SIGN_IDENTITY" "$APP" 2>/dev/null || true
else
    echo "    无证书，使用 ad-hoc 签名（TrollStore/越狱可用）"
    find "$APP/Frameworks" -name '*.dylib' -exec codesign -f -s - {} \; 2>/dev/null || true
    codesign -f -s - --deep "$APP" 2>/dev/null || true
fi

echo ""
echo "==> 打包 IPA"

IPA="$OUTDIR/Air2.ipa"
rm -f "$IPA"
mkdir -p "$BUILDDIR/Payload"
rm -rf "$BUILDDIR/Payload/Air2.app"
cp -R "$APP" "$BUILDDIR/Payload/"
(cd "$BUILDDIR" && zip -qry "$IPA" Payload)

# ------------------------------------------------------------
# 6. 体积校验
# ------------------------------------------------------------
echo ""
echo "==> 体积校验"

SIZE_BYTES=$(stat -f%z "$IPA" 2>/dev/null || stat -c%s "$IPA")
SIZE_MB=$((SIZE_BYTES / 1024 / 1024))

echo "    IPA: ${SIZE_MB} MB"

if [ "$SIZE_MB" -lt "$MIN_IPA_MB" ]; then
    echo ""
    echo "  ✗ IPA 只有 ${SIZE_MB} MB，低于最低要求 ${MIN_IPA_MB} MB" >&2
    echo "    这通常意味着 Frameworks 或 JRE 没有正确注入。" >&2
    echo "    检查：$APP/Frameworks 与 $APP/java_runtimes" >&2
    exit 1
fi

echo ""
echo "==> 完成：$IPA"
ls -lh "$IPA"
