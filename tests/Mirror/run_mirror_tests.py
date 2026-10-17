#!/usr/bin/env python3
"""
Air2 tests/Mirror —— 国内镜像链单测运行器（★仓内测试入口★）。

做什么：
  用 clang 把 Air2/Core/Addons/A2MirrorResolver.m、Air2/Core/Settings/A2Settings.m
  与 tests/Mirror/mirror_tests.m 一起编译成 macOS 可执行文件并运行：
    · ① URL 重写表（逐域名 / 逐路径 + 不改写的反例）
    · ② 中国大陆判定 —— ★同一个二进制用不同 TZ 跑多轮，真判定、不复刻逻辑★
    · ③ 开关 / 优先级四组合（纯函数缝）
    · ④ 源标签（判据行字段）
    · ⑤ 接线判据（判据串 / 候选展开真的接在下载路径上，含阴性对照）

为什么是【真编译 + 真运行】而不是源码扫描：
  「官方 URL 有没有被改写成对的镜像 URL、库走不走 /maven、资源走不走 /assets、
    同前缀异主机会不会被误改写」都是**字符串变换 + 顺序**的行为问题。
  源码扫描只能证明「文字在文件里」；只有把改写函数真喂进每条官方路径、再看输出，
  才能证明候选链的**第一顺位确实是镜像、第二顺位确实是官方**。

用法：
    python3 tests/Mirror/run_mirror_tests.py

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

# 被测的【真实】源文件。
#   A2MirrorResolver.m —— 域名映射与候选链的唯一实现处
#   A2Settings.m       —— 开关 / 优先级的落盘语义（被 resolver 引用，必须一起链）
SOURCES = [
    os.path.join(ROOT, "Air2", "Core", "Addons", "A2MirrorResolver.m"),
    os.path.join(ROOT, "Air2", "Core", "Settings", "A2Settings.m"),
    os.path.join(HERE, "mirror_tests.m"),
]

# 头搜索路径：被测文件按「裸文件名」互相 import（仓内既有写法）。
INCLUDE_DIRS = [
    os.path.join(ROOT, "Air2", "Core", "Addons"),
    os.path.join(ROOT, "Air2", "Core", "Settings"),
    os.path.join(ROOT, "Air2", "Utils"),               # A2LaunchMemory.h（内存档位枚举）
]

# 时区轮次：(TZ 值, 期望结论)。大陆时区判 YES，其余判 NO。
# 依据 = 系统时区（与老线 Air 1 的 PLMirrorIsChinaMainland 同口径）。
TZ_ROUNDS = [
    ("Asia/Shanghai", "cn"),
    ("Asia/Urumqi", "cn"),
    ("Asia/Chongqing", "cn"),
    ("Asia/Harbin", "cn"),
    ("America/Los_Angeles", "noncn"),
    ("Europe/London", "noncn"),
    ("Asia/Tokyo", "noncn"),
    ("UTC", "noncn"),
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

    tmpdir = tempfile.mkdtemp(prefix="a2mirror_tests_")
    binary = os.path.join(tmpdir, "mirror_tests")

    includes = []
    for inc in INCLUDE_DIRS:
        includes += ["-I", inc]
    cmd = [clang, "-fobjc-arc", "-Wall", "-Wno-unused-parameter"] + includes + \
          ["-framework", "Foundation", "-framework", "CoreFoundation",
           "-o", binary] + SOURCES
    print("compile: clang -fobjc-arc -I Air2/{Core/Addons,Core/Settings,Utils} ... "
          "-o mirror_tests")
    ci = subprocess.run(cmd, capture_output=True, text=True)
    if ci.stderr.strip():
        print("--- clang 输出 ---")
        print(ci.stderr.strip())
    if ci.returncode != 0:
        print("!! 编译失败（rc=%d）" % ci.returncode)
        return 1

    passed = 0
    failed = 0
    failed_lines = []

    for i, (tz, expect) in enumerate(TZ_ROUNDS):
        env = dict(os.environ)
        env["TZ"] = tz
        env["A2_MIRROR_TZ_EXPECT"] = expect
        if i == 0:
            env["A2_MIRROR_SOURCE_CHECK"] = "1"     # 源码级断言只在首轮跑一次

        print("\n---- TZ=%s（期望 %s）----" % (tz, expect))
        run = subprocess.run([binary], capture_output=True, text=True, env=env)
        out = run.stdout + run.stderr
        sys.stdout.write(out)

        p = sum(1 for ln in out.splitlines() if ln.startswith("PASS"))
        f = sum(1 for ln in out.splitlines() if ln.startswith("FAIL"))
        passed += p
        failed += f
        for ln in out.splitlines():
            if ln.startswith("FAIL"):
                failed_lines.append("[%s] %s" % (tz, ln))
        if run.returncode != 0 and f == 0:
            print("!! 本轮非零退出但无 FAIL 行（rc=%d）" % run.returncode)
            failed += 1

    print("\n================ 汇总（%d 轮） ================" % len(TZ_ROUNDS))
    print("TOTAL pass=%d fail=%d" % (passed, failed))
    for ln in failed_lines:
        print(ln)

    if failed:
        return 1
    if passed == 0:
        print("[runner] 未解析到任何用例，视为失败")
        return 1
    print("[runner] 全部通过 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
