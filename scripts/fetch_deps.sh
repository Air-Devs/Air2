#!/bin/sh
#
# 下载预编译依赖（Libraries/ 下的 .dylib 与 .jar）
#
# 为什么用脚本而不是把二进制提交进 git：
#   这些产物总共约 250MB（MobileGL 两个 85MB 的库就占了大半）。
#   提交进仓库会让 clone 变得极慢，而且每次重建都要重传。
#
# 依赖来源：Amethyst（Air1）的预编译产物。
#
# 用法：
#   ./scripts/fetch_deps.sh            # 下载全部
#   ./scripts/fetch_deps.sh --check    # 只校验已下载的文件完整性
#
# ⚠️ 关于镜像站
#   raw.githubusercontent.com 对大文件会【静默截断】——
#   curl 返回 0，文件只有期望大小的一部分。
#   实测：libMobileGL 期望 85.7MB 只下到 7.8MB；
#         libOSMesa 期望 17.8MB 只下到 3.6KB。
#   所以必须走镜像站（ghfast.top），并且下载后校验大小。
#

set -u

REPO="herbrine8403/Amethyst-iOS-MyRemastered"
BRANCH="main"
MIRRORS="https://ghfast.top/https://raw.githubusercontent.com https://gh-proxy.com/https://raw.githubusercontent.com https://raw.githubusercontent.com"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# 期望的文件清单：路径|最小可用大小（字节，0 = 不校验）
FILES="
Libraries/Frameworks/libEGL.framework/libEGL|300000
Libraries/Frameworks/libGLESv2.framework/libGLESv2|5000000
Libraries/Frameworks/libMobileGL.dylib|80000000
Libraries/Frameworks/libMobileGL-gles.dylib|80000000
Libraries/Frameworks/libMoltenVK.dylib|6000000
Libraries/Frameworks/libOSMesa.8.dylib|17000000
Libraries/Frameworks/libSDL3.dylib|2000000
Libraries/Frameworks/liblwjgl.dylib|300000
Libraries/Frameworks/liblwjgl_opengl.dylib|150000
Libraries/Frameworks/liblwjgl_tinyfd.dylib|130000
Libraries/Frameworks/liblwjgl_stb.dylib|400000
Libraries/Frameworks/liblwjgl_nanovg.dylib|380000
Libraries/Frameworks/liblwjgl_vma.dylib|180000
Libraries/Frameworks/libopenal_impl.dylib|4000000
Libraries/Frameworks/libglslang.dylib|2900000
Libraries/Frameworks/libglslang.16.dylib|2900000
Libraries/Frameworks/libshaderc.dylib|9000000
Libraries/Frameworks/libshaderc_impl.dylib|2500000
Libraries/Frameworks/libspirv-cross.dylib|2600000
Libraries/Frameworks/libfreetype.dylib|2000000
Libraries/Frameworks/libmetallum.dylib|200000
Libraries/Frameworks/libglapi.0.dylib|500000
Libraries/Frameworks/libvulkan.1.dylib|16000
Libraries/Jars/lwjgl-333/lwjgl.jar|700000
Libraries/Jars/lwjgl-333/lwjgl-glfw.jar|120000
Libraries/Jars/lwjgl-333/lwjgl-opengl.jar|900000
Libraries/Jars/lwjgl-333/lwjgl-openal.jar|6000
Libraries/Jars/lwjgl-333/lwjgl-stb.jar|110000
Libraries/Jars/lwjgl-333/lwjgl-tinyfd.jar|6000
Libraries/Jars/lwjgl-333/lwjgl-vma.jar|90000
Libraries/Jars/lwjgl-333/lwjgl-nanovg.jar|120000
Libraries/Jars/lwjgl-333/lwjgl-shaderc.jar|22000
Libraries/Jars/lwjgl-333/lwjgl-spvc.jar|19000
Libraries/Jars/lwjgl-333/lwjgl-freetype.jar|440000
Libraries/Jars/lwjgl-333/lwjgl-vulkan.jar|4600000
Libraries/Jars/lwjgl-333/lwjgl-lwjglx.jar|230000
Libraries/Jars/lwjgl-341/lwjgl.jar|850000
Libraries/Jars/lwjgl-341/lwjgl-glfw.jar|130000
Libraries/Jars/lwjgl-341/lwjgl-opengl.jar|900000
"

# 源路径映射（Air2 路径 → Air1 仓库路径）
air1_path() {
    case "$1" in
        Libraries/Frameworks/*)
            echo "Natives/resources/Frameworks/$(basename "$1")"
            ;;
        Libraries/Jars/lwjgl-333/*)
            echo "JavaApp/libs/lwjgl-333/$(basename "$1")"
            ;;
        Libraries/Jars/lwjgl-341/*)
            echo "JavaApp/libs/lwjgl-341/$(basename "$1")"
            ;;
        *)
            echo "$1"
            ;;
    esac
}

# 检查单个文件
verify_one() {
    local rel="$1" min="$2"
    local cur=$(stat -c%s "$ROOT/$rel" 2>/dev/null || echo 0)
    [ "$cur" -ge "$min" ]
}

# 下载单个文件
fetch_one() {
    local rel="$1" min="$2"
    local src=$(air1_path "$rel")
    local out="$ROOT/$rel"

    mkdir -p "$(dirname "$out")"

    for M in $MIRRORS; do
        rm -f "$out"
        curl -sL --max-time 900 --retry 2 "$M/$REPO/$BRANCH/$src" -o "$out" 2>/dev/null
        if verify_one "$rel" "$min"; then
            return 0
        fi
    done
    rm -f "$out"
    return 1
}

# ---------------- 主流程 ----------------

FAILED=""
OK=0
SKIP=0

echo "$FILES" | while IFS='|' read -r rel min; do
    [ -z "$rel" ] && continue

    if verify_one "$rel" "$min"; then
        if [ "$CHECK_ONLY" = "1" ]; then
            printf "  ✓ %s\n" "$(basename "$rel")"
        else
            printf "  · %s（已存在）\n" "$(basename "$rel")"
        fi
        continue
    fi

    [ "$CHECK_ONLY" = "1" ] && {
        printf "  ✗ %s（不完整或缺失）\n" "$(basename "$rel")"
        continue
    }

    printf "  ↓ %s ... " "$(basename "$rel")"
    if fetch_one "$rel" "$min"; then
        printf "OK (%s bytes)\n" "$(stat -c%s "$ROOT/$rel")"
    else
        printf "失败\n"
    fi
done

if [ "$CHECK_ONLY" = "0" ]; then
    echo ""
    echo "=== 校验 ==="
    exec "$0" --check
fi
