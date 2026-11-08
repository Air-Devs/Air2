#!/usr/bin/env python3
"""
Air2 tests/Core —— ★卡片来源解析（内置 / 插件 / 不可用三态）单测★ 运行器。

做什么：
  用 clang 把【仓内真实实现】Air2/Core/Home/A2HomeCardSource.m
  （+ 它依赖的 A2HomeLayout.m / A2Log.m）与 tests/Core/home_card_source_tests.m
  一起编译成 macOS 可执行文件并运行，打印每例 PASS/FAIL 与末尾计数。

为什么是【真编译 + 真运行】而不是源码扫描：
  本单要钉的是「插件停用/卸载/贡献被删 ⇒ 返回占位而不是删卡」「卸载优先于残留的
  停用标记」「未知 kind 不崩」这些**行为**。源码扫描只能证明代码里出现过这些字样，
  只有把 resolver 与快照真的跑一遍、把卡片 JSON 前后比一遍，才能证明「不删卡」成立。

用法：
    python3 tests/Core/run_home_card_source_tests.py

退出码：0 = 全部通过；1 = 有 FAIL 或工具链/编译失败。
（Windows 无 clang 时本脚本无法运行，属预期；请在 Mac 上跑。）
构建机（Linux 交叉编译）只能做类型检查，见文件末尾说明。
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # 仓根

# 被测的【真实】源文件。三者都只依赖 Foundation（不含 UIKit），所以能在 macOS 上直接编、直接跑。
SOURCES = [
    os.path.join(ROOT, "Air2", "Core", "Home", "A2HomeCardSource.m"),
    os.path.join(ROOT, "Air2", "Core", "Home", "A2HomeLayout.m"),
    os.path.join(ROOT, "Air2", "Utils", "A2Log.m"),
    os.path.join(HERE, "home_card_source_tests.m"),
]

INCLUDE_DIRS = [
    os.path.join(ROOT, "Air2", "Core", "Home"),
    os.path.join(ROOT, "Air2", "Utils"),
]


def find_clang():
    clang = shutil.which("clang")
    if clang:
        return clang
    xcrun = shutil.which("xcrun")
    if xcrun:
        try:
            out = subprocess.run([xcrun, "-f", "clang"], capture_output=True, text=True)
            if out.returncode == 0 and out.stdout.strip():
                return out.stdout.strip()
        except Exception:
            pass
    return None


def main():
    for src in SOURCES:
        if not os.path.exists(src):
            print("缺少源文件: %s" % src)
            return 1

    clang = find_clang()
    if not clang:
        print("找不到 clang（本测试需在装有 Xcode 命令行工具的 macOS 上运行）")
        return 1
    print("clang = %s" % clang)

    tmpdir = tempfile.mkdtemp(prefix="a2cardsrc_tests_")
    binary = os.path.join(tmpdir, "home_card_source_tests")

    includes = []
    for inc in INCLUDE_DIRS:
        includes += ["-I", inc]
    cmd = [clang, "-fobjc-arc", "-Wall", "-Wno-unused-parameter"] + includes + \
          ["-framework", "Foundation", "-framework", "CoreFoundation",
           "-o", binary] + SOURCES
    print("compile: clang -fobjc-arc -I Air2/{Core/Home,Utils} ... -o home_card_source_tests")
    ci = subprocess.run(cmd, capture_output=True, text=True)
    if ci.stderr.strip():
        print("--- clang 输出 ---")
        print(ci.stderr.strip())
    if ci.returncode != 0:
        print("!! 编译失败（rc=%d）" % ci.returncode)
        return 1

    print("run: %s\n" % binary)
    run = subprocess.run([binary], capture_output=True, text=True)
    out = run.stdout + run.stderr
    sys.stdout.write(out)

    failed = sum(1 for ln in out.splitlines() if ln.startswith("FAIL"))
    checks = 0
    for ln in out.splitlines():
        if ln.startswith("__HOME_CARD_SOURCE_CHECKS="):
            try:
                checks = int(ln.split("=", 1)[1])
            except ValueError:
                checks = 0
    print("\n[runner] 解析结果：CHECK=%d FAIL=%d" % (checks, failed))

    if failed or run.returncode != 0:
        return 1
    if checks == 0:
        print("[runner] 未解析到任何断言，视为失败")
        return 1
    print("[runner] 全部通过 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
