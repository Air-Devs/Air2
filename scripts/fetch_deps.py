#!/usr/bin/env python3
"""
下载并校验预编译依赖。

## 为什么需要这个脚本

这些产物约 250MB（MobileGL 两个库各 85MB、Mesa 17MB、terracotta 18.6MB）。
提交进 git 会让 clone 极慢，所以不提交，用脚本按需下载。

## ⚠️ 最大的坑：GitHub 对大文件会静默截断

raw.githubusercontent.com 对超过一定大小的文件会截断传输，
**curl 仍然返回 0**，文件却只有期望大小的一部分。

实测被截断的文件（每次都是随机发生，不是稳定复现）：

| 文件 | 期望 | 实际下到 |
|---|---|---|
| libMobileGL.dylib | 85.7 MB | 7.8 MB |
| libOSMesa.8.dylib | 17.8 MB | 3.6 KB |
| libMoltenVK.dylib | 6.6 MB | 3.3 MB |
| libterracotta.a | 18.6 MB | 10.2 MB |
| lwjgl-openal.jar | 105 KB | 6.9 KB |
| lwjgl-vulkan.jar | 5.7 MB | 4.4 MB |
| lwjgl-spvc.jar | 122 KB | 19 KB |

**所以：下载后必须校验大小，且要对照【真实大小】而不是"大于某个阈值"。**

本脚本的做法：
  1. 从 Air1 仓库的 list 接口拿每个文件的准确大小
  2. 走镜像站下载（ghfast.top 实测 266 KB/s）
  3. 下完比对大小，不等就换源重试

用法：
    python3 scripts/fetch_deps.py            # 下载缺失/损坏的
    python3 scripts/fetch_deps.py --check    # 只校验
"""

import json
import os
import sys
import time
import urllib.request

REPO = "herbrine8403/Amethyst-iOS-MyRemastered"
BRANCH = "main"

