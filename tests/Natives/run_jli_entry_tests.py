#!/usr/bin/env python3
"""
Air2 tests/Natives —— ★JLI 入口纯逻辑（a2_jli_entry）单测运行器★（仓内测试入口）。

做什么：
  用 clang 把 Natives/Context 的【真实实现】a2_jli_entry.m 与
  tests/Natives/jli_entry_tests.m 一起编译成 macOS 可执行文件并运行，
  输出每例 PASS/FAIL 与末尾计数。

为什么是【真编译 + 真运行】而不是源码扫描：
  「JLI_Launch 到底收到什么命令行」是行为 —— 选项顺序、classpath 是否被注入两次、
  程序参数（`--plan` / `-jar`）有没有被吞、空 classpath 会不会变成 `-cp ""`、
  特殊字符有没有被改动。源码扫描只能证明代码里写了 if；只有把 argv 真组出来、
  逐位比对，才能证明真机上主类能找到、参数能到。

  为什么能在 macOS 上跑：a2_jli_entry.m 不 import jni.h、不 dlopen、不写日志、
  不读环境变量（纯 Foundation 逻辑）⇒ 无需 iOS/JRE 环境即可编、即可跑。
  dlopen(libjli)/JLI_Launch 的调用与 J1/J2/J3 判据行属真机判定表项。

用法：
    python3 tests/Natives/run_jli_entry_tests.py

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
    os.path.join(ROOT, "Natives", "Context", "a2_jli_entry.m"),   # ★被测主体★
    os.path.join(HERE, "jli_entry_tests.m"),
]

# 头搜索路径：Natives 代码按「裸文件名」互相 import（仓内既有写法）。
INCLUDE_DIRS = [
    os.path.join(ROOT, "Natives", "Context"),
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

    tmpdir = tempfile.mkdtemp(prefix="a2jli_tests_")
    binary = os.path.join(tmpdir, "jli_entry_tests")

    includes = []
    for inc in INCLUDE_DIRS:
        includes += ["-I", inc]
    cmd = [clang, "-fobjc-arc", "-Wall", "-Wno-unused-parameter"] + includes + \
          ["-framework", "Foundation", "-framework", "CoreFoundation",
           "-o", binary] + SOURCES
    print("compile: clang -fobjc-arc -I Natives/Context ... -o jli_entry_tests")
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
    if passed < 30:
        print("[runner] 用例数 %d < 30（本套单测下限），视为失败" % passed)
        return 1
    print("[runner] 全部通过 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
