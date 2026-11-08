#!/usr/bin/env python3
"""
Air2 tests/Core —— ★主页落盘层（导入 / 导出 / 备份 / 只读）行为单测★ 运行器。

做什么：
  用 clang 把【仓内真实实现】A2HomeStore.m + A2HomeLayout.m（及其 Foundation 依赖
  A2Settings.m / A2Log.m / A2LaunchMemory.m）与 tests/Core/home_store_tests.m
  编成 macOS 可执行文件，并**把 HOME 指向临时目录**后运行 ——
  这样 Documents/home-layout.json 落在沙盒化的 tmp 里，不会碰真实用户配置。

为什么必须真跑：
  本单验收项 4/9 是「导入前备份 .bak」「版本过高只读不覆盖」「结构损坏不动现有配置」
  「只读模式禁写」。这些全是**文件系统上的后果**，只有真的写、真的读回来、真的比对
  字节才能证明；源码扫描证明不了「没覆盖」。

用法：
    python3 tests/Core/run_home_store_tests.py

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

SOURCES = [
    os.path.join(ROOT, "Air2", "Core", "Home", "A2HomeLayout.m"),
    os.path.join(ROOT, "Air2", "Core", "Home", "A2HomeStore.m"),
    os.path.join(ROOT, "Air2", "Core", "Settings", "A2Settings.m"),
    os.path.join(ROOT, "Air2", "Utils", "A2Log.m"),
    os.path.join(ROOT, "Air2", "Utils", "A2LaunchMemory.m"),
    os.path.join(HERE, "home_store_tests.m"),
]

INCLUDE_DIRS = [
    os.path.join(ROOT, "Air2", "Core", "Home"),
    os.path.join(ROOT, "Air2", "Core", "Settings"),
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

    workdir = tempfile.mkdtemp(prefix="a2home_store_")
    binary = os.path.join(workdir, "home_store_tests")
    fake_home = os.path.join(workdir, "home")
    os.makedirs(os.path.join(fake_home, "Documents"), exist_ok=True)

    includes = []
    for inc in INCLUDE_DIRS:
        includes += ["-I", inc]
    cmd = [clang, "-fobjc-arc", "-Wall", "-Wno-unused-parameter"] + includes + \
          ["-framework", "Foundation", "-framework", "CoreFoundation",
           "-o", binary] + SOURCES
    print("compile: clang -fobjc-arc -I Air2/{Core/Home,Core/Settings,Utils} ... -o home_store_tests")
    ci = subprocess.run(cmd, capture_output=True, text=True)
    if ci.stderr.strip():
        print("--- clang 输出 ---")
        print(ci.stderr.strip())
    if ci.returncode != 0:
        print("!! 编译失败（rc=%d）" % ci.returncode)
        return 1

    env = dict(os.environ)
    env["HOME"] = fake_home
    env["TMPDIR"] = os.path.join(workdir, "tmp")
    os.makedirs(env["TMPDIR"], exist_ok=True)

    print("run: %s  (HOME=%s)\n" % (binary, fake_home))
    run = subprocess.run([binary], capture_output=True, text=True, env=env)
    out = run.stdout + run.stderr
    sys.stdout.write(out)

    failed = sum(1 for ln in out.splitlines() if ln.startswith("FAIL"))
    checks = 0
    for ln in out.splitlines():
        if ln.startswith("__HOME_STORE_CHECKS="):
            try:
                checks = int(ln.split("=", 1)[1])
            except ValueError:
                checks = 0
    print("\n[runner] 解析结果：CHECK=%d FAIL=%d" % (checks, failed))

    if failed or run.returncode != 0:
        return 1
    if checks == 0:
        print("[runner] 未解析到任何断言，视为失败")
        return 1
    print("[runner] 全部通过 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