# 镜像站：raw.githubusercontent.com 会截断，必须走这些
MIRRORS = [
    "https://ghfast.top/https://raw.githubusercontent.com",
    "https://gh-proxy.com/https://raw.githubusercontent.com",
    "https://raw.githubusercontent.com",
]

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 要下载的文件：Air2 路径 → Air1 路径
DEPENDENCIES = {
    # ---- Frameworks ----
    "Libraries/Frameworks/libEGL.framework/libEGL":
        "Libraries/Frameworks/libEGL.framework/libEGL",
    "Libraries/Frameworks/libEGL.framework/Info.plist":
        "Libraries/Frameworks/libEGL.framework/Info.plist",
    "Libraries/Frameworks/libGLESv2.framework/libGLESv2":
        "Libraries/Frameworks/libGLESv2.framework/libGLESv2",
    "Libraries/Frameworks/libGLESv2.framework/Info.plist":
        "Libraries/Frameworks/libGLESv2.framework/Info.plist",
    "Libraries/Frameworks/libMobileGL.dylib":
        "Libraries/Frameworks/libMobileGL.dylib",
    "Libraries/Frameworks/libMobileGL-gles.dylib":
        "Libraries/Frameworks/libMobileGL-gles.dylib",
    "Libraries/Frameworks/libMoltenVK.dylib":
        "Libraries/Frameworks/libMoltenVK.dylib",
    "Libraries/Frameworks/libOSMesa.8.dylib":
        "Libraries/Frameworks/libOSMesa.8.dylib",
    "Libraries/Frameworks/libSDL3.dylib":
        "Libraries/Frameworks/libSDL3.dylib",
    "Libraries/Frameworks/liblwjgl.dylib":
        "Libraries/Frameworks/liblwjgl.dylib",
    "Libraries/Frameworks/liblwjgl_opengl.dylib":
        "Libraries/Frameworks/liblwjgl_opengl.dylib",
    "Libraries/Frameworks/liblwjgl_tinyfd.dylib":
        "Libraries/Frameworks/liblwjgl_tinyfd.dylib",
    "Libraries/Frameworks/liblwjgl_stb.dylib":
        "Libraries/Frameworks/liblwjgl_stb.dylib",
    "Libraries/Frameworks/liblwjgl_nanovg.dylib":
        "Libraries/Frameworks/liblwjgl_nanovg.dylib",
    "Libraries/Frameworks/liblwjgl_vma.dylib":
        "Libraries/Frameworks/liblwjgl_vma.dylib",
    "Libraries/Frameworks/libopenal_impl.dylib":
        "Libraries/Frameworks/libopenal_impl.dylib",
    "Libraries/Frameworks/libglslang.dylib":
        "Libraries/Frameworks/libglslang.dylib",
    "Libraries/Frameworks/libglslang.16.dylib":
        "Libraries/Frameworks/libglslang.16.dylib",
    "Libraries/Frameworks/libshaderc.dylib":
        "Libraries/Frameworks/libshaderc.dylib",
    "Libraries/Frameworks/libshaderc_impl.dylib":
        "Libraries/Frameworks/libshaderc_impl.dylib",
    "Libraries/Frameworks/libspirv-cross.dylib":
        "Libraries/Frameworks/libspirv-cross.dylib",
    "Libraries/Frameworks/libfreetype.dylib":
        "Libraries/Frameworks/libfreetype.dylib",
    "Libraries/Frameworks/libmetallum.dylib":
        "Libraries/Frameworks/libmetallum.dylib",
    "Libraries/Frameworks/libglapi.0.dylib":
        "Libraries/Frameworks/libglapi.0.dylib",
    "Libraries/Frameworks/libvulkan.1.dylib":
        "Libraries/Frameworks/libvulkan.1.dylib",

    # ---- LWJGL 3.3.3 ----
    "Libraries/Jars/lwjgl-333/lwjgl.jar": "JavaApp/libs/lwjgl-333/lwjgl.jar",
    "Libraries/Jars/lwjgl-333/lwjgl-glfw.jar": "JavaApp/libs/lwjgl-333/lwjgl-glfw.jar",
    "Libraries/Jars/lwjgl-333/lwjgl-opengl.jar": "JavaApp/libs/lwjgl-333/lwjgl-opengl.jar",
    "Libraries/Jars/lwjgl-333/lwjgl-openal.jar": "JavaApp/libs/lwjgl-333/lwjgl-openal.jar",
    "Libraries/Jars/lwjgl-333/lwjgl-stb.jar": "JavaApp/libs/lwjgl-333/lwjgl-stb.jar",
    "Libraries/Jars/lwjgl-333/lwjgl-tinyfd.jar": "JavaApp/libs/lwjgl-333/lwjgl-tinyfd.jar",
    "Libraries/Jars/lwjgl-333/lwjgl-vma.jar": "JavaApp/libs/lwjgl-333/lwjgl-vma.jar",
    "Libraries/Jars/lwjgl-333/lwjgl-nanovg.jar": "JavaApp/libs/lwjgl-333/lwjgl-nanovg.jar",
    "Libraries/Jars/lwjgl-333/lwjgl-shaderc.jar": "JavaApp/libs/lwjgl-333/lwjgl-shaderc.jar",
    "Libraries/Jars/lwjgl-333/lwjgl-spvc.jar": "JavaApp/libs/lwjgl-333/lwjgl-spvc.jar",
    "Libraries/Jars/lwjgl-333/lwjgl-freetype.jar": "JavaApp/libs/lwjgl-333/lwjgl-freetype.jar",
    "Libraries/Jars/lwjgl-333/lwjgl-vulkan.jar": "JavaApp/libs/lwjgl-333/lwjgl-vulkan.jar",
    "Libraries/Jars/lwjgl-333/lwjgl-lwjglx.jar": "JavaApp/libs/lwjgl-333/lwjgl-lwjglx.jar",

    # ---- LWJGL 3.4.1 ----
    "Libraries/Jars/lwjgl-341/lwjgl.jar": "JavaApp/libs/lwjgl-341/lwjgl.jar",
    "Libraries/Jars/lwjgl-341/lwjgl-glfw.jar": "JavaApp/libs/lwjgl-341/lwjgl-glfw.jar",
    "Libraries/Jars/lwjgl-341/lwjgl-opengl.jar": "JavaApp/libs/lwjgl-341/lwjgl-opengl.jar",

    # ---- 陶瓦联机 ----
    "Libraries/terracotta/libterracotta.xcframework/Info.plist":
        "Libraries/terracotta/libterracotta.xcframework/Info.plist",
    "Libraries/terracotta/libterracotta.xcframework/ios-arm64/Headers/terracotta.h":
        "Libraries/terracotta/libterracotta.xcframework/ios-arm64/Headers/terracotta.h",
    "Libraries/terracotta/libterracotta.xcframework/ios-arm64/libterracotta.a":
        "Libraries/terracotta/libterracotta.xcframework/ios-arm64/libterracotta.a",
}


