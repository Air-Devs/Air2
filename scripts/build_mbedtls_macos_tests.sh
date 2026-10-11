#!/bin/bash
# ============================================================================
#  Air2 —— [JIT-AUTOPAIR-3] mbedTLS → macOS(x86_64 + arm64) 静态库（测试用，离线重建）
# ----------------------------------------------------------------------------
#  产出（随仓，供 tests/JIT/run_jit_tests.py 在 Mac 上真链接）：
#    Libraries/ThirdParty/mbedtls/lib-macos/libmbedcrypto.a
#
#  为什么需要它：
#    · a2_rppairing_srp.m 用随仓第三方 mbedTLS 的 `mbedtls_mpi` 做大数模幂（★不自造 bignum★）。
#    · 随仓的 Libraries/ThirdParty/mbedtls/lib/*.a 是 **iOS arm64** 静态库，无法链进 macOS 测试二进制。
#    · 单测在 macOS 上跑（clang + Foundation），所以这里产出一份同源(3.6.2)的 **macOS** mbedcrypto。
#      只需 crypto 部分（bignum），但整编 library/*.c 最省事且与 iOS 配方一致。
#
#  ★不上云★：只从**本地已有的源码目录**取源；获取该源码的方式记录在仓库外，本脚本不代为下载。
#
#  用法（Mac）：bash scripts/build_mbedtls_macos_tests.sh /path/to/mbedtls-3.6.2
#  依赖：Xcode 命令行工具（clang/ar/ranlib/lipo）。无 cmake、无 Homebrew 也可跑。
# ============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-}"
VERSION="3.6.2"
DEST="$REPO_ROOT/Libraries/ThirdParty/mbedtls/lib-macos"
WORK="${A2_MBEDTLS_MACOS_WORK:-$HOME/a2_mbedtls_macos_work}"

if [ -z "$SRC" ] || [ ! -d "$SRC/library" ]; then
  echo "用法：bash scripts/build_mbedtls_macos_tests.sh /path/to/mbedtls-$VERSION" >&2
  echo "（需指向含 library/ 与 include/ 的 mbedTLS $VERSION 源码目录）" >&2
  exit 2
fi

export PATH="/usr/local/bin:$HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin"
CLANG="clang -arch x86_64 -arch arm64 -O2 -fno-common"   # ★通用二进制：Intel 与 Apple Silicon 都能链★

rm -rf "$WORK"; mkdir -p "$WORK/obj"
cd "$SRC"
for f in library/*.c; do
  $CLANG -I include -I library -c "$f" -o "$WORK/obj/$(basename "$f" .c).o"
done

# 只需要 crypto（bignum 及其依赖）；ssl/x509 的对象一并进库也无害（静态库按需取成员）。
( cd "$WORK/obj" && ar rcs "$WORK/libmbedcrypto.a" *.o ) 2>/dev/null || {
  ( cd "$WORK/obj" && ar rcs "$WORK/libmbedcrypto.a" ./*.o )
}
ranlib "$WORK/libmbedcrypto.a" 2>/dev/null || true

mkdir -p "$DEST"
cp -f "$WORK/libmbedcrypto.a" "$DEST/libmbedcrypto.a"
echo "note: macOS mbedcrypto -> $DEST/libmbedcrypto.a"
lipo -info "$DEST/libmbedcrypto.a" || true
nm "$DEST/libmbedcrypto.a" 2>/dev/null | grep -q "_mbedtls_mpi_exp_mod" \
  && echo "note: 导出 mbedtls_mpi_exp_mod ✓"
