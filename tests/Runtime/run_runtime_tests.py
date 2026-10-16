#!/usr/bin/env python3
"""
Air2 tests/Runtime —— 渲染器 / Java 运行时「两张列表」单测运行器（★仓内测试入口★）。

做什么：
  用 clang 把 Air2/Core/Renderer、Air2/Core/Version、Air2/Player 下的【真实实现】
  与 tests/Runtime/runtime_selection_tests.m 一起编译成 macOS 可执行文件并运行，
  输出每例 PASS/FAIL 与末尾计数。

为什么是【真编译 + 真运行】而不是源码扫描：
  「设置里各能看到哪几项、选每项分别会发生什么」是行为问题。源码扫描只能证明
  「文字在文件里」；只有把候选表、包内存在性判定、四语文案表真的跑一遍，
  才能证明「列表里就是这些项、未内置的真的会被判出来」。

用法：
    python3 tests/Runtime/run_runtime_tests.py

退出码：0 = 全部通过；1 = 有 FAIL 或工具链/编译失败。
（Windows 无 clang 时本脚本无法运行，属预期；请在 Mac 上跑。）
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # 仓根

# 被测的【真实】源文件（全部只依赖 Foundation ⇒ 能在 macOS 上直接编、直接跑）。
SOURCES = [
    os.path.join(ROOT, "Air2", "Core", "Renderer", "A2Renderer.m"),         # 既有：值对象 + 注册表
    os.path.join(ROOT, "Air2", "Core", "Renderer", "A2RendererCatalog.m"),  # 候选表 + 包内存在性
    os.path.join(ROOT, "Air2", "Core", "Renderer", "A2RenderScaleCatalog.m"),# ★[FRAME-PERF] 渲染分辨率倍率候选表★
    os.path.join(ROOT, "Air2", "Core", "Version", "A2JavaRuntimeCatalog.m"),# JRE 候选表 + 可用性
    os.path.join(ROOT, "Air2", "Player", "A2RuntimeStrings.m"),             # 四语文案表
    os.path.join(HERE, "runtime_selection_tests.m"),
]

# 头搜索路径：被测文件按「裸文件名」互相 import（仓内既有写法）。
INCLUDE_DIRS = [
    os.path.join(ROOT, "Air2", "Core", "Renderer"),
    os.path.join(ROOT, "Air2", "Core", "Version"),
    os.path.join(ROOT, "Air2", "Player"),
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

    tmpdir = tempfile.mkdtemp(prefix="a2rt_tests_")
    binary = os.path.join(tmpdir, "runtime_selection_tests")

    includes = []
    for inc in INCLUDE_DIRS:
        includes += ["-I", inc]
    cmd = [clang, "-fobjc-arc", "-Wall", "-Wno-unused-parameter"] + includes + \
          ["-framework", "Foundation", "-framework", "CoreFoundation",
           "-o", binary] + SOURCES
    print("compile: clang -fobjc-arc -I Air2/{Core/Renderer,Core/Version,Player} ... "
          "-o runtime_selection_tests")
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

    passed = sum(1 for ln in out.splitlines() if ln.startswith("PASS"))
    failed = sum(1 for ln in out.splitlines() if ln.startswith("FAIL"))
    print("\n[runner] 解析结果：PASS=%d FAIL=%d" % (passed, failed))

    if failed or run.returncode != 0:
        return 1
    if passed == 0:
        print("[runner] 未解析到任何用例，视为失败")
        return 1
    print("[runner] 全部通过 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