def fetch_expected_sizes():
    """从 Air1 仓库的 tree 接口拿所有文件的准确大小"""
    url = f"https://api.github.com/repos/{REPO}/git/trees/{BRANCH}?recursive=1"
    token = os.environ.get("GITHUB_TOKEN", "")

    req = urllib.request.Request(url)
    req.add_header("Accept", "application/vnd.github+json")
    if token:
        req.add_header("Authorization", f"token {token}")

    with urllib.request.urlopen(req, timeout=120) as resp:
        data = json.load(resp)

    return {x["path"]: x.get("size", 0) for x in data["tree"] if x["type"] == "blob"}


def download(local_rel, air1_path, expected):
    """下载单个文件，返回 (成功, 说明)"""
    dest = os.path.join(ROOT, local_rel)
    os.makedirs(os.path.dirname(dest), exist_ok=True)

    for mirror in MIRRORS:
        url = f"{mirror}/{REPO}/{BRANCH}/{air1_path}"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Air2-fetch-deps"})
            with urllib.request.urlopen(req, timeout=900) as resp:
                data = resp.read()

            # 关键：按【准确大小】校验，不是"大于阈值"
            if len(data) != expected:
                continue

            with open(dest, "wb") as f:
                f.write(data)
            return True, f"{len(data):,} bytes"

        except Exception:
            continue

    return False, "所有源都失败或截断"


def main():
    check_only = "--check" in sys.argv

    print("==> 获取依赖清单大小")
    try:
        sizes = fetch_expected_sizes()
    except Exception as e:
        print(f"    失败：{e}")
        print("    （需要网络；也可设 GITHUB_TOKEN 提高限额）")
        return 1

    print(f"    Air1 仓库共 {len(sizes)} 个文件\n")

    ok = 0
    failed = []
    skipped = 0

    for local_rel, air1_path in sorted(DEPENDENCIES.items()):
        expected = sizes.get(air1_path)
        if not expected:
            print(f"  ? {local_rel}（Air1 里找不到）")
            continue

        dest = os.path.join(ROOT, local_rel)
        cur = os.path.getsize(dest) if os.path.exists(dest) else 0

        if cur == expected:
            ok += 1
            if check_only:
                print(f"  ✓ {os.path.basename(local_rel)}")
            continue

        if check_only:
            which = "缺失" if cur == 0 else f"不完整 {cur:,}/{expected:,}"
            print(f"  ✗ {os.path.basename(local_rel)}（{which}）")
            failed.append(local_rel)
            continue

        name = os.path.basename(local_rel)
        print(f"  ↓ {name} ... ", end="", flush=True)
        success, detail = download(local_rel, air1_path, expected)
        if success:
            print(detail)
            ok += 1
        else:
            print(detail)
            failed.append(local_rel)

    print(f"\n=== 结果 ===")
    print(f"  完整: {ok}")
    if failed:
        print(f"  失败: {len(failed)}")
        for f in failed:
            print(f"    {f}")
        return 1

    print("  ✓ 全部完整")
    return 0


if __name__ == "__main__":
    sys.exit(main())
