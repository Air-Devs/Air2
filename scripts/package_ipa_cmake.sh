#!/usr/bin/env bash
# ============================================================================
# Air2 — 不依赖 xcodeproj 的 IPA 打包（CMake 产物 + ldid 签名）
#
# 调用点（谁执行它）：
#   ① CMakeLists.txt:67   cmake --build build/cmake --target a2-ipa
#   ② 手工：bash scripts/package_ipa_cmake.sh [--app-dir <dir>] [--out <dir>]
#
# 与 scripts/package_ipa.sh 的关系：那个走 xcodebuild archive/export（需要证书/
# provisioning），本脚本走「CMake 产物 + ldid ad-hoc 签名」，用于真机自签迭代。
# 两者并存，互不替代。
#
# ★资源清单一律复用★：<App>/{Frameworks,libs,java_runtimes} 的拷贝逻辑不是本脚本
# 重写的，而是直接执行 scripts/gen_xcodeproj.py 里 runtime_stage_script() 生成的
# 那段 shell（见下面 step 3）。这样「Xcode 包里有什么」与「CMake 包里有什么」
# 只有一个源头，不会各自漂移。
#
# 前置：macOS + Xcode(clang/SDK) + ldid。ldid 依次在 $LDID → /usr/local/bin →
#       /opt/homebrew/bin → ~/bin → PATH 里找（非交互 SSH 的 PATH 常常没有
#       /usr/local/bin，这正是本脚本要自己找的原因）。
# 产物：<out>/Air2-cmake.ipa（缺省 artifacts/）
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR=""
OUT_DIR="$ROOT/artifacts"
BUNDLE_NAME="Air2"

while [ $# -gt 0 ]; do
    case "$1" in
        --app-dir) APP_DIR="${2:-}"; shift 2 ;;
        --out)     OUT_DIR="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- 前置检查
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
    echo "[fail] 需要 python3（读 gen_xcodeproj.py 的资源清单/版本常量）" >&2
    exit 1
fi

