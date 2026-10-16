#!/usr/bin/env python3
"""
Air2 tests/Plan —— 启动计划「运行时事实」单测运行器（★仓内测试入口★）。

做什么：
  用 clang 把 Air2/Core/Version 与 Air2/Utils 下的【真实实现】与
  tests/Plan/plan_runtime_facts_tests.m 一起编译成 macOS 可执行文件并运行，
  输出每例 PASS/FAIL 与末尾计数。

为什么是【真编译 + 真运行】而不是源码扫描：
  本单要修的卡点是「两个 JVM 系统属性没人下发 ⇒ 装载 GLFW 类时 NPE」。
  源码扫描只能证明代码「看起来会」产出那两条 -D；
  只有把 A2LaunchPlan/A2LaunchRuntimeFacts 真的跑一遍、把字符串真的拼出来，
  才能证明「产出的字符串就是 GLFW.java 能吃掉的那一个」。

用法：
    python3 tests/Plan/run_plan_tests.py

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

# 被测的【真实】源文件（Core 的计划产出 + Utils 的值对象/契约常量/日志门面）。
# 全部只依赖 Foundation（★不含 UIKit★），所以能在 macOS 上直接编、直接跑。
SOURCES = [
    os.path.join(ROOT, "Air2", "Core", "Version", "A2LaunchPlan.m"),
    os.path.join(ROOT, "Air2", "Utils", "A2LaunchMemory.m"),   # 本单：计划现在依赖它做 Java 档位判据
    os.path.join(ROOT, "Air2", "Utils", "A2LaunchRuntimeFacts.m"),
    os.path.join(ROOT, "Air2", "Utils", "A2LaunchContract.m"),
    os.path.join(ROOT, "Air2", "Utils", "A2Log.m"),      # 计划里记日志的门面（随包真实实现）
    os.path.join(HERE, "plan_runtime_facts_tests.m"),
]

# 头搜索路径：被测文件按「裸文件名」互相 import（仓内既有写法）。
INCLUDE_DIRS = [
    os.path.join(ROOT, "Air2", "Utils"),
    os.path.join(ROOT, "Air2", "Core", "Version"),
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

    tmpdir = tempfile.mkdtemp(prefix="a2plan_tests_")
    binary = os.path.join(tmpdir, "plan_runtime_facts_tests")

    includes = []
    for inc in INCLUDE_DIRS:
        includes += ["-I", inc]
    cmd = [clang, "-fobjc-arc", "-Wall", "-Wno-unused-parameter"] + includes + \
          ["-framework", "Foundation", "-framework", "CoreFoundation",
           "-o", binary] + SOURCES
    print("compile: clang -fobjc-arc -I Air2/{Utils,Core/Version} ... -o plan_runtime_facts_tests")
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
