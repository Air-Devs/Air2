#!/usr/bin/env python3
"""
Air2 tests/Instance —— 「已安装的版本实例」落位路径单测运行器（★仓内测试入口★）。

做什么：
  用 clang 把 Air2/Core/Path、Air2/Utils 下的【真实实现】
  与 tests/Instance/instance_path_tests.m 一起编译成 macOS 可执行文件并运行，
  输出每例 PASS/FAIL 与末尾计数。

为什么是【真编译 + 真运行】而不是源码扫描：
  「装完之后 versions/<id>/ 里真的有一个可用实例、启动路径认到的是同一份」是行为问题。
  源码扫描只能证明「文字在文件里」；只有把 A2GamePath 真的跑一遍、真的在临时游戏目录里
  落盘再判存在，才能证明「写入的那条路径 == 启动判存在的那条路径」。

用法：
    python3 tests/Instance/run_instance_tests.py

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
    os.path.join(ROOT, "Air2", "Core", "Path", "A2VersionIsolation.m"),  # 实例路径唯一计算处
    os.path.join(ROOT, "Air2", "Utils", "A2Log.m"),                      # 判据行的日志门面
    os.path.join(HERE, "instance_path_tests.m"),
]

# 头搜索路径：被测文件按「裸文件名」互相 import（仓内既有写法）。
INCLUDE_DIRS = [
    os.path.join(ROOT, "Air2", "Core", "Path"),
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

    tmpdir = tempfile.mkdtemp(prefix="a2inst_tests_")
    binary = os.path.join(tmpdir, "instance_path_tests")

    includes = []
    for inc in INCLUDE_DIRS:
        includes += ["-I", inc]
    cmd = [clang, "-fobjc-arc", "-Wall", "-Wno-unused-parameter"] + includes + \
          ["-framework", "Foundation", "-framework", "CoreFoundation",
           "-o", binary] + SOURCES
    print("compile: clang -fobjc-arc -I Air2/{Core/Path,Utils} ... "
          "-o instance_path_tests")
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
