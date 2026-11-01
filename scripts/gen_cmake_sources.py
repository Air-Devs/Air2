#!/usr/bin/env python3
"""把「参与编译的源清单」翻译成 CMake 变量文件。

★为什么存在★
  清单的真源头只有一个：scripts/gen_xcodeproj.py 的 scan_sources()（扫 Air2/ 与
  Natives/ 下的 .m/.mm）。CMake 侧若另写一份 GLOB 或手抄列表，两边必然分叉 ——
  「Xcode 编得进、CMake 编不进」（或反之）是最难查的一类问题。
  所以这里 import 那个模块、调它的函数，只做「格式转换」，不做第二套扫描逻辑。

调用点（谁执行它）：
  cmake/a2_sources_bootstrap.cmake:25-26  execute_process(... gen_cmake_sources.py --output ...)
  （由根 CMakeLists.txt:30 与 Natives/CMakeLists.txt:28 各自 include 那个 bootstrap）

用法：
    python3 scripts/gen_cmake_sources.py --output build/cmake/a2_sources.cmake
    python3 scripts/gen_cmake_sources.py --json          # 给工具/调试看

产物内容（全部由 gen_xcodeproj.py 的既有常量/函数推导，无第二份清单）：
    A2_APP_SOURCES / A2_NATIVE_SOURCES   编译单元（按 Air2/ 与 Natives/ 分开）
    A2_INCLUDE_DIRS                      等价 Xcode 的 header map（裸文件名可解析）
    A2_UNDEFINED_SYMS                    联机库 libterracotta 的可选符号放行
    A2_MBEDTLS_LIB_DIR / A2_MBEDTLS_LIBS 第三方静态库
    A2_GEN_*                             版本/部署目标（供 CMake 侧一致性校验）
    A2_RESOURCE_PATHS                    随包资源（Assets/，含 JIT 脚本）
"""
import argparse
import importlib.util
import json
import os
import sys

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SCRIPTS_DIR)


