#!/usr/bin/env python3
"""
Air2 tests/Natives —— ★帧性能判据（a2_frame_perf）单测运行器★（仓内测试入口）。

做什么：
  用 clang 把 Natives/Renderer 的【真实实现】(a2_frame_perf) 与 Natives/Support 的日志实现，
  跟 tests/Natives/frame_perf_tests.m 一起编译成 macOS 可执行文件并运行，
  输出每例 PASS/FAIL 与末尾计数。

为什么是【真编译 + 真运行】而不是源码扫描：
  「行里有没有 fps/帧时间/draw/纹理估值/着色器新建/相位/缩放像素」「CPU 帧时间是不是量到的」
  都是**行为**。只有把 a2_frame_perf 真跑一遍，才能证明那行 `[FRAME] …` 真的是这些字段、
  缩放真的落在像素上。

  为什么能在 macOS 上跑：本模块只做计数与墙钟差分，不碰图形上下文、不链接图形库。

用法：
    python3 tests/Natives/run_frame_perf_tests.py

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

# 被测的【真实】源文件（只用 Foundation ⇒ 能在 macOS 上直接编、直接跑）。
SOURCES = [
    os.path.join(ROOT, "Natives", "Renderer", "a2_frame_perf.m"),   # ★被测主体★
    os.path.join(ROOT, "Natives", "Support", "a2_log.m"),           # 日志实现（判据行出口）
    os.path.join(HERE, "frame_perf_tests.m"),
]

# 头搜索路径：Natives 代码按「裸文件名」互相 import（仓内既有写法）。
INCLUDE_DIRS = [
    os.path.join(ROOT, "Natives", "Renderer"),
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

    tmpdir = tempfile.mkdtemp(prefix="a2fp_tests_")
    binary = os.path.join(tmpdir, "frame_perf_tests")

    includes = []
    for inc in INCLUDE_DIRS:
        includes += ["-I", inc]
    cmd = [clang, "-fobjc-arc", "-fblocks", "-Wall", "-Wno-unused-parameter"] + includes + \
          ["-framework", "Foundation", "-o", binary] + SOURCES
    print("compile: clang -fobjc-arc -I Natives/{Renderer,Support} ... -o frame_perf_tests")
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
