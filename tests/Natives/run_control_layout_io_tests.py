#!/usr/bin/env python3
"""
Air2 tests/Natives —— 控件布局多格式导入单测运行器（★仓内测试入口★）。

做什么：
  用 clang 把 Natives/Input 下的【真实实现】（A2ControlLayoutIO / A2KeyCodeMap）
  与 tests/Natives/control_layout_io_tests.m 一起编译成 macOS 可执行文件并运行，
  输出每例 PASS/FAIL 与末尾计数。

为什么是【真编译 + 真运行】而不是源码扫描：
  「FCL 的 evdev 键码 17 真的换算成了 GLFW 的 W(87)」「ZL2 的百分比尺寸
  真的按参考屏幕高折算」是行为问题。源码扫描只能证明字符串在文件里；
  只有把真实实现跑一遍才能证明导入后的键位与几何真的对得上。

用法：
    python3 tests/Natives/run_control_layout_io_tests.py

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
    os.path.join(ROOT, "Natives", "Input", "A2ControlLayoutIO.m"),
    os.path.join(ROOT, "Natives", "Input", "A2KeyCodeMap.m"),
    # 导入失败分支会走统一日志门面，必须随包真实实现
    os.path.join(ROOT, "Natives", "Support", "a2_log.m"),
    os.path.join(HERE, "control_layout_io_tests.m"),
]

# 头搜索路径：被测文件按「裸文件名」互相 import（仓内既有写法）。
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

    tmpdir = tempfile.mkdtemp(prefix="a2ctl_layout_tests_")
    binary = os.path.join(tmpdir, "control_layout_io_tests")

    includes = []
    for inc in INCLUDE_DIRS:
        includes += ["-I", inc]
    cmd = [clang, "-fobjc-arc", "-Wall", "-Wno-unused-parameter"] + includes + \
          ["-framework", "Foundation", "-o", binary] + SOURCES
    print("compile: clang -fobjc-arc -I Natives/{Input,Support} ... "
          "-o control_layout_io_tests")
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