def _load_gen_xcodeproj():
    """按文件路径加载生成器模块（文件名不是合法包名，不能普通 import）。

    注意：该模块顶层会跑一次 `git rev-parse --short=7 HEAD`（求 CFBundleVersion），
    只是读操作、失败也会退化成 "0"，因此加载它没有副作用。
    """
    path = os.path.join(SCRIPTS_DIR, "gen_xcodeproj.py")
    spec = importlib.util.spec_from_file_location("a2_gen_xcodeproj", path)
    if spec is None or spec.loader is None:
        raise SystemExit("gen_cmake_sources: 无法加载 %s" % path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _include_dirs(headers):
    """由头文件所在目录推导头搜索路径 —— 对齐 Xcode 的 header map。

    为什么不是「只加 Natives 那 5 个目录」：Air2/ 内部同样按裸文件名互相
    #import（如 "A2Log.h"、"A2Paths.h"），Xcode 靠 USE_HEADERMAP=YES 解析；
    CMake 没有 header map，只能把所有含头文件的目录都塞进 -I。
    浅目录优先、仓库根放最后：越靠前的 -I 越先命中，结果稳定可复现。
    ⚠ 前提：头文件 basename 全局唯一 —— _assert_unique_basenames() 硬校验。
    """
    dirs = {os.path.dirname(h) for h in headers}
    dirs.add("Natives")                                    # jni.h 在 Natives/ 根
    dirs.add("Libraries/ThirdParty/mbedtls/include")       # <mbedtls/ssl.h>
    out = sorted(dirs, key=lambda d: (d.count("/"), d))
    out.append(".")                                        # "Air2/Core/xxx.h" 形式
    return out


def collect(mod):
    impl, headers = mod.scan_sources()
    if not impl:
        raise SystemExit("gen_cmake_sources: gen_xcodeproj.scan_sources() 返回空清单")

    app, native = [], []
    for f in impl:
        (native if f.startswith("Natives/") else app).append(f)

    _assert_unique_basenames(headers)

    inc = _include_dirs(headers)

    # mbedTLS：从 gen_xcodeproj.MBEDTLS_LDFLAGS 解析（-L<dir> / -l<name>），
    # 不另抄一份库名，避免与 Xcode 侧的链接顺序分叉。
    lib_dir, libs = None, []
    for item in mod.MBEDTLS_LDFLAGS:
        item = item.replace("$(SRCROOT)/", "")
        if item.startswith("-L"):
            lib_dir = item[2:]
        elif item.startswith("-l"):
            libs.append(item[2:])

    return {
        "app_sources": app,
        "native_sources": native,
        "headers": headers,
        "include_dirs": inc,
        "undefined_syms": list(mod.TERRACOTTA_UNDEFINED_SYMS),
        "mbedtls_lib_dir": lib_dir,
        "mbedtls_libs": libs,
        "resources": list(mod.collect_resources()),
        "deployment_target": mod.DEPLOYMENT_TARGET,
        "bundle_id": mod.BUNDLE_ID,
        "build_version": mod.BUILD_VERSION,
        "marketing_version": mod.MARKETING_VERSION,
        "project_name": mod.PROJECT_NAME,
    }


def _assert_unique_basenames(headers):
    """include 目录法是「裸文件名解析」的近似实现，basename 撞名就会静默取错头。

    撞名时宁可在这里炸掉（给出同名的几个路径），也不要让 CMake 悄悄编过头。
    """
    seen = {}
    for h in headers:
        seen.setdefault(os.path.basename(h), []).append(h)
    dups = {k: v for k, v in seen.items() if len(v) > 1}
    if dups:
        lines = ["同名头文件会在 -I 目录法下互相遮蔽（Xcode 的 header map 同样有歧义）："]
        for name, paths in sorted(dups.items()):
            lines.append("  %s: %s" % (name, ", ".join(sorted(paths))))
        raise SystemExit("gen_cmake_sources: " + "\n".join(lines))


def _cmake_list(items, indent="    "):
    if not items:
        return ""
    return "\n" + "\n".join('%s"%s"' % (indent, i) for i in items)


def render_cmake(d):
    L = []
    add = L.append
    add("# 本文件由 scripts/gen_cmake_sources.py 生成，请勿手改（改源清单请改磁盘/生成器）。")
    add("# 源清单真源头：scripts/gen_xcodeproj.py 的 scan_sources()。")
    add("")
    add("set(A2_APP_SOURCES%s)" % _cmake_list(d["app_sources"]))
    add("set(A2_NATIVE_SOURCES%s)" % _cmake_list(d["native_sources"]))
    add("set(A2_INCLUDE_DIRS%s)" % _cmake_list(d["include_dirs"]))
    add("set(A2_UNDEFINED_SYMS%s)" % _cmake_list(d["undefined_syms"]))
    add("set(A2_MBEDTLS_LIBS%s)" % _cmake_list(d["mbedtls_libs"]))
    add('set(A2_MBEDTLS_LIB_DIR "%s")' % (d["mbedtls_lib_dir"] or ""))
    add("set(A2_RESOURCE_PATHS%s)" % _cmake_list(d["resources"]))
    add('set(A2_GEN_PROJECT_NAME "%s")' % d["project_name"])
    add('set(A2_GEN_DEPLOYMENT_TARGET "%s")' % d["deployment_target"])
    add('set(A2_GEN_BUNDLE_ID "%s")' % d["bundle_id"])
    add('set(A2_GEN_BUILD_VERSION "%s")' % d["build_version"])
    add('set(A2_GEN_MARKETING_VERSION "%s")' % d["marketing_version"])
    add("")
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", help="写出 CMake 变量文件（缺省打到 stdout）")
    ap.add_argument("--json", action="store_true", help="以 JSON 输出（调试/工具用）")
    args = ap.parse_args()

    d = collect(_load_gen_xcodeproj())

    if args.json:
        text = json.dumps({k: v for k, v in d.items() if k != "headers"},
                          ensure_ascii=False, indent=2) + "\n"
    else:
        text = render_cmake(d)

    if args.output:
        out = args.output
        os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
        with open(out, "w", newline="\n") as f:
            f.write(text)
    else:
        sys.stdout.write(text)

    sys.stderr.write(
        "[gen_cmake_sources] 编译单元 %d（Air2/ %d + Natives/ %d），头文件 %d，-I 目录 %d\n"
        % (len(d["app_sources"]) + len(d["native_sources"]),
           len(d["app_sources"]), len(d["native_sources"]),
           len(d["headers"]), len(d["include_dirs"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
