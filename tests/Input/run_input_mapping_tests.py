#!/usr/bin/env python3
"""
Air2 tests/Input —— 统一输入映射层 [INPUT-MAP-1] 单测运行器（★仓内测试入口★）。

做什么：
  用 clang 把 Natives/Input 下的【真实实现】与 tests/Input/input_mapping_tests.m
  一起编译成 macOS 可执行文件并运行，输出每例 PASS/FAIL 与末尾计数。

为什么是【真编译 + 真运行】而不是源码扫描：
  「按下 → 查绑定 → 投递 → 松开」是一条状态机。卡键（松手还在走）、双触发
  （按一下跳两下）、改绑后旧键抬不起来，这三类问题都只在状态机真的跑起来时才
  暴露；源码扫描连「引用计数是不是对的」都答不了。

★测试边界★：
  只链接「不依赖 UIKit / JVM」的源文件 —— 映射层、绑定表、键盘源都是 Foundation 级，
  所以能在 macOS 上直接编、直接跑。窗口层（a2_glfw_input.m）要 UIKit，不在此列；
  它接映射层的那几行由 scripts/lint_objc.py + 真机构建把关。

用法：
    python3 tests/Input/run_input_mapping_tests.py

退出码：0 = 全部通过；1 = 有 FAIL 或编译失败。
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
    os.path.join(ROOT, "Natives", "Input", "A2InputTypes.m"),
    os.path.join(ROOT, "Natives", "Input", "A2InputBinding.m"),
    os.path.join(ROOT, "Natives", "Input", "A2InputRouter.m"),
    os.path.join(ROOT, "Natives", "Input", "A2KeyboardInputSource.m"),
    os.path.join(ROOT, "Natives", "Input", "A2VirtualButtonInputSource.m"),
    os.path.join(ROOT, "Natives", "Input", "A2GamepadInputSource.m"),
    os.path.join(ROOT, "Natives", "Support", "a2_log.m"),   # 映射层的日志门面（判据行落点）
    os.path.join(HERE, "input_mapping_tests.m"),
]

INCLUDE_DIRS = [
    os.path.join(ROOT, "Natives", "Input"),
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

    tmpdir = tempfile.mkdtemp(prefix="a2input_tests_")
    binary = os.path.join(tmpdir, "input_mapping_tests")

    includes = []
    for inc in INCLUDE_DIRS:
        includes += ["-I", inc]
    cmd = [clang, "-fobjc-arc", "-Wall", "-Wno-unused-parameter"] + includes + \
          ["-framework", "Foundation", "-o", binary] + SOURCES
    print("compile: clang -fobjc-arc -I Natives/{Input,Support} ... -o input_mapping_tests")
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