find_ldid() {
    for c in "${LDID:-}" /usr/local/bin/ldid /opt/homebrew/bin/ldid "$HOME/bin/ldid"; do
        [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
    done
    command -v ldid 2>/dev/null || true
}
LDID_BIN="$(find_ldid)"
if [ -z "$LDID_BIN" ]; then
    echo "[fail] 找不到 ldid（可用 LDID=/path/to/ldid 指定；brew install ldid 亦可）" >&2
    exit 1
fi

if [ -z "$APP_DIR" ]; then
    # CMake 在 iOS 平台把 add_executable 自动包成 <name>.app（见根 CMakeLists.txt）
    APP_DIR="$ROOT/build/cmake/${BUNDLE_NAME}.app"
fi
if [ ! -d "$APP_DIR" ]; then
    echo "[fail] 找不到 CMake 产物 $APP_DIR" >&2
    echo "       先构建：cmake -S . -B build/cmake -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-ios.cmake && cmake --build build/cmake -j8" >&2
    exit 1
fi
if [ ! -f "$APP_DIR/$BUNDLE_NAME" ]; then
    echo "[fail] $APP_DIR/$BUNDLE_NAME 不存在（可执行文件没生成？）" >&2
    exit 1
fi

# 中间产物放 build/（.gitignore 已忽略 /build/），不污染仓库、不写 /tmp 之外的地方
STAGE="$ROOT/build/cmake-package"
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload" "$OUT_DIR"

echo "==> 1/5 拷贝 CMake 产物 → Payload/$BUNDLE_NAME.app"
cp -R "$APP_DIR" "$STAGE/Payload/$BUNDLE_NAME.app"
APP="$STAGE/Payload/$BUNDLE_NAME.app"

# ---------------------------------------------------------------- Info.plist
# CMake 生成的 plist 只是占位：Air2/Info.plist 里是 Xcode 的 $(VAR) 语法，
# CMake 只认 @VAR@，展开不了 ⇒ 在这里用 gen_xcodeproj.py 的常量替换。
# ★唯一来源★：BUNDLE_ID / BUILD_VERSION / MARKETING_VERSION 都从那个模块读，
# 不再抄一份字面量。
echo "==> 2/5 生成 Info.plist（替换 \$(PRODUCT_BUNDLE_IDENTIFIER) 等 Xcode 变量）"
"$PY" - "$ROOT" "$APP" <<'PYEOF'
import subprocess
import sys

root, app = sys.argv[1], sys.argv[2]
out = subprocess.run(
    [sys.executable, "-c",
     "import sys; sys.path.insert(0, sys.argv[1] + '/scripts');"
     "import importlib.util as u;"
     "s = u.spec_from_file_location('g', sys.argv[1] + '/scripts/gen_xcodeproj.py');"
     "m = u.module_from_spec(s); s.loader.exec_module(m);"
     "print(m.BUNDLE_ID); print(m.BUILD_VERSION); print(m.MARKETING_VERSION);"
     "print(m.PROJECT_NAME)", root],
    capture_output=True, text=True, check=True)
bundle_id, build_version, marketing_version, product_name = out.stdout.strip().split("\n")

src = open(root + "/Air2/Info.plist", encoding="utf-8").read()
subs = {
    "$(PRODUCT_BUNDLE_IDENTIFIER)": bundle_id,
    "$(CURRENT_PROJECT_VERSION)": build_version,
    "$(PRODUCT_NAME)": product_name,
    "$(EXECUTABLE_NAME)": product_name,
    "$(MARKETING_VERSION)": marketing_version,
}
for k, v in subs.items():
    src = src.replace(k, v)
left = [t for t in subs if t in src]
assert not left, "Info.plist 仍有未展开的 Xcode 变量: %s" % left
open(app + "/Info.plist", "w", encoding="utf-8").write(src)
print("   CFBundleIdentifier=%s  CFBundleVersion=%s  短版本=%s"
      % (bundle_id, build_version, marketing_version))
PYEOF

# 断言：包内 plist 里不许残留 $(...)（残留 = 装到真机上显示字面变量）
if grep -q '\$(' "$APP/Info.plist"; then
    echo "[fail] Info.plist 仍含未展开的 \$(...)：$(grep -o '\$([A-Z_]*)' "$APP/Info.plist" | sort -u | tr '\n' ' ')" >&2
    exit 1
fi

# --------------------------------------------------- 运行时资源（复用既有清单）
# 直接执行 gen_xcodeproj.runtime_stage_script() 的输出（Xcode 侧同一个函数），
# 只把它依赖的 Xcode 环境变量换成我们的路径：
#   BUILT_PRODUCTS_DIR = $STAGE  （它拼 "$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH"）
#   CONTENTS_FOLDER_PATH = Payload/Air2.app
#   SRCROOT = 仓库根
# 该脚本约定在仓库根执行（里面有 "Assets/..." 相对路径），所以先 cd。
echo "==> 3/5 随包资源（Frameworks/ libs/ java_runtimes/ + JIT 脚本 + 图标）"
STAGE_SCRIPT="$STAGE/runtime_stage.sh"
"$PY" - "$ROOT" "$STAGE_SCRIPT" <<'PYEOF'
import importlib.util
import sys

root, dst = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("g", root + "/scripts/gen_xcodeproj.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
open(dst, "w", encoding="utf-8").write(mod.runtime_stage_script())
print("   %d 行（来源：gen_xcodeproj.runtime_stage_script()）"
      % len(mod.runtime_stage_script().splitlines()))
PYEOF
( cd "$ROOT" && SRCROOT="$ROOT" BUILT_PRODUCTS_DIR="$STAGE" \
    CONTENTS_FOLDER_PATH="Payload/$BUNDLE_NAME.app" /bin/sh "$STAGE_SCRIPT" )

# ---------------------------------------------------------------- 签名
# fail 在签名阶段就可能被置位，所以提前初始化（下面包内断言沿用同一个累加器）
fail=0
echo "==> 4/5 ldid 签名（$LDID_BIN）"
# 默认 ad-hoc（ldid -S）。要带权限（JIT/get-task-allow）就：
#   ENTITLEMENTS=path/to/ent.plist bash scripts/package_ipa_cmake.sh
# ★注意★：真机 JIT 所需的 get-task-allow / dynamic-codesigning 由侧载工具
# （StikDebug / SideStore）注入；本脚本只保证包是「签名完整、可被侧载工具接管」的。
SIGN_ARGS=(-S)
if [ -n "${ENTITLEMENTS:-}" ]; then
    if [ ! -f "$ENTITLEMENTS" ]; then
        echo "[fail] ENTITLEMENTS=$ENTITLEMENTS 不存在" >&2
        exit 1
    fi
    SIGN_ARGS=(-S"$ENTITLEMENTS")
fi
"$LDID_BIN" "${SIGN_ARGS[@]}" "$APP/$BUNDLE_NAME"

# ---- 签名自证 ----
# ★只断言「二进制里嵌了 CodeDirectory」，不断言 codesign -v 通过★
#   ldid 是 ad-hoc 签名：它写 LC_CODE_SIGNATURE + CodeDirectory，但**不生成**
#   _CodeSignature/CodeResources（bundle 封印）。因此 `codesign -v Air2.app`
#   会说 "code object is not signed at all"，那是 ldid 的预期行为，不是打包失败。
#   真机侧载时 StikDebug / SideStore / Sideloadly 会整体重签并重建封印。
if otool -l "$APP/$BUNDLE_NAME" | grep -q LC_CODE_SIGNATURE; then
    SIG_SZ="$(otool -l "$APP/$BUNDLE_NAME" | grep -A3 LC_CODE_SIGNATURE | awk '/datasize/{print $2}')"
    echo "   [ok] LC_CODE_SIGNATURE 已嵌入（datasize=${SIG_SZ}B，ad-hoc；bundle 封印由侧载工具重建）"
else
    echo "   [fail] 没有 LC_CODE_SIGNATURE —— ldid 没写进去" >&2
    fail=1
fi

# ---------------------------------------------------------------- 压包 + 自检
echo "==> 5/5 压缩为 ipa"
IPA="$OUT_DIR/Air2-cmake.ipa"
rm -f "$IPA"
( cd "$STAGE" && zip -qry "$IPA" Payload )

# ---- 包内断言（缺一项就失败，不做「大概打好了」）----
need=(
    "Payload/$BUNDLE_NAME.app/$BUNDLE_NAME"
    "Payload/$BUNDLE_NAME.app/Info.plist"
    "Payload/$BUNDLE_NAME.app/Frameworks"
    "Payload/$BUNDLE_NAME.app/libs"
    "Payload/$BUNDLE_NAME.app/java_runtimes"
)
LIST="$(unzip -l "$IPA")"
for n in "${need[@]}"; do
    if echo "$LIST" | grep -q " $n"; then
        echo "   [ok] $n"
    else
        echo "   [MISS] $n" >&2
        fail=1
    fi
done

# 架构断言：真机包必须是 arm64 的 Mach-O（Intel 宿主上编错就会退化成 x86_64）
ARCH="$(file "$APP/$BUNDLE_NAME" | tr -d '\n')"
case "$ARCH" in
    *arm64*) echo "   [ok] $ARCH" ;;
    *) echo "   [fail] 架构不对: $ARCH" >&2; fail=1 ;;
esac

# 启动链断言：渲染器 dylib 与 JRE 必须在（A2ResourcePaths 按这些路径找）
if echo "$LIST" | grep -q "Payload/$BUNDLE_NAME.app/Frameworks/"; then
    echo "   [ok] Frameworks 非空"
else
    echo "   [warn] Frameworks 为空（Libraries/Renderers/*.dylib 未就位？）" >&2
fi

# java_runtimes 只做「有/无」提示，不当失败：JRE 不入 git（防石山），缺它时
# runtime_stage_script() 自己会打 warning，本脚本跟着如实报，不掩盖。
if [ -n "$(ls -A "$APP/java_runtimes" 2>/dev/null)" ]; then
    echo "   [ok] java_runtimes 已就位（$(ls -A "$APP/java_runtimes" | tr '\n' ' '))"
else
    echo "   [warn] java_runtimes 为空：包内没有 JVM。出可启动的 ipa 前先跑 scripts/stage_runtime.sh" >&2
fi

[ "$fail" -eq 0 ] || { echo "[fail] 包内自检未通过：$IPA" >&2; exit 1; }

echo "==> 完成：$IPA ($(du -h "$IPA" | cut -f1))"
