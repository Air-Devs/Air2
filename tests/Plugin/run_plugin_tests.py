#!/usr/bin/env python3
"""
Air2 tests/Plugin —— ★插件数据层单测运行器★（manifest 校验 + registry 原子读写）。

做什么：
  用 clang 把 Air2/Core/Plugin 下的【真实实现】
    A2PluginManifest.m  （manifest.json 解析 / 校验 / 权限集规范串）
    A2PluginRegistry.m  （registry.json 原子读写 / approvedHashes 淘汰 / 损坏不覆写）
  与 tests/Plugin/plugin_data_tests.m 一起编译成 macOS 可执行文件并运行，
  逐例输出 PASS/FAIL 与末尾计数。

为什么是【真编译 + 真运行】而不是源码扫描：
  「什么情况拒装、错误码对不对」「写盘后重读是否一致」「approvedHashes 第 6 个
  进来时最旧的是不是被丢掉」「损坏的 registry.json 会不会被覆盖」都是**行为**。
  源码扫描只能证明「文字在文件里」，只有把这两个类真跑一遍才能证明「门在那儿」。

为什么这些类只依赖 Foundation：
  它们不读磁盘日志、不碰 UIKit —— registry 用 POSIX open/fsync/rename 做原子写，
  在 macOS 上同样成立，所以本测试可以在 Mac 上直接编、直接跑。

用法：
    python3 tests/Plugin/run_plugin_tests.py

退出码：0 = 全部通过；1 = 有 FAIL 或工具链/编译失败。
（本机没有 clang 时脚本会明确报告「未编译」，不假装跑过 —— 属预期；请在 Mac 上跑。）
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # 仓根

PLUGIN_DIR = os.path.join(ROOT, "Air2", "Core", "Plugin")

# 被测的【真实】源文件（只用 Foundation + POSIX ⇒ 能在 macOS 上直接编、直接跑）。
SOURCES = [
    os.path.join(PLUGIN_DIR, "A2PluginManifest.m"),
    os.path.join(PLUGIN_DIR, "A2PluginRegistry.m"),
    os.path.join(HERE, "plugin_data_tests.m"),
]

INCLUDE_DIRS = [PLUGIN_DIR]


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
        print("找不到 clang（本测试需在装有 Xcode 命令行工具的 macOS 上运行）。")
        print("本机没有工具链 ⇒ 这些用例【未编译、未执行】，不代表通过。")
        return 1
    print("clang = %s" % clang)

    tmpdir = tempfile.mkdtemp(prefix="a2plugin_tests_")
    binary = os.path.join(tmpdir, "plugin_data_tests")

    includes = []
    for inc in INCLUDE_DIRS:
        includes += ["-I", inc]
    cmd = [clang, "-fobjc-arc", "-Wall", "-Wno-unused-parameter"] + includes + \
          ["-framework", "Foundation", "-framework", "CoreFoundation",
           "-o", binary] + SOURCES
    print("compile: clang -fobjc-arc -I Air2/Core/Plugin ... -o plugin_data_tests")
    compile_result = subprocess.run(cmd, capture_output=True, text=True)
    if compile_result.stderr.strip():
        print("--- clang 输出 ---")
        print(compile_result.stderr.strip())
    if compile_result.returncode != 0:
        print("!! 编译失败（rc=%d）" % compile_result.returncode)
        return 1

    print("run: %s\n" % binary)
    run = subprocess.run([binary], capture_output=True, text=True)
    out = run.stdout + run.stderr
    sys.stdout.write(out)

    passed = sum(1 for ln in out.splitlines() if ln.startswith("PASS"))
    failed = sum(1 for ln in out.splitlines() if ln.startswith("FAIL"))
    print("\n[runner] 解析结果：PASS=%d FAIL=%d 合计=%d" % (passed, failed, passed + failed))

    if failed or run.returncode != 0:
        return 1
    if passed == 0:
        print("[runner] 未解析到任何用例，视为失败")
        return 1
    print("[runner] 全部通过 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
