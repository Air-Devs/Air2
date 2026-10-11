#!/usr/bin/env bash
# ============================================================================
# Air2 — JVM 运行时「就位」脚本
# ============================================================================
# ★不上云★：本脚本【不下载任何东西】。它只把**本机已存在的** Amethyst 构建产物里的
#   java-25-openjdk 复制到 Libraries/java_runtimes/，供 gen_xcodeproj.py 的
#   「Stage Runtime Bundle」脚本阶段随包 ⇒ Air2.app/java_runtimes/java-25-openjdk/。
#
# 为什么 JRE 不入 git： 119 MB —— 用户明确「★防石山★，不一股脑把 Amethyst 250MB 的东西搬过来」。
#   渲染器与 LWJGL（合计 ~3.3 MB）已随仓：Libraries/{Renderers,Frameworks,Jars}。
#
# 用法：
#   bash scripts/stage_runtime.sh
#   A2_JRE_SRC=/path/to/java-25-openjdk bash scripts/stage_runtime.sh
#
# 候选源（按序探测；全部是【本机本地路径】，无任何网络访问）：
#   $A2_JRE_SRC
#   /Volumes/Big/air/b12/artifacts/java_runtimes/java-25-openjdk          # Amethyst 构建产物（b12）
#   /Volumes/Big/air/b12/artifacts/Payload/AngelAuraAmethyst.app/java_runtimes/java-25-openjdk
#   /Volumes/Big/air/b12/Natives/build/AngelAuraAmethyst.app/java_runtimes/java-25-openjdk
# 许可： GPL-2.0 + Classpath Exception（OpenJDK 官方构建）。见 docs/DEPENDENCIES.md。
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_ROOT="$ROOT/Libraries/java_runtimes"
DEST="$DEST_ROOT/java-25-openjdk"

CANDIDATES=(
  "${A2_JRE_SRC:-}"
  "/Volumes/Big/air/b12/artifacts/java_runtimes/java-25-openjdk"
  "/Volumes/Big/air/b12/artifacts/Payload/AngelAuraAmethyst.app/java_runtimes/java-25-openjdk"
  "/Volumes/Big/air/b12/Natives/build/AngelAuraAmethyst.app/java_runtimes/java-25-openjdk"
)

SRC=""
for c in "${CANDIDATES[@]}"; do
  [ -n "$c" ] || continue
  if [ -f "$c/lib/server/libjvm.dylib" ]; then SRC="$c"; break; fi
done

if [ -z "$SRC" ]; then
  echo "错误：找不到本地 java-25-openjdk（探测了 ${#CANDIDATES[@]} 个候选路径）。" >&2
  echo "      请用 A2_JRE_SRC=<path> 显式指定。★本脚本不下载任何东西★。" >&2
  exit 1
fi

echo "==> JRE 源 : $SRC"
echo "==> 目标   : $DEST"
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

# 包内自证：a2_vmloader.m 解析 <javaHome>/lib/server/libjvm.dylib —— 缺它则 JVM 起不来。
JVM_LIB="$DEST/lib/server/libjvm.dylib"
if [ ! -f "$JVM_LIB" ]; then
  echo "错误：$JVM_LIB 缺失（启动链 a2_vm_resolve_libjvm 的首选布局）" >&2
  exit 1
fi

echo "==> 自证 OK"
ls -la "$JVM_LIB"
du -sh "$DEST"

# ============================================================================
# ★可选：再就位「用户能在设置里选到的其它档位」★
# ----------------------------------------------------------------------------
# 用法（★要加档才跑；不加则包内只有主推那一档★）：
#     A2_JRE_EXTRA="21 17 8" bash scripts/stage_runtime.sh
# 语义：把 <同一份本机 artifacts 根>/java-<N>-openjdk 复制到
#       Libraries/java_runtimes/java-<N>-openjdk，随 gen_xcodeproj.py 的
#       「Stage Runtime Bundle」阶段入包（= 设置页「Java 运行时」列表里变成「已内置」）。
# ★体积代价★：每档 ≈ 99~119 MB（未压缩；IPA 内约 +35 MB）。默认**不动**它们 ——
# 这正是「不做石山」的那条线：要加哪一档由人拍板，不由脚本自作主张。
# ============================================================================
if [ -n "${A2_JRE_EXTRA:-}" ]; then
  # 与主推同源：从主推那一份所在的本机 artifacts 根推同级的 java-<N>-openjdk。
  ROOTS="$(dirname "$(dirname "$SRC")") ${A2_JRE_ROOT:-}"
  for v in $A2_JRE_EXTRA; do
    want="java-${v}-openjdk"
    extra_src=""
    for r in $ROOTS; do
      [ -n "$r" ] || continue
      if [ -f "$r/$want/lib/server/libjvm.dylib" ]; then extra_src="$r/$want"; break; fi
    done
    if [ -z "$extra_src" ]; then
      echo "警告：本机 artifacts 里没有 $want（跳过；★不下载★）" >&2
      continue
    fi
    rm -rf "$DEST_ROOT/$want"
    cp -R "$extra_src" "$DEST_ROOT/$want"
    [ -f "$DEST_ROOT/$want/lib/server/libjvm.dylib" ] || { echo "错误：$want 复制不完整" >&2; exit 1; }
    echo "==> 已加档 $want"
    du -sh "$DEST_ROOT/$want"
  done
fi

echo "完成。接下来： python3 scripts/gen_xcodeproj.py && <build>"
