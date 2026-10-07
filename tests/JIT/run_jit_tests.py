#!/usr/bin/env python3
"""
A2 JIT 纯逻辑单元测试 —— 一键运行器（★仓内测试入口★）。

做什么：
  用 clang 把 Air2/Player 下的【真实】纯逻辑源文件与 tests/JIT/jit_logic_tests.m
  一起编译成 macOS 可执行文件并运行，输出每例 PASS/FAIL 与末尾计数。

为什么是真编译而不是 Python 镜像：
  版本隔离那套测试用 Python 镜像，是因为当年 iSH 里没有 ObjC 编译器。
  本机（Mac）有 clang + Foundation，可以直接编译【被测的真实实现】——这严格强于镜像。

用法：
    python3 tests/JIT/run_jit_tests.py

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
PLAYER = os.path.join(ROOT, "Air2", "Player")

# 被测的【真实】源文件（纯逻辑，无 UIKit）。
SOURCES = [
    os.path.join(PLAYER, "A2JITProvider.m"),
    os.path.join(PLAYER, "A2JITFacts.m"),
    os.path.join(PLAYER, "A2JITStrategySelector.m"),
    os.path.join(PLAYER, "A2PairingFile.m"),
    os.path.join(PLAYER, "A2JITStateMachine.m"),
    os.path.join(HERE, "jit_logic_tests.m"),
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

    tmpdir = tempfile.mkdtemp(prefix="a2jit_tests_")
    binary = os.path.join(tmpdir, "jit_logic_tests")

    cmd = [clang, "-fobjc-arc", "-fblocks", "-Wall", "-Wno-unused-parameter",
           "-I", PLAYER, "-framework", "Foundation", "-o", binary] + SOURCES
    print("compile: clang -fobjc-arc -I Air2/Player ... -o jit_logic_tests")
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
