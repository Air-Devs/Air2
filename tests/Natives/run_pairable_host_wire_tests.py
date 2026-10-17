#!/usr/bin/env python3
"""
Air2 tests/Natives —— ★pairable-host 线上契约（[A2-PAIRPIN]）单测运行器★

做什么：
  用 clang 把 Natives/Support 的【真实实现】a2_rppairing_pairable_host_wire.m
  与 tests/Natives/pairable_host_wire_tests.m 一起编译成 macOS 可执行文件并运行，
  输出每例 PASS/FAIL 与末尾计数。

为什么是【真编译 + 真运行】而不是源码扫描：
  「帧长度是不是大端」「信封能不能往返」「握手响应里 allowsPinlessPairing 是不是 NO」
  都是**行为**。源码扫描只能证明文字在文件里；只有把纯函数真跑一遍，才能证明
  「设备该弹输码框」那条声明确实成立。

  为什么能在 macOS 上跑：被测文件只依赖 Foundation（无 Network.framework、无 socket、
  无 iOS SDK 私有符号）⇒ 无需真机即可编、即可跑。★真机互操作（设备是否真弹码框）不在此证明★。

用法：
    python3 tests/Natives/run_pairable_host_wire_tests.py

退出码：0 = 全部通过；1 = 有 FAIL 或工具链/编译失败。
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # 仓根

# 被测的【真实】源文件（只用 Foundation ⇒ 能在 macOS 上直接编、直接跑）。
SOURCES = [
    os.path.join(ROOT, "Natives", "Support", "a2_rppairing_pairable_host_wire.m"),  # ★被测主体★
    os.path.join(HERE, "pairable_host_wire_tests.m"),
]

INCLUDE_DIRS = [
    os.path.join(ROOT, "Natives", "Support"),
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

    tmpdir = tempfile.mkdtemp(prefix="a2pairpin_tests_")
    binary = os.path.join(tmpdir, "pairable_host_wire_tests")

    includes = []
    for inc in INCLUDE_DIRS:
        includes += ["-I", inc]
    cmd = [clang, "-fobjc-arc", "-fblocks", "-Wall", "-Wno-unused-parameter"] + includes + \
          ["-framework", "Foundation", "-o", binary] + SOURCES
    print("compile: clang -fobjc-arc -I Natives/Support ... -o pairable_host_wire_tests")
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
    if passed < 25:
        print("[runner] 用例数 %d < 25（本单要求 ≥25 例）⇒ 视为失败" % passed)
        return 1
    print("[runner] 全部通过 ✓（%d 例）" % passed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
