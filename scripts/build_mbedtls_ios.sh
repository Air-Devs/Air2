#!/bin/bash
# ============================================================================
#  Air2 —— [A2-INTEGRATION] mbedTLS → iOS arm64 静态库（离线重建脚本）
# ----------------------------------------------------------------------------
#  产出（随仓，供 Xcode 链接）：
#    Libraries/ThirdParty/mbedtls/lib/{libmbedtls.a,libmbedx509.a,libmbedcrypto.a}
#    Libraries/ThirdParty/mbedtls/include/{mbedtls,psa}/*.h
#  为什么随仓预编译：把「第三方 TLS」的引入面缩到最小 —— 不引包管理器、不联网取依赖、
#  不上云；重建配方就在本文件里，谁都能在 Mac 上离线复现。
#
#  ★不上云★：本脚本只从**本地已有的源码 tarball** 取源（$SRC_TGZ）；
#  首次获取该 tarball 的方式记录在仓库外（运维动作），本脚本不代为下载。
#
#  用法（Mac）：bash scripts/build_mbedtls_ios.sh /path/to/mbedtls-3.6.2.tar.gz
#  依赖：Xcode 命令行工具（xcrun/clang/ar/ranlib）。无 cmake、无 Homebrew 也可跑
#        （mbedTLS 3.6 的 CMake 依赖 framework 子模块，tarball 里没有 ⇒ 这里直接编 library/*.c）。
# ============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_TGZ="${1:-}"
WORK="${A2_MBEDTLS_WORK:-$HOME/a2_mbedtls_work}"
VERSION="3.6.2"
DEST="$REPO_ROOT/Libraries/ThirdParty/mbedtls"

if [ -z "$SRC_TGZ" ] || [ ! -f "$SRC_TGZ" ]; then
  echo "用法：bash scripts/build_mbedtls_ios.sh /path/to/mbedtls-$VERSION.tar.gz" >&2
  exit 2
fi

export PATH="/usr/local/bin:$HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=14.0 -O2 -fno-common"
# ★熵源★：库用 ALT 钩子，由 App 侧 Natives/Support/a2_tlspsk_mbedtls.m 的
#   mbedtls_hardware_poll（SecRandomCopyBytes）提供 ⇒ 库不依赖 /dev/urandom。
DEFS="-DMBEDTLS_ENTROPY_HARDWARE_ALT"

rm -rf "$WORK"; mkdir -p "$WORK/src" "$WORK/obj" "$WORK/out/lib" "$WORK/out/include"
tar xzf "$SRC_TGZ" -C "$WORK/src"
SRC="$WORK/src/mbedtls-$VERSION"
[ -d "$SRC/library" ] || { echo "源码树里没有 library/：$SRC" >&2; exit 2; }

cd "$SRC"
for f in library/*.c; do
  $CLANG $DEFS -I include -I library -c "$f" -o "$WORK/obj/$(basename "$f" .c).o"
done

# 分库（与上游一致）：crypto / x509 / tls
crypto_objs=""; x509_objs=""; tls_objs=""
for o in "$WORK"/obj/*.o; do
  b="$(basename "$o" .o)"
  case "$b" in
    ssl_*|tls13_*|tls12_*|tls1_*) tls_objs="$tls_objs $o" ;;
    x509*|pkcs7*|pkcs12*)          x509_objs="$x509_objs $o" ;;
    *)                             crypto_objs="$crypto_objs $o" ;;
  esac
done
ar rcs "$WORK/out/lib/libmbedcrypto.a" $crypto_objs; ranlib "$WORK/out/lib/libmbedcrypto.a"
ar rcs "$WORK/out/lib/libmbedx509.a"  $x509_objs $crypto_objs; ranlib "$WORK/out/lib/libmbedx509.a"
ar rcs "$WORK/out/lib/libmbedtls.a"   $tls_objs $x509_objs $crypto_objs; ranlib "$WORK/out/lib/libmbedtls.a"
cp -R include/mbedtls "$WORK/out/include/mbedtls"
[ -d include/psa ] && cp -R include/psa "$WORK/out/include/psa"

echo "=== lipo ==="; lipo -info "$WORK/out/lib/libmbedtls.a"
echo "=== 关键符号（PSK）==="
nm -gU "$WORK/out/lib/libmbedtls.a" | grep -E "_mbedtls_ssl_conf_psk$|_mbedtls_ssl_ciphersuite_from_id$" || true

# 落到仓库（幂等覆盖；头文件整体替换）
mkdir -p "$DEST"
rm -rf "$DEST/lib" "$DEST/include"
cp -R "$WORK/out/lib" "$DEST/lib"
cp -R "$WORK/out/include" "$DEST/include"
[ -f "$SRC/LICENSE" ] && cp -f "$SRC/LICENSE" "$DEST/LICENSE"
echo "已落：$DEST（lib + include + LICENSE）"
